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
			callback = function(value: string, state)
				return value, inner :: types.NonNullable<typeof(inner)>
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
			callback = function(value: string, state)
				return value, outer
			end,
		},
	},
})

print("=== Basic morph ===")
for value, kind in outer.lex('<!--hello-->') do
	print(`[{value}]`, kind)
end
-- [<!--]   comment_start
-- [h]      nil
-- [e]      nil
-- [l]      nil
-- [l]      nil
-- [o]      nil
-- [-->]    comment_end
