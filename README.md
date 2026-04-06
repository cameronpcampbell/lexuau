# Lexuau
A lexer generation library for Luau.

Strongly inspired from [logos](https://github.com/maciejhirsz/logos).

## Example Usage

```luau
--!strict

local lexuau = require("path/to/lexuau")

local my_lexer = lexuau.new({
    skip = "[ \t\n\r\f]+",

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

print(lexed)

-- local	local_keyword
-- foo	    ident
-- =	    eq_sign
-- "hello"	string
-- local	local_keyword
-- bar	    ident
-- =	    eq_sign
-- 500_450.852	number
```
