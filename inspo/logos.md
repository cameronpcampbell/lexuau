# Logos Architecture Analysis

> Deep dive into [maciejhirsz/logos](https://github.com/maciejhirsz/logos) — a compile-time lexer generator for Rust that produces lexers rivaling hand-written performance (1000+ MB/s throughput).

---

## Table of Contents

1. [High-Level Architecture](#1-high-level-architecture)
2. [Crate Structure](#2-crate-structure)
3. [Runtime Library (`logos`)](#3-runtime-library)
4. [Derive Macro Entry Point (`logos-derive`)](#4-derive-macro-entry-point)
5. [Code Generation Engine (`logos-codegen`)](#5-code-generation-engine)
6. [Parsing Pipeline](#6-parsing-pipeline)
7. [Pattern Compilation](#7-pattern-compilation)
8. [Graph / Automaton Construction](#8-graph--automaton-construction)
9. [Code Generation](#9-code-generation)
10. [Optimization Techniques](#10-optimization-techniques)
11. [Error Handling](#11-error-handling)
12. [Key Design Decisions](#12-key-design-decisions)

---

## 1. High-Level Architecture

Logos transforms `#[derive(Logos)]` enum definitions into highly optimized lexer code at compile time. The entire pipeline runs during `rustc`'s macro expansion phase — no runtime regex engine exists.

```
User writes:                         Compiler produces:
#[derive(Logos)]                     impl Logos for Token {
enum Token {                           fn lex(lexer: &mut Lexer) -> ... {
  #[token("+")]                          // Optimized state machine
  Plus,                                  // with lookup tables,
  #[regex("[0-9]+")]                     // loop unrolling, and
  Number,                                // zero-copy slicing
}                                      }
                                     }
```

**Processing pipeline:**

```
TokenStream (Rust AST)
    │
    ▼
┌─────────────────────┐
│  Parser              │  Extract #[token], #[regex], #[logos] attributes
│  (logos-codegen)      │  Parse callbacks, priorities, subpatterns
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│  Pattern Compiler    │  regex-syntax: regex string → HIR
│                      │  Priority calculation per pattern
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│  Graph Builder       │  regex-automata: HIR → NFA → DFA
│                      │  State deduplication, dead-state pruning
│                      │  Early-match detection
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│  Code Generator      │  DFA → Rust code (state machine or tail-call)
│                      │  Lookup tables, fast loops, fork logic
└─────────┬───────────┘
          │
          ▼
TokenStream (generated `impl Logos`)
```

---

## 2. Crate Structure

```
logos/                          # Workspace root
├── Cargo.toml                  # Workspace manifest (v0.16.1, edition 2021, MSRV 1.80)
├── src/                        # Runtime library (logos crate)
│   ├── lib.rs                  # Logos trait, Skip, Filter, FilterResult
│   ├── lexer.rs                # Lexer struct, Span, SpannedIter
│   ├── source.rs               # Source trait, Chunk trait
│   └── internal.rs             # LexerInternal, CallbackRetVal, SkipRetVal
├── logos-derive/               # Proc macro crate (thin wrapper)
│   └── src/lib.rs              # #[proc_macro_derive(Logos, ...)]
├── logos-codegen/              # Heavy lifting: parsing, graph, codegen
│   └── src/
│       ├── lib.rs              # generate() entry point
│       ├── error.rs            # Error accumulation and reporting
│       ├── leaf.rs             # Leaf nodes (pattern match endpoints)
│       ├── pattern.rs          # Pattern compilation and priority
│       ├── util.rs             # TokenStream helpers
│       ├── macros.rs           # Debug macros
│       ├── parser/
│       │   ├── mod.rs          # Parser struct, attribute orchestration
│       │   ├── definition.rs   # #[token] / #[regex] attribute parsing
│       │   ├── error_type.rs   # Error type validation
│       │   ├── ignore_flags.rs # Case sensitivity flags
│       │   ├── nested.rs       # Flexible attribute syntax parser
│       │   ├── subpattern.rs   # Named regex fragment resolution
│       │   └── type_params.rs  # Generic type parameter handling
│       ├── graph/
│       │   ├── mod.rs          # Graph (DFA) construction and optimization
│       │   ├── dfa_util.rs     # State traversal utilities
│       │   └── export.rs       # DOT / Mermaid visualization export
│       └── generator/
│           ├── mod.rs          # Generator struct, code emission orchestration
│           ├── fork.rs         # State branching / byte dispatch logic
│           ├── fast_loop.rs    # Self-edge loop unrolling optimization
│           └── leaf.rs         # Callback code generation
├── logos-cli/                  # CLI tool for visualization
└── tests/                      # Integration tests
```

**Key external dependencies (logos-codegen):**
- `regex-automata 0.4.9` — NFA/DFA compilation from HIR
- `regex-syntax 0.8.5` — Regex string parsing to HIR
- `syn 2.0` (full features) — Rust AST parsing
- `quote 1.0` — TokenStream code generation
- `proc-macro2 1.0` — Proc macro API
- `fnv 1.0` — Fast hashing for state deduplication

---

## 3. Runtime Library

The `logos` crate is intentionally minimal — the heavy work happens at compile time. The runtime provides the scaffolding that generated code plugs into.

### 3.1 The `Logos` Trait

```rust
pub trait Logos<'source>: Sized {
    type Extras;                                        // User-defined state
    type Source: Source + ?Sized + 'source;              // Input type (str or [u8])
    type Error: Default + Clone + PartialEq + Debug;    // Error type

    /// Core function — implemented by the derive macro.
    /// Called by Iterator::next() to advance and produce the next token.
    fn lex(lexer: &mut Lexer<'source, Self>) -> Option<Result<Self, Self::Error>>;

    fn lexer(source: &'source Self::Source) -> Lexer<'source, Self>
    where Self::Extras: Default;

    fn lexer_with_extras(source: &'source Self::Source, extras: Self::Extras) -> Lexer<'source, Self>;
}
```

**Design notes:**
- Generic over `'source` — all token data borrows from input, zero allocations during lexing
- `lex()` is the single entry point for generated code — one function encapsulates the entire state machine
- Associated types allow customization without runtime overhead (monomorphization)

### 3.2 The `Lexer` Struct

```rust
pub struct Lexer<'source, Token: Logos<'source>> {
    source: &'source Token::Source,    // Borrowed input
    token_start: usize,                // Byte offset: start of current token
    token_end: usize,                  // Byte offset: end of current token (read head)
    pub extras: Token::Extras,         // User-accessible state
}

pub type Span = Range<usize>;          // Byte range alias
```

**Key methods:**

| Method | Returns | Purpose |
|--------|---------|---------|
| `span()` | `Span` | Current token's byte range `token_start..token_end` |
| `slice()` | `&Source::Slice` | Matched text from source (zero-copy) |
| `bump(n)` | `()` | Advance `token_end` by `n` bytes (validates UTF-8) |
| `remainder()` | `&Source::Slice` | Unconsumed input from `token_end` onward |
| `source()` | `&Source` | Full input reference |
| `morph::<T>()` | `Lexer<T>` | Switch token type mid-stream (preserving position) |
| `spanned()` | `SpannedIter` | Iterator yielding `(Result<Token, Error>, Span)` |

**Iterator implementation:**
```rust
impl<'source, Token: Logos<'source>> Iterator for Lexer<'source, Token> {
    type Item = Result<Token, Token::Error>;

    fn next(&mut self) -> Option<Self::Item> {
        self.token_start = self.token_end;  // Advance past previous token
        Token::lex(self)                     // Generated state machine takes over
    }
}
```

The lexer's position is tracked purely through `token_start` and `token_end` byte offsets. The generated `lex()` function reads bytes from `source` starting at `token_end` and updates `token_end` when a match is found.

### 3.3 The `Source` Trait

Abstracts over input types (`&str` vs `&[u8]`):

```rust
pub trait Source {
    type Slice<'a>: PartialEq + Eq + Debug where Self: 'a;

    fn len(&self) -> usize;
    fn read<'a, Chunk>(&'a self, offset: usize) -> Option<Chunk>
        where Chunk: Chunk<'a>;
    fn slice(&self, range: Range<usize>) -> Option<Self::Slice<'_>>;
    fn find_boundary(&self, index: usize) -> usize;  // UTF-8 char boundary
    fn is_boundary(&self, index: usize) -> bool;
}
```

**Implementations:**
- **`str`**: `Slice = &str`, enforces UTF-8 char boundaries, `find_boundary()` scans forward to valid code point start
- **`[u8]`**: `Slice = &[u8]`, no boundary restrictions (binary-safe)
- **Generic `Deref<Target: Source>`**: Enables `String`, `Vec<u8>`, `Box<str>`, etc.

**`Chunk` trait** — fixed-size byte reading for efficient pattern matching:
```rust
pub trait Chunk<'source>: Sized + Copy + PartialEq + Eq {
    const SIZE: usize;
    unsafe fn from_ptr(ptr: *const u8) -> Self;  // Fast path
    fn from_slice(s: &'source [u8]) -> Option<Self>;  // Safe path (forbid_unsafe feature)
}
```
Implemented for `u8` (SIZE=1) and `&[u8; N]` for N=1..=32. Enables reading fixed byte chunks with a single bounds check.

### 3.4 Callback / Filter System

Logos supports flexible return types from token callbacks:

```rust
pub struct Skip;                    // Signal: skip this match entirely

pub enum Filter<T> {
    Emit(T),                        // Produce token with value
    Skip,                           // Skip this match
}

pub enum FilterResult<T, E> {
    Emit(T),                        // Produce token with value
    Skip,                           // Skip this match
    Error(E),                       // Produce error
}
```

The `CallbackRetVal` trait (internal) enables polymorphic callbacks — users can return `T`, `Option<T>`, `Result<T, E>`, `Filter<T>`, `FilterResult<T, E>`, `bool`, `Skip`, or the token type itself. The trait converts each into a unified `CallbackResult`:

```rust
pub enum CallbackResult<'a, L: Logos<'a>> {
    Emit(L),           // Token produced
    Error(L::Error),   // Typed error
    DefaultError,      // Default error value
    Skip,              // Skip this match
}
```

### 3.5 `LexerInternal` Trait

The bridge between generated code and the `Lexer` struct (not public API):

```rust
pub trait LexerInternal<'source> {
    type Token: Logos<'source>;

    fn offset(&self) -> usize;          // Read token_start
    fn read<T: Chunk<'source>>(&self, offset: usize) -> Option<T>;
    fn trivia(&mut self);               // Reset token_start = token_end (skip whitespace)
    fn end(&mut self, offset: usize);   // Set token_end
    fn end_to_boundary(&mut self, offset: usize);  // Set token_end at UTF-8 boundary
}
```

Generated code calls these methods to read input and manipulate positions without direct field access.

---

## 4. Derive Macro Entry Point

`logos-derive` is a razor-thin proc macro crate:

```rust
// logos-derive/src/lib.rs
#[proc_macro_derive(Logos, attributes(logos, extras, error, end, token, regex))]
pub fn logos(input: TokenStream) -> TokenStream {
    logos_codegen::generate(input.into()).into()
}
```

**Registered attributes:**
- `#[logos(...)]` — Container-level config (skip patterns, subpatterns, extras, error type, UTF-8 mode)
- `#[token("...")]` — Literal string match
- `#[regex("...")]` — Regex pattern match
- `#[error]` — Default error variant
- `#[end]` — End-of-input marker (legacy)
- `#[extras]` — Custom extras type (legacy)

All logic lives in `logos-codegen`. The derive crate exists solely because proc macros must be in their own crate.

---

## 5. Code Generation Engine

`logos-codegen/src/lib.rs` contains `generate()` — the master orchestrator:

```
generate(input: TokenStream) → TokenStream
    │
    ├─ Parse enum definition (syn::ItemEnum)
    ├─ Extract generics, validate structure
    ├─ Run Parser on attributes → leaves, skip patterns, subpatterns
    ├─ Compile Pattern objects (regex-syntax HIR)
    ├─ Build Graph (NFA → DFA → optimized state machine)
    ├─ Run Generator (Graph → Rust code)
    └─ Return impl block as TokenStream
```

---

## 6. Parsing Pipeline

### 6.1 Parser Struct (`parser/mod.rs`)

The `Parser` orchestrates attribute extraction. `try_parse_logos()` processes the `#[logos(...)]` container attribute:

| Key | Purpose |
|-----|---------|
| `crate` | Override logos crate path |
| `error` | Custom error type |
| `extras` | Extras type |
| `skip` | Skip pattern (e.g., `r"\s+"`) |
| `subpattern` | Named regex fragments |
| `utf8` | Force UTF-8 mode on/off |
| `export_dir` | Directory for graph visualization |

### 6.2 Definition Parsing (`parser/definition.rs`)

Each `#[token("...")]` or `#[regex("...")]` attribute becomes a `Definition`:

```rust
pub struct Definition {
    pub literal: Literal,           // UTF-8 string or byte string
    pub priority: Option<usize>,    // Explicit priority override
    pub callback: Option<Callback>, // Label or inline closure
    pub allow_greedy: bool,         // Allow greedy .+ patterns
    pub ignore: IgnoreFlags,        // Case sensitivity flags
}
```

**Callback types:**
- **Label**: `#[regex("[0-9]+", my_parser)]` — references a named function
- **Inline**: `#[regex("[0-9]+", |lex| lex.slice().parse())]` — closure with `lex` parameter

### 6.3 Subpattern Resolution (`parser/subpattern.rs`)

Named patterns can be defined and reused:

```rust
#[logos(
    subpattern digit = "[0-9]",
    subpattern hex   = "[0-9a-fA-F]",
)]
enum Token {
    #[regex("(?&digit)+")]     // Expands to [0-9]+
    Integer,
    #[regex("0x(?&hex)+")]     // Expands to 0x[0-9a-fA-F]+
    HexLiteral,
}
```

Resolution is recursive — later subpatterns can reference earlier ones. The parser substitutes `(?&name)` references with their definitions before regex compilation.

### 6.4 Type Parameters (`parser/type_params.rs`)

Handles generic token types:
- Enforces single lifetime parameter (default `'s`)
- Supports named type parameters with concrete assignments
- Replaces lifetime references throughout generated code

---

## 7. Pattern Compilation

### `Pattern` Struct (`pattern.rs`)

```rust
pub struct Pattern {
    is_literal: bool,       // true for #[token], false for #[regex]
    source: String,         // Original pattern string
    hir: Hir,              // regex-syntax HIR (Hierarchical Intermediate Representation)
}
```

**Compilation paths:**
- `compile()` — Regex strings via `regex_syntax::ParserBuilder`. Applies unicode and case-insensitive flags. UTF-8 checking deferred to later validation.
- `compile_lit()` — Literal byte sequences. No escape processing, direct HIR construction.

### Priority Calculation

Priority determines which token wins when multiple patterns match the same input at the same position. Higher priority = wins.

```
Pattern type              │ Priority formula
──────────────────────────┼──────────────────────────
Literal "abc"             │ 2 × character_count (= 6)
Character class [a-z]     │ 2
Repetition [a-z]{3,5}     │ min_count × sub_priority
Alternation (a|bc)        │ min(branch_priorities)
Concatenation ab          │ sum(sub_priorities)
```

Literals always get the highest priority — they're the most specific. Users can override with `priority = N`.

### Greedy Pattern Detection

`check_for_greedy_all()` flags dangerous patterns like `.*` or `.+` that would consume the entire input. These require explicit `allow_greedy` opt-in.

---

## 8. Graph / Automaton Construction

This is the heart of Logos — transforming pattern definitions into an optimized DFA.

### 8.1 Core Data Structures (`graph/mod.rs`)

```rust
pub struct Graph {
    states: Vec<StateData>,     // All states indexed by State
    leaves: Vec<Leaf>,          // Pattern match endpoints
}

pub struct State(usize);        // Newtype index into states vec

pub struct StateData {
    pub state_type: StateType,                  // Which leaves match here
    pub normal: Vec<(ByteClass, State)>,        // Byte transitions
    pub eoi: Option<State>,                     // End-of-input transition
    pub backward: Vec<State>,                   // Parent states (for pruning)
}

pub struct StateType {
    pub accept: Option<LeafId>,   // Match ending before last byte
    pub early: Option<LeafId>,    // Match including last byte
}

pub struct ByteClass { /* sorted non-overlapping byte ranges */ }
```

**ByteClass** represents sets of byte values as contiguous ranges. For example, `[a-zA-Z]` becomes two ranges: `[65..=90, 97..=122]`. Supports merging, comparison, and conversion to 256-element lookup tables.

### 8.2 Construction Pipeline (`Graph::new()`)

#### Step 1: NFA Compilation
```rust
let nfa = NFA::compiler()
    .configure(nfa_config)
    .build_many_from_hir(&hirs)   // All patterns compiled into one NFA
```
Uses `regex-automata` to compile all pattern HIRs into a single NFA. Each pattern gets a distinct match ID for later identification.

#### Step 2: DFA Conversion
```rust
let dfa = DFA::builder()
    .configure(dfa_config)
    .build_from_nfa(&nfa)
```
Configuration:
- `MatchKind::All` — Track all simultaneous matches (not just first/leftmost)
- `StartKind::Anchored` — Match from current position (no search)
- Byte classes disabled (each byte value gets its own transition)
- Minimization disabled (Logos does its own optimization)

#### Step 3: State Enumeration
Maps DFA state IDs to sequential `State(0)`, `State(1)`, etc. Creates `StateData` for each with empty transitions.

#### Step 4: Transition Building
For each state, iterates all 256 byte values (0x00–0xFF):
- Groups bytes with identical target states into `ByteClass` objects
- Records transitions as `(ByteClass, target_state)` pairs
- Separately records end-of-input (EOI) transitions
- Builds backward edges for later pruning

#### Step 5: Early-Match Detection
If all children of an accepting state accept the same single leaf, mark the parent as an "early" match. This avoids an extra state transition for common cases like single-character tokens.

#### Step 6: Dead-State Pruning
Starting from accepting states, traverses backward edges to mark reachable states. Unreachable states are removed, significantly shrinking the graph.

#### Step 7: State Deduplication
Iteratively merges states with identical structure:
- Same byte class ranges
- Same target states (after remapping)
- Same match type
- Same EOI transition

Continues until no further merges are possible (fixed-point iteration).

### 8.3 Visualization Export (`graph/export.rs`)

The graph can be exported for debugging:
- **Graphviz DOT** — Rectangular nodes, colored green for accepting states
- **Mermaid** — Flowchart diagrams with hex color codes

Both include edge labels showing byte classes and EOI markers. Enabled via `#[logos(export_dir = "path/")]`.

### 8.4 DFA Utilities (`graph/dfa_util.rs`)

- `iter_matches(state)` — Returns leaf IDs matching at a state
- `iter_children(state)` — Returns all byte/EOI transitions from a state
- `get_states()` — Depth-first traversal from root, returns sorted reachable states

---

## 9. Code Generation

The `Generator` transforms the optimized `Graph` into executable Rust code.

### 9.1 Generator Structure (`generator/mod.rs`)

```rust
pub struct Generator<'a> {
    config: Config,
    name: Ident,                        // Token enum name
    this: TokenStream,                  // Type with generics applied
    graph: &'a Graph,
    state_idents: Vec<(Ident, Ident)>,  // (snake_case, PascalCase) per state
    leaf_idents: Vec<Ident>,            // Identifier per leaf
    error_callback: TokenStream,
    loop_masks: Vec<Vec<u8>>,           // Lookup tables for fast loops
}
```

### 9.2 Two Code Generation Modes

**State Machine Mode** (`use_state_machine_codegen = true`):
```rust
// Generated code structure:
enum _LogosState { State0, State1, State2, ... }

fn lex(lexer: &mut Lexer<Token>) -> Option<Result<Token, Error>> {
    let mut state = _LogosState::State0;
    loop {
        match state {
            _LogosState::State0 => { /* read byte, transition */ }
            _LogosState::State1 => { /* ... */ }
            _LogosState::State2 => { /* ... */ }
        }
    }
}
```
- Central dispatch loop with enum states
- More compact generated code
- Good for lexers with few states

**Tail-Call Mode** (`use_state_machine_codegen = false`):
```rust
// Generated code structure:
fn _state_0(lexer: &mut Lexer<Token>) -> ... {
    // Read byte, then:
    _state_1(lexer)  // "tail call" to next state
}

fn _state_1(lexer: &mut Lexer<Token>) -> ... {
    _state_2(lexer)
}
```
- Separate function per state
- Recursive calls (Rust optimizes tail calls in release mode)
- Can be faster for large lexers (avoids dispatch overhead)

### 9.3 State Code Generation (`generate_state()`)

For each DFA state:

1. **Set up match context** — If state is accepting, record which leaf matched
2. **Check for fast loops** — If state has a self-edge, generate optimized loop (see 10.3)
3. **Generate fork logic** — Byte dispatch to next states
4. **Wrap in mode-specific code** — Enum variant or function definition

### 9.4 Fork / Branch Logic (`generator/fork.rs`)

The fork handles "given the next byte, which state do I go to?"

**Few transitions (<=2): Conditional branching**
```rust
// Generated: direct if/else
if byte == b'+' {
    // transition to Plus state
} else if matches!(byte, b'0'..=b'9') {
    // transition to Number state
} else {
    // error/default
}
```

**Many transitions (>2): Lookup table dispatch**
```rust
// Generated: 256-byte table mapping byte → branch index
const TABLE: [u8; 256] = [0, 0, 0, ..., 1, 1, ..., 2, ...];
match TABLE[byte as usize] {
    0 => { /* default/error */ }
    1 => { /* transition A */ }
    2 => { /* transition B */ }
    _ => unreachable!()
}
```

**End-of-input handling:**
- If lexing just started (`token_start == token_end`): return `None`
- If EOI transition exists: follow it
- Otherwise: emit best match found so far or error

### 9.5 Callback Code Generation (`generator/leaf.rs`)

For each leaf (matched pattern), generates the appropriate action:

- **Unit variants** (`Plus`): Directly construct enum variant
- **Value variants** (`Number(i64)`): Call callback with `lex` reference, use `CallbackRetVal` trait to convert result
- **Skip variants**: Return `Skip` signal, lexer restarts from current position

```rust
// Example generated code for: #[regex("[0-9]+", |lex| lex.slice().parse())]
// Number(i64),
{
    let callback_result = (|lex: &mut Lexer<Token>| lex.slice().parse())(lexer);
    // CallbackRetVal converts Result<i64, _> into CallbackResult
    match callback_result.construct(Token::Number) {
        CallbackResult::Emit(token) => Some(Ok(token)),
        CallbackResult::Error(err) => Some(Err(err)),
        CallbackResult::Skip => { lexer.trivia(); continue; }
        CallbackResult::DefaultError => Some(Err(Default::default())),
    }
}
```

### 9.6 Lookup Table Rendering

`render_luts()` compresses byte classification into efficient lookup tables:

```rust
// Generated: packed lookup tables
const _LUT_0: [u8; 256] = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, ...  // 0x00-0x0F
    // ... 256 entries mapping byte → bit flags
];
```

- Groups up to 8 classifications per table (bit-packed)
- Each table is 256 bytes
- Fast loops test membership via `_LUT[byte] & MASK != 0`

---

## 10. Optimization Techniques

### 10.1 Compile-Time DFA Construction

The most fundamental optimization: **all pattern matching logic is resolved at compile time**. There is no runtime regex engine, no interpretation loop, no pattern compilation on startup. The generated code is pure Rust with direct byte comparisons and table lookups.

### 10.2 State Deduplication

Equivalent states are merged during graph construction, reducing the number of states (and therefore branches) in the generated code. This is applied iteratively until a fixed point.

### 10.3 Fast Loop Optimization (`generator/fast_loop.rs`)

When a state has a self-referencing edge (e.g., `[0-9]+` loops on digit bytes), Logos generates an unrolled inner loop:

```rust
// Conceptual generated code for [0-9]+ fast loop:
loop {
    // Unrolled: check multiple bytes with single bounds check
    if offset + 8 <= source.len() {
        if !LUT[source[offset + 0]] { break; }
        if !LUT[source[offset + 1]] { break; }
        if !LUT[source[offset + 2]] { break; }
        // ... up to 8 bytes
        offset += 8;
        continue;
    }
    // Remainder: single byte at a time
    if offset < source.len() && LUT[source[offset]] {
        offset += 1;
    } else {
        break;
    }
}
```

Benefits:
- Amortizes bounds checks across multiple bytes
- Reduces branch misprediction (longer straight-line code)
- Lookup table stays in L1 cache

### 10.4 Early-Match Detection

When all transitions from a state lead to the same token, the state is marked as an "early match." The generated code can emit the token immediately without reading the next byte, saving one memory access per token.

### 10.5 Dead-State Pruning

Unreachable states (those that can never lead to an accepting state) are removed. This prevents generating code for impossible paths, reducing binary size and improving instruction cache behavior.

### 10.6 Lookup Table Dispatch

For states with many outgoing transitions, a 256-byte lookup table replaces a chain of comparisons. A single array index replaces potentially dozens of `if` branches:

```rust
// Instead of:
if byte >= b'a' && byte <= b'z' { ... }
else if byte >= b'A' && byte <= b'Z' { ... }
else if byte >= b'0' && byte <= b'9' { ... }
else if byte == b'_' { ... }

// Generated:
const TABLE: [u8; 256] = [/* precomputed */];
match TABLE[byte as usize] { ... }
```

### 10.7 Zero-Copy Token Extraction

Tokens borrow from the input via `lex.slice()` — no string copying occurs during lexing. The `Source` trait's `Chunk` abstraction enables reading fixed-size byte arrays with minimal bounds checks.

### 10.8 Benchmark Results

From the Logos README (lexing Rust-like syntax):

| Category | Throughput |
|----------|------------|
| Identifiers | 1,204 MB/s |
| Keywords + Operators | 1,037 MB/s |
| Strings | 1,575 MB/s |

---

## 11. Error Handling

### Compile-Time Errors (`error.rs`)

The `Errors` struct accumulates errors during codegen:

```rust
pub struct Errors {
    errors: Vec<SpannedError>,  // (message, source_span) pairs
}
```

- Errors are collected (not immediately fatal) so multiple issues can be reported at once
- `render()` converts to `compile_error!()` macro invocations with original spans
- Users see errors pointing to the exact attribute/pattern that caused the issue

**Validated conditions:**
- UTF-8 compatibility when `Source = str`
- No empty-matching patterns (would cause infinite loops)
- No unbounded greedy patterns without opt-in
- Pattern conflicts (multiple patterns at same priority matching same input)
- Unsupported regex features (lookbehind, etc.)

### Runtime Errors

The `Logos::Error` associated type (default `()`) is returned when no pattern matches. Users can customize:

```rust
#[derive(Default, Debug, Clone, PartialEq)]
struct LexError { position: usize }

#[derive(Logos)]
#[logos(error = LexError)]
enum Token { ... }
```

Error callbacks can produce custom errors via `FilterResult::Error(e)` or `Result::Err(e)`.

---

## 12. Key Design Decisions

### Why compile-time DFA?

Traditional lexers (flex, hand-written) either interpret tables at runtime or require external build steps. Logos uses Rust's proc macro system to generate the DFA during compilation, achieving:
- **No runtime overhead** — the "interpreter" is the compiled Rust code itself
- **No build step** — `cargo build` is all you need
- **Type safety** — patterns and callbacks are checked at compile time
- **Inlining** — LLVM can inline and optimize the generated state machine

### Why `regex-automata` instead of custom DFA?

Logos originally had its own automaton implementation (the `Fork`/`Rope` node types visible in older versions). The migration to `regex-automata` brought:
- Battle-tested NFA→DFA conversion
- Proper handling of Unicode character classes
- `MatchKind::All` for tracking simultaneous matches
- Maintained by the regex ecosystem (Andrew Gallant / BurntSushi)

### Why two codegen modes?

The state machine vs. tail-call trade-off depends on lexer size:
- **Small lexers** (few states): State machine mode produces tighter code, the dispatch enum fits in registers
- **Large lexers** (many states): Tail-call mode avoids the overhead of a central dispatch loop and large match expressions. LLVM can optimize individual state functions independently.

### Why `Source` trait instead of just `&str`?

Binary protocols and byte-oriented formats need lexing too. The `Source` trait with `Chunk` abstraction allows:
- `&str` input with UTF-8 safety guarantees
- `&[u8]` input for binary parsing
- Custom types via `Deref` (e.g., memory-mapped files)

### Why byte-level (not char-level) processing?

UTF-8 is a byte encoding. Processing bytes directly:
- Avoids the overhead of `char` decoding on every step
- Allows single-byte ASCII fast paths (the common case)
- Still handles multi-byte UTF-8 correctly via the `Source::find_boundary()` mechanism
- Enables the `Chunk` trait's fixed-size reads for performance

### The `Extras` pattern

Rather than forcing users to wrap the lexer or use global state, `Extras` provides a type-safe slot for user state that travels with the lexer:

```rust
#[derive(Logos)]
#[logos(extras = MyState)]
enum Token {
    #[regex(r"//.*", |lex| { lex.extras.comment_count += 1; Skip })]
    Comment,
}
```

This keeps the lexer self-contained while allowing stateful lexing (counting lines, tracking nesting depth, etc.).

---

## Appendix: Example End-to-End Flow

Given this input:

```rust
#[derive(Logos)]
#[logos(skip r"[ \t\n]+")]
enum Token {
    #[token("+")]
    Plus,

    #[token("-")]
    Minus,

    #[regex("[0-9]+", |lex| lex.slice().parse::<i64>().ok())]
    Number(i64),

    #[regex("[a-zA-Z_][a-zA-Z0-9_]*")]
    Ident,
}
```

**Step 1 — Parsing:** Four leaves are created:
- Leaf 0: `"+"`, literal, priority 2, unit variant `Plus`
- Leaf 1: `"-"`, literal, priority 2, unit variant `Minus`
- Leaf 2: `[0-9]+`, regex, priority 2, value variant `Number(i64)`, inline callback
- Leaf 3: `[a-zA-Z_][a-zA-Z0-9_]*`, regex, priority 2, unit variant `Ident`
- Skip pattern: `[ \t\n]+`

**Step 2 — Pattern compilation:** Each pattern is parsed to HIR via `regex-syntax`.

**Step 3 — Graph construction:**
- All HIRs compiled into single NFA via `regex-automata`
- NFA converted to DFA
- States enumerated and transitions built
- Example states (simplified):
  - State 0 (start): `+` → State 1, `-` → State 2, `[0-9]` → State 3, `[a-zA-Z_]` → State 4, `[ \t\n]` → State 5
  - State 1 (accept Plus): any → emit Plus
  - State 2 (accept Minus): any → emit Minus
  - State 3 (accept Number): `[0-9]` → State 3 (self-loop), other → emit Number
  - State 4 (accept Ident): `[a-zA-Z0-9_]` → State 4 (self-loop), other → emit Ident
  - State 5 (skip): `[ \t\n]` → State 5 (self-loop), other → trivia, restart

**Step 4 — Optimization:**
- States 1, 2 marked as early matches (single-byte tokens)
- States 3, 4 get fast-loop optimization (self-edges)
- Dead states pruned, equivalent states merged

**Step 5 — Code generation:** Produces `impl Logos for Token` with optimized state machine. States 3 and 4 get unrolled loops for digit/identifier runs. Lookup tables generated for the start state's byte dispatch.

**Result:** A lexer that processes ~1 GB/s of input with zero allocations.
