--!strict

local lexer = require("@src")

-- Test 1: Basic morph (outer -> inner -> outer).
local outer = lexer.new({
	skip = "[ \t\n]+",
	subpatterns = {},
	patterns = {
		start_string = '"',
		ident = "[a-zA-Z]+",
	},
})

local inner = lexer.new({
    subpatterns = {},
	patterns = {
		text = '[^"\\\\]+',
		escape = "\\\\.",
		end_string = '"',
	},
})

print("=== Basic morph test ===")
local session = outer.lex('"hello" world')
local iterate = session:iter()

while true do
	local value, kind = iterate()
	if not value then break end

	if kind == "start_string" then
		local inner_session = session:morph(inner)
		for inner_value, inner_kind in inner_session do
			if inner_kind == "end_string" then
				session = inner_session:morph(outer)
				iterate = session:iter()
				break
			end
			print(`[{inner_value}]`, inner_kind)
		end
	else
		print(`[{value}]`, kind)
	end
end
-- Expected:
-- [hello]  text
-- [world]  ident

-- Test 2: Morphing to same lexer.
print("\n=== Morph to same lexer ===")
local simple = lexer.new({
	skip = "[ ]+",
	subpatterns = {},
	patterns = {
		word = "[a-z]+",
	},
})

local session2 = simple.lex("hello world")

for value, kind in session2 do
	if value == "hello" then
		session2 = session2:morph(simple)
		for value2, kind2 in session2 do
			print(`[{value2}]`, kind2)
		end
		break
	end
end
-- Expected:
-- [world]  word

-- Test 3: Iterating a morphed session returns nil.
print("\n=== Morphed session is invalid ===")
local session3 = simple.lex("hello world")

for value, kind in session3 do
	if value == "hello" then
		local new_session = session3:morph(simple)
		break
	end
end

-- Iterating the old session should produce nothing.
local count = 0
for value, kind in session3 do
	count += 1
end
print(`Tokens from morphed session: {count}`)
-- Expected:
-- Tokens from morphed session: 0

-- Test 4: Morph with escape sequences inside string.
print("\n=== Morph with escapes ===")
local session4 = outer.lex('"he\\nllo" end')
local iterate4 = session4:iter()

while true do
	local value, kind = iterate4()
	if not value then break end

	if kind == "start_string" then
		local inner_session = session4:morph(inner)
		for inner_value, inner_kind in inner_session do
			if inner_kind == "end_string" then
				session4 = inner_session:morph(outer)
				iterate4 = session4:iter()
				break
			end
			print(`[{inner_value}]`, inner_kind)
		end
	else
		print(`[{value}]`, kind)
	end
end
-- Expected:
-- [he]     text
-- [\n]     escape
-- [llo]    text
-- [end]    ident
