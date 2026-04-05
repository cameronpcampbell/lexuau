--!strict
--!optimize 2

local hir = require("./hir")
type HirNode = hir.HirNode
type Range = hir.Range

local parser = {}

local BYTE_TAB = string.byte("\t")
local BYTE_NEWLINE = string.byte("\n")
local BYTE_VTAB = string.byte("\v")
local BYTE_FORMFEED = string.byte("\f")
local BYTE_RETURN = string.byte("\r")
local BYTE_ZERO = string.byte("0")
local BYTE_NINE = string.byte("9")
local BYTE_OPEN_PAREN = string.byte("(")
local BYTE_CLOSE_PAREN = string.byte(")")
local BYTE_OPEN_BRACKET = string.byte("[")
local BYTE_CLOSE_BRACKET = string.byte("]")
local BYTE_OPEN_BRACE = string.byte("{")
local BYTE_CLOSE_BRACE = string.byte("}")
local BYTE_BACKSLASH = string.byte("\\")
local BYTE_CARET = string.byte("^")
local BYTE_HYPHEN = string.byte("-")
local BYTE_PIPE = string.byte("|")
local BYTE_DOT = string.byte(".")
local BYTE_STAR = string.byte("*")
local BYTE_PLUS = string.byte("+")
local BYTE_QUESTION = string.byte("?")
local BYTE_COLON = string.byte(":")
local BYTE_COMMA = string.byte(",")
local BYTE_DOLLAR = string.byte("$")
local BYTE_X = string.byte("x")

type ParserState = {
    source: string,
    pos: number,
}

local function new_parser(source: string): ParserState
    return { source = source, pos = 1 }
end

local function peek(state: ParserState): number?
    if state.pos > #state.source then
        return nil
    end

    local byte = string.byte(state.source, state.pos)
    return byte
end

local function advance(state: ParserState): number?
    local byte = peek(state)

    if not byte then
        return nil
    end

    state.pos += 1
    return byte
end

local function expect(state: ParserState, expected_byte: number)
    local byte = advance(state)

    if byte == expected_byte then
        return
    end

    error(
        `Expected '{string.char(expected_byte)}' at position {state.pos - 1}, got '{if byte then string.char(byte) else "EOF"}'.`
    )
end

local function at_end(state: ParserState): boolean
    return state.pos > #state.source
end

local parse_alternation: (state: ParserState) -> HirNode

local ESCAPE_CLASSES: { [string]: () -> HirNode } = {
    d = function() return hir.class(hir.classes.digit) end,
    D = function() return hir.class(hir.negate_class(hir.classes.digit)) end,
    w = function() return hir.class(hir.classes.word) end,
    W = function() return hir.class(hir.negate_class(hir.classes.word)) end,
    s = function() return hir.class(hir.classes.space) end,
    S = function() return hir.class(hir.negate_class(hir.classes.space)) end,
}

local ESCAPE_LITERALS: { [string]: number } = {
    t = BYTE_TAB,
    n = BYTE_NEWLINE,
    r = BYTE_RETURN,
    f = BYTE_FORMFEED,
    v = BYTE_VTAB,
    ["0"] = 0,
}

local function parse_escape(state: ParserState): HirNode
    local byte = advance(state)

    if not byte then
        error("Unexpected end of pattern after '\\'.")
    end

    local char = string.char(byte)

    local class_fn = ESCAPE_CLASSES[char]

    if class_fn then
        return class_fn()
    end

    local literal_byte = ESCAPE_LITERALS[char]

    if literal_byte then
        return hir.literal(literal_byte)
    end

    if byte ~= BYTE_X then
        return hir.literal(byte)
    end

    -- \xHH
    local hex_high = advance(state)
    local hex_low = advance(state)

    if not hex_high or not hex_low then
        error("Incomplete hex escape '\\x'.")
    end

    local hex_string = string.char(hex_high) .. string.char(hex_low)
    local hex_value = tonumber(hex_string, 16)

    if not hex_value then
        error(`Invalid hex escape '\\x{hex_string}'.`)
    end

    return hir.literal(hex_value)
end

-- Same as ESCAPE_CLASSES/ESCAPE_LITERALS but returns ranges for use inside [...].
local CLASS_ESCAPE_RANGES: { [string]: { Range } } = {
    d = hir.classes.digit,
    D = hir.negate_class(hir.classes.digit),
    w = hir.classes.word,
    W = hir.negate_class(hir.classes.word),
    s = hir.classes.space,
    S = hir.negate_class(hir.classes.space),
    t = { { low = BYTE_TAB, high = BYTE_TAB } },
    n = { { low = BYTE_NEWLINE, high = BYTE_NEWLINE } },
    r = { { low = BYTE_RETURN, high = BYTE_RETURN } },
    f = { { low = BYTE_FORMFEED, high = BYTE_FORMFEED } },
    v = { { low = BYTE_VTAB, high = BYTE_VTAB } },
}

local function parse_class_escape(state: ParserState): { Range }
    local byte = advance(state)

    if not byte then
        error("Unexpected end of pattern in character class after '\\'.")
    end

    local mapped = CLASS_ESCAPE_RANGES[string.char(byte)]

    if mapped then
        return mapped
    end

    return { { low = byte, high = byte } }
end

-- Returns the next single byte in a character class, or nil if it was a
-- multi-byte shorthand like \d (which gets appended to ranges directly).
local function next_class_atom(state: ParserState, ranges: { Range }): number?
    local byte = peek(state)

    if not byte or byte == BYTE_CLOSE_BRACKET then
        return nil
    end

    advance(state)

    if byte ~= BYTE_BACKSLASH then
        return byte
    end

    local escape_ranges = parse_class_escape(state)

    if #escape_ranges > 1 or (escape_ranges[1] and escape_ranges[1].low ~= escape_ranges[1].high) then
        for _, range in escape_ranges do
            table.insert(ranges, range)
        end

        return nil
    end

    return escape_ranges[1].low
end

local function parse_class(state: ParserState): HirNode
    local negated = peek(state) == BYTE_CARET

    if negated then
        advance(state)
    end

    local ranges: { Range } = {}

    while peek(state) and peek(state) ~= BYTE_CLOSE_BRACKET do
        local low = next_class_atom(state, ranges)

        if low == nil then
            continue
        end

        if peek(state) ~= BYTE_HYPHEN then
            table.insert(ranges, { low = low, high = low })
            continue
        end

        advance(state)

        -- Trailing '-' before ']' or EOF: treat as two separate literals.
        if peek(state) == BYTE_CLOSE_BRACKET or peek(state) == nil then
            table.insert(ranges, { low = low, high = low })
            table.insert(ranges, { low = BYTE_HYPHEN, high = BYTE_HYPHEN })
            continue
        end

        local high = next_class_atom(state, ranges)

        -- '-' followed by shorthand class like \d: treat '-' as literal.
        if high == nil then
            table.insert(ranges, { low = low, high = low })
            table.insert(ranges, { low = BYTE_HYPHEN, high = BYTE_HYPHEN })
            continue
        end

        table.insert(ranges, { low = low, high = high })
    end

    expect(state, BYTE_CLOSE_BRACKET)

    if negated then
        ranges = hir.negate_class(ranges)
    end

    return hir.class(ranges)
end

local function is_digit(byte: number): boolean
    return byte >= BYTE_ZERO and byte <= BYTE_NINE
end

local function parse_quantifier(state: ParserState): (boolean, number, number?, boolean)
    local byte = peek(state)

    if not byte then
        return false, 0, nil, true
    end

    local min: number
    local max: number? = nil

    if byte == BYTE_STAR then
        advance(state)
        min, max = 0, nil

    elseif byte == BYTE_PLUS then
        advance(state)
        min, max = 1, nil

    elseif byte == BYTE_QUESTION then
        advance(state)
        min, max = 0, 1

    elseif byte == BYTE_OPEN_BRACE then
        advance(state)

        local min_string = ""

        while peek(state) and is_digit(peek(state) :: number) do
            min_string ..= string.char(advance(state) :: number)
        end

        local parsed_min = tonumber(min_string)

        if not parsed_min then
            error("Invalid repetition count in '{}'.")
        end

        min = parsed_min
        max = parsed_min

        if peek(state) == BYTE_COMMA then
            advance(state)

            local max_string = ""

            while peek(state) and is_digit(peek(state) :: number) do
                max_string ..= string.char(advance(state) :: number)
            end

            max = if #max_string > 0 then tonumber(max_string) else nil
        end

        expect(state, BYTE_CLOSE_BRACE)

    else
        return false, 0, nil, true
    end

    local greedy = true

    if peek(state) == BYTE_QUESTION then
        advance(state)
        greedy = false
    end

    return true, min, max, greedy
end

local function parse_group(state: ParserState): HirNode
    -- Non-capturing group (?:...).
    if peek(state) == BYTE_QUESTION then
        local saved_pos = state.pos
        advance(state)

        if peek(state) == BYTE_COLON then
            advance(state)
            local inner = parse_alternation(state)
            expect(state, BYTE_CLOSE_PAREN)
            return hir.group(inner)
        end

        -- Unrecognized modifier after '(?'; backtrack.
        state.pos = saved_pos
    end

    local inner = parse_alternation(state)
    expect(state, BYTE_CLOSE_PAREN)
    return hir.group(inner)
end

local function parse_atom(state: ParserState): HirNode?
    local byte = peek(state)

    if not byte then
        return nil
    end

    if byte == BYTE_CLOSE_PAREN or byte == BYTE_PIPE then
        return nil
    end

    advance(state)

    if byte == BYTE_OPEN_PAREN then return parse_group(state) end
    if byte == BYTE_OPEN_BRACKET then return parse_class(state) end
    if byte == BYTE_DOT then return hir.dot() end
    if byte == BYTE_CARET then return hir.anchor("start") end
    if byte == BYTE_DOLLAR then return hir.anchor("end") end
    if byte == BYTE_BACKSLASH then return parse_escape(state) end

    return hir.literal(byte)
end

local function parse_repetition(state: ParserState): HirNode?
    local atom = parse_atom(state)

    if not atom then
        return nil
    end

    local found, min, max, greedy = parse_quantifier(state)

    if not found then
        return atom
    end

    return hir.repetition(atom, min, max, greedy)
end

local function parse_concat(state: ParserState): HirNode
    local children: { HirNode } = {}

    while not at_end(state) do
        local node = parse_repetition(state)

        if not node then
            break
        end

        table.insert(children, node)
    end

    if #children == 0 then
        return hir.empty()
    end

    return hir.concat(children)
end

parse_alternation = function(state: ParserState): HirNode
    local first = parse_concat(state)
    local branches: { HirNode } = { first }

    while peek(state) == BYTE_PIPE do
        advance(state)
        table.insert(branches, parse_concat(state))
    end

    return hir.alternation(branches)
end

function parser.parse(source: string): HirNode
    local state = new_parser(source)
    local result = parse_alternation(state)

    if not at_end(state) then
        error(`Unexpected character '{string.char(peek(state) :: number)}' at position {state.pos}.`)
    end

    return result
end

return parser
