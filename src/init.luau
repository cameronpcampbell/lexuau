--!strict

local regex_parser = require("@self/regex/parser")
local hir = require("@self/regex/hir")
local nfa = require("@self/regex/nfa")
local dfa = require("@self/regex/dfa")
local subpattern = require("@self/subpattern")
local lexer = require("@self/lexer")

type PatternConfig = string | {
    pattern: string,
    priority: number?,
    callback: ((string) -> string?)?,
}

type LexerConfig<Skip, SubPatternNames, PatternNames> = {
    skip: (Skip | "") & string,
    subpatterns: SubPatternNames & ({
        [string]: string
    }?),
    patterns: PatternNames & {
        [string]: PatternConfig
    }
}

type function FieldNames(input: type)
    assert(input.tag, "table")

    local names: { type } = {}

    for key in input:properties() do
        table.insert(names, key)
    end

    return types.unionof(table.unpack(names))
end

type TokenDisciminants<Ident> = {
    kind: Ident?,
    value: string
}

-- Check for pattern conflicts and raise an error listing them.
local function check_conflicts(
    conflicts: { dfa.Conflict },
    pattern_names: { [number]: string },
    pattern_priorities: { [number]: number }
)
    if #conflicts == 0 then
        return
    end

    -- Deduplicate conflicts by pattern pair.
    local seen: { [string]: boolean } = {}
    local unique: { string } = {}

    for _, conflict in conflicts do
        local name_a = pattern_names[conflict.pattern_a] or "(skip)"
        local name_b = pattern_names[conflict.pattern_b] or "(skip)"
        local key = `{name_a},{name_b}`
        if seen[key] then
            continue
        end
        seen[key] = true
        table.insert(unique, `  '{name_a}' and '{name_b}' (both priority {conflict.priority})`)
    end

    error(`Pattern conflicts detected:\n{table.concat(unique, "\n")}`)
end

local function new<Skip, SubPatternNames, PatternNames>(
    config: LexerConfig<Skip, SubPatternNames, PatternNames>
)
    -- Extract raw pattern strings for subpattern resolution.
    local raw_patterns: { [string]: string } = {}
    local user_priorities: { [string]: number? } = {}
    local callbacks: { [string]: ((string) -> string?)? } = {}

    for name, value in config.patterns :: { [string]: PatternConfig } do
        if type(value) == "string" then
            raw_patterns[name] = value
        else
            raw_patterns[name] = value.pattern
            user_priorities[name] = value.priority
            callbacks[name] = value.callback
        end
    end

    -- Resolve subpattern references in all patterns.
    local resolved_patterns = subpattern.resolve(
        config.subpatterns :: { [string]: string }?,
        raw_patterns
    )

    -- Build the pattern list: skip pattern first (index 1), then named patterns.
    local pattern_hirs = {}
    local pattern_names: { [number]: string } = {}
    local pattern_priorities: { [number]: number } = {}
    local pattern_callbacks: { [number]: (string) -> string? } = {}
    local skip_id: number? = nil

    -- Add skip pattern if provided.
    if config.skip ~= "" then
        local resolved_skip = subpattern.resolve(
            config.subpatterns :: { [string]: string }?,
            { _skip = config.skip }
        )._skip
        local skip_hir = regex_parser.parse(resolved_skip)
        table.insert(pattern_hirs, skip_hir)
        skip_id = #pattern_hirs
        -- Skip gets highest possible priority so it always wins at same length.
        pattern_priorities[skip_id] = math.huge
    end

    -- Add named patterns.
    for name, pattern_string in resolved_patterns do
        local parsed_hir = regex_parser.parse(pattern_string)
        table.insert(pattern_hirs, parsed_hir)

        local index = #pattern_hirs
        pattern_names[index] = name

        -- Use user-supplied priority if provided, otherwise compute from HIR.
        local user_priority = user_priorities[name]
        pattern_priorities[index] = if user_priority then user_priority else hir.priority(parsed_hir)

        local callback = callbacks[name]
        if callback then
            pattern_callbacks[index] = callback
        end
    end

    -- Build combined NFA from all patterns, then convert to optimized DFA.
    local combined_nfa = nfa.build(pattern_hirs)
    local compiled_dfa, conflicts = dfa.from_nfa(combined_nfa, pattern_priorities)
    check_conflicts(conflicts, pattern_names, pattern_priorities)

    return {
        lex = function(content: string)
            return lexer.new(
                compiled_dfa,
                skip_id :: number,
                pattern_names,
                pattern_callbacks,
                content
            ) :: () -> (string, FieldNames<PatternNames>)
        end
    }
end

return {
    new = new
}
