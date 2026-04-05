--!strict

local regex_parser = require("@self/regex/parser")
local nfa = require("@self/regex/nfa")
local dfa = require("@self/regex/dfa")
local subpattern = require("@self/subpattern")
local lexer = require("@self/lexer")

type LexerConfig<Skip, SubPatternNames, PatternNames> = {
    skip: (Skip | "") & string,
    subpatterns: SubPatternNames & ({
        [string]: string
    }?),
    patterns: PatternNames & {
        [string]: string
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

local function new<Skip, SubPatternNames, PatternNames>(
    config: LexerConfig<Skip, SubPatternNames, PatternNames>
)
    -- Resolve subpattern references in all patterns.
    local resolved_patterns = subpattern.resolve(
        config.subpatterns :: { [string]: string }?,
        config.patterns :: { [string]: string }
    )

    -- Build the pattern list: skip pattern first (index 1), then named patterns.
    local pattern_hirs = {}
    local pattern_names: { [number]: string } = {}
    local skip_id: number? = nil

    -- Add skip pattern if provided.
    if config.skip ~= "" then
        -- Resolve subpatterns in the skip pattern too.
        local resolved_skip = subpattern.resolve(
            config.subpatterns :: { [string]: string }?,
            { _skip = config.skip }
        )._skip
        table.insert(pattern_hirs, regex_parser.parse(resolved_skip))
        skip_id = #pattern_hirs
    end

    -- Add named patterns.
    for name, pattern_string in resolved_patterns do
        table.insert(pattern_hirs, regex_parser.parse(pattern_string))
        pattern_names[#pattern_hirs] = name
    end

    -- Build combined NFA from all patterns, then convert to optimized DFA.
    local combined_nfa = nfa.build(pattern_hirs)
    local compiled_dfa = dfa.from_nfa(combined_nfa)

    return {
        lex = function(content: string)
            return lexer.new(
                compiled_dfa,
                skip_id :: number,
                pattern_names,
                content
            ) :: () -> (string, FieldNames<PatternNames>)
        end
    }
end

return {
    new = new
}
