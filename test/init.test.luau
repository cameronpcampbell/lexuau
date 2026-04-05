--!strict

local lexer = require("@src")

local my_lexer = lexer.new({
    skip = "[ \t\n\r\f]+",

    subpatterns = {
        numsect = "_*[\d]+_*",
        num = "((?&numsect)+\.)?(?&numsect)+|\.(?&numsect)"
    },

    patterns = {
        ident = "[a-zA-Z_-]+",
        number = "(?&num)"
    }
})

local lexed = my_lexer.lex("hello 5 + world")

for value, kind in lexed do
    print(value, kind)
end

-- "hello", "ident"
-- "5", "number"
-- "+", nil
-- "world", "ident"
