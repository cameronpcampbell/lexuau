--!strict

local lexuau = require("@src")

local my_lexer = lexuau.new({
    skip = "[ \t\n\r\f]+",
    init_state = function() return nil end,

    subpatterns = {
        numsect = "_*[\\d]+_*",
        num = "((?&numsect)+\\.)?(?&numsect)+|\\.(?&numsect)",
    },

    patterns = {
        local_keyword = "local",
        eq_sign = "=",
        ident = "[a-zA-Z_-]+",
        number = "(?&num)",
        string = "'[^']+'|\"[^\"]+\""
    }
})

local lexed = my_lexer.lex([[
    local foo = "hello"
    local bar = 500_450.852
]])

for value, kind in lexed do
    print(value, kind)
end
-- local	local_keyword
-- foo	    ident
-- =	    eq_sign
-- "hello"	string
-- local	local_keyword
-- bar	    ident
-- =	    eq_sign
-- 500_450.852	number
