local lexer = require("@src")

-- Two patterns with the same priority that match the same input should conflict.
local ok, err = pcall(function()
    lexer.new({
        skip = "[ \t\n]+",
        patterns = {
            alpha = "[a-zA-Z]+",
            word = "[a-zA-Z]+",
        }
    })
end)

print("=== Conflict detection test ===")
print("Should error:", not ok)
print("Error:", err)

-- No conflict: different priorities.
local ok2, err2 = pcall(function()
    lexer.new({
        skip = "[ \t\n]+",
        patterns = {
            alpha = {
                pattern = "[a-zA-Z]+",
                priority = 10,
            },
            word = "[a-zA-Z]+",
        }
    })
end)

print("\n=== No conflict with different priorities ===")
print("Should succeed:", ok2)
