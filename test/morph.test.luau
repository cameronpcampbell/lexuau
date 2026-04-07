--!strict

local lexuau = require("@src")
local types = require("./types")

-- Morph between outer (code) and inner (string contents) lexers.
local inner

local outer = lexuau.new({
	skip = "[ \t\n]+",
	init_state = function() return nil end,
	subpatterns = {},
	patterns = {
		comment_start = {
			pattern = '<!--',
			callback = function(value: string, lexer)
				return value, lexer:morph(inner :: types.NonNullable<typeof(inner)>)
			end,
		}
	},
})

inner = lexuau.new({
	skip = nil,
	init_state = function() return nil end,
	subpatterns = {},
	patterns = {

		comment_end = {
			pattern = '-->',
			callback = function(value: string, session)
				return value, session:morph(outer)
			end,
		},
	},
})

print("=== Basic morph ===")
for value, kind in outer.lex('<!--hello-->') do
	print(`[{value}]`, kind)
end
-- ["]      start_string
-- [hello]  text
-- ["]      end_string
-- [world]  ident
