local lexer = require("@src")

-- Test 1: Priority: "for" literal (priority 6) should beat [a-zA-Z]+ (priority 2).
local keyword_lexer = lexer.new({
    skip = "[ \t\n]+",
    init_state = function() return nil end,
    patterns = {
        keyword_for = "for",
        ident = "[a-zA-Z]+",
    }
})

print("=== Priority test ===")
for value, kind in keyword_lexer.lex("for foreach x") do
    print(`[{value}]`, kind)
end
-- Expected:
-- [for]    keyword_for
-- [foreach] ident
-- [x]      ident

-- Test 2: Callback: transform value.
local transform_lexer = lexer.new({
    skip = "[ \t\n]+",
    init_state = function() return nil end,
    patterns = {
        upper_ident = {
            pattern = "[a-zA-Z]+",
            callback = function(value: string): string?
                return string.upper(value)
            end,
        },
        number = "[0-9]+",
    }
})

print("\n=== Callback transform test ===")
for value, kind in transform_lexer.lex("hello 42 world") do
    print(`[{value}]`, kind)
end
-- Expected:
-- [HELLO]  upper_ident
-- [42]     number
-- [WORLD]  upper_ident

-- Test 3: Callback: skip (return nil).
local skip_lexer = lexer.new({
    skip = "[ \t\n]+",
    init_state = function() return nil end,
    patterns = {
        comment = {
            pattern = "//[^\n]*",
            callback = function(value: string): string?
                return nil -- Skip comments.
            end,
        },
        ident = "[a-zA-Z]+",
        number = "[0-9]+",
    }
})

print("\n=== Callback skip test ===")
for value, kind in skip_lexer.lex("hello //comment\nworld") do
    print(`[{value}]`, kind)
end
-- Expected:
-- [hello]  ident
-- [world]  ident

-- Test 4: Explicit priority override.
local override_lexer = lexer.new({
    skip = "[ \t\n]+",
    init_state = function() return nil end,
    patterns = {
        ident = {
            pattern = "[a-zA-Z]+",
            priority = 100,
        },
        keyword = "for",
    }
})

print("\n=== Priority override test ===")
for value, kind in override_lexer.lex("for x") do
    print(`[{value}]`, kind)
end
-- Expected (ident has priority 100, keyword_for has auto priority 6):
-- [for]    ident
-- [x]      ident
