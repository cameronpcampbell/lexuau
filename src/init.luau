--!strict
--!optimize 2

local regex_parser = require("@self/regex/parser")
local hir = require("@self/regex/hir")
local nfa = require("@self/regex/nfa")
local dfa = require("@self/regex/dfa")
local subpattern = require("@self/subpattern")
local lexer = require("@self/lexer")

export type PatternConfig<S> = string | {
    pattern: string,
    priority: number?,
    callback: ((string, lexer.Session<S>) -> (string?, {
        _profile: lexer.Profile<S>
    }))?,
}

export type LexerConfig<S> = {
    skip: string?,
    init_state: () -> S,
    subpatterns: {
        [string]: string
    }?,
    patterns: {
        [string]: PatternConfig<S>
    }
}

export type Lexer<S> = {
    _profile: lexer.Profile<S>,
    _patterns: { [string]: string },
    lex: (content: string) -> () -> (string, string?),
}

local function check_conflicts(
    conflicts: { dfa.Conflict },
    pattern_names: { [number]: string },
    pattern_priorities: { [number]: number }
)
    if #conflicts == 0 then
        return
    end

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

local function new<S>(
    config: LexerConfig<S>
): Lexer<S>
    local raw_patterns: { [string]: string } = {}
    local user_priorities: { [string]: number? } = {}
    local callbacks: { [string]: ((string, lexer.Session<S>) -> (string?, lexer.Session<S>?))? } = {}

    for name, value in config.patterns do
        if type(value) == "string" then
            raw_patterns[name] = value
        else
            raw_patterns[name] = value.pattern
            user_priorities[name] = value.priority
            callbacks[name] = value.callback :: any
        end
    end

    local resolved_patterns = subpattern.resolve(
        config.subpatterns :: { [string]: string }?,
        raw_patterns
    )

    -- Skip pattern is always index 1 so the lexer can identify it.
    local pattern_hirs = {}
    local pattern_names: { [number]: string } = {}
    local pattern_priorities: { [number]: number } = {}
    local pattern_callbacks: { [number]: (string, lexer.Session<S>) -> (string?, lexer.Session<S>?) } = {}
    local skip_id: number? = nil

    if config.skip ~= nil and (config :: LexerConfig).skip ~= "" then
        local resolved_skip = subpattern.resolve(
            (config :: LexerConfig).subpatterns :: { [string]: string }?,
            { _skip = (config :: LexerConfig).skip }
        )._skip

        local skip_hir = regex_parser.parse(resolved_skip)

        table.insert(pattern_hirs, skip_hir)
        skip_id = #pattern_hirs

        pattern_priorities[skip_id] = math.huge
    end

    for name, pattern_string in resolved_patterns do
        local parsed_hir = regex_parser.parse(pattern_string)
        table.insert(pattern_hirs, parsed_hir)

        local index = #pattern_hirs
        pattern_names[index] = name

        local user_priority = user_priorities[name]
        pattern_priorities[index] = if user_priority then user_priority else hir.priority(parsed_hir)

        local callback = callbacks[name]

        if callback then
            pattern_callbacks[index] = callback
        end
    end

    local combined_nfa = nfa.build(pattern_hirs)
    local compiled_dfa, conflicts = dfa.from_nfa(combined_nfa, pattern_priorities)

    check_conflicts(conflicts, pattern_names, pattern_priorities)

    local profile: lexer.Profile<S> = {
        compiled_dfa = compiled_dfa,
        skip_id = skip_id,
        pattern_names = pattern_names,
        pattern_callbacks = pattern_callbacks,
        init_state = config.init_state,
    }

    return {
        _profile = profile,
        _patterns = {},
        lex = function(content: string)
            return lexer.new(profile, content, profile.init_state()) :: any
        end,
    }
end

return {
    new = new
}
