# Lexuau
A lexer generation library for Luau.

Strongly inspired from [logos](https://github.com/maciejhirsz/logos).

## Installation

Install the package matching your environment with Pesde.

For Roblox:

```sh
pesde add cameronpcampbell/lexuau@0.1.0 -t roblox
```

```toml
[dependencies]
lexuau = { name = "cameronpcampbell/lexuau", version = "^0.1.0", target = "roblox" }
```

For standalone Luau:

```sh
pesde add cameronpcampbell/lexuau@0.1.0 -t luau
```

```toml
[dependencies]
lexuau = { name = "cameronpcampbell/lexuau", version = "^0.1.0", target = "luau" }
```

The repository keeps Roblox as its canonical development target. Releases publish
both target variants from the same source and version.

## Example Usage

The example below uses a Roblox package path. For standalone Luau, require
`./luau_packages/lexuau` instead.

```luau
--!strict

local lexuau = require(path.to.lexuau)

local my_lexer = lexuau.new({
    skip = "[ \t\n\r\f]+",
    init_state = function()
        return nil
    end,

    subpatterns = {
        numsect = "_*[\\d]+_*",
        num = "((?&numsect)+\\.)?(?&numsect)+|\\.(?&numsect)",
    },

    patterns = {
        local_keyword = "local",
        eq_sign = "=",
        ident = "[a-zA-Z_-]+",
        number = "(?&num)",
        string = "'[^']+'|\"[^\"]+\"",
    },
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
```
