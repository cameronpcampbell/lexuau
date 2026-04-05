--!strict

local hir = require("./hir")
type HirNode = hir.HirNode
type Range = hir.Range

local parser = {}

type ParserState = {
    source: string,
    pos: number,
}

local function new_parser(source: string): ParserState
    return { source = source, pos = 1 }
end

local function peek(state: ParserState): number?
    if state.pos > #state.source then
        return nil
    end
    local byte = string.byte(state.source, state.pos)
    return byte
end

local function advance(state: ParserState): number?
    local byte = peek(state)
    if not byte then
        return nil
    end
    state.pos += 1
    return byte
end

local function expect(state: ParserState, expected_byte: number)
    local byte = advance(state)
    if byte == expected_byte then
        return
    end
    error(
        `Expected '{string.char(expected_byte)}' at position {state.pos - 1}, got '{if byte then string.char(byte) else "EOF"}'.`
    )
end

local function at_end(state: ParserState): boolean
    return state.pos > #state.source
end

-- Forward declaration for recursive descent.
local parse_alternation: (state: ParserState) -> HirNode

-- Escape sequence lookup tables.
local ESCAPE_CLASSES: { [string]: () -> HirNode } = {
    d = function() return hir.class(hir.classes.digit) end,
    D = function() return hir.class(hir.negate_class(hir.classes.digit)) end,
    w = function() return hir.class(hir.classes.word) end,
    W = function() return hir.class(hir.negate_class(hir.classes.word)) end,
    s = function() return hir.class(hir.classes.space) end,
    S = function() return hir.class(hir.negate_class(hir.classes.space)) end,
}

local ESCAPE_LITERALS: { [string]: number } = {
    t = 0x09, n = 0x0A, r = 0x0D, f = 0x0C, v = 0x0B, ["0"] = 0x00,
}

local function parse_escape(state: ParserState): HirNode
    local byte = advance(state)
    if not byte then
        error("Unexpected end of pattern after '\\'.")
    end

    local char = string.char(byte)

    local class_fn = ESCAPE_CLASSES[char]
    if class_fn then
        return class_fn()
    end

    local literal_byte = ESCAPE_LITERALS[char]
    if literal_byte then
        return hir.literal(literal_byte)
    end

    if char ~= "x" then
        -- Escaped literal (., *, +, ?, etc.).
        return hir.literal(byte)
    end

    -- Hexadecimal escape: \xHH.
    local hex_high = advance(state)
    local hex_low = advance(state)
    if not hex_high or not hex_low then
        error("Incomplete hex escape '\\x'.")
    end
    local hex_string = string.char(hex_high) .. string.char(hex_low)
    local hex_value = tonumber(hex_string, 16)
    if not hex_value then
        error(`Invalid hex escape '\\x{hex_string}'.`)
    end
    return hir.literal(hex_value)
end

-- Class-context escape lookup tables.
local CLASS_ESCAPE_RANGES: { [string]: { Range } } = {
    d = hir.classes.digit,
    D = hir.negate_class(hir.classes.digit),
    w = hir.classes.word,
    W = hir.negate_class(hir.classes.word),
    s = hir.classes.space,
    S = hir.negate_class(hir.classes.space),
    t = { { low = 0x09, high = 0x09 } },
    n = { { low = 0x0A, high = 0x0A } },
    r = { { low = 0x0D, high = 0x0D } },
    f = { { low = 0x0C, high = 0x0C } },
    v = { { low = 0x0B, high = 0x0B } },
}

local function parse_class_escape(state: ParserState): { Range }
    local byte = advance(state)
    if not byte then
        error("Unexpected end of pattern in character class after '\\'.")
    end

    local mapped = CLASS_ESCAPE_RANGES[string.char(byte)]
    if mapped then
        return mapped
    end

    -- Escaped literal inside class.
    return { { low = byte, high = byte } }
end

-- Try to consume the next single byte value inside a character class.
-- Returns nil if it was a shorthand class (ranges added directly).
local function next_class_atom(state: ParserState, ranges: { Range }): number?
    local byte = peek(state)
    if not byte or byte == 0x5D then -- ']'
        return nil
    end
    advance(state)

    if byte ~= 0x5C then -- Not '\'.
        return byte
    end

    local escape_ranges = parse_class_escape(state)

    -- If escape produced a range (not a single byte), add directly and return nil.
    if #escape_ranges > 1 or (escape_ranges[1] and escape_ranges[1].low ~= escape_ranges[1].high) then
        for _, range in escape_ranges do
            table.insert(ranges, range)
        end
        return nil
    end

    return escape_ranges[1].low
end

local function parse_class(state: ParserState): HirNode
    -- Opening '[' already consumed.
    local negated = peek(state) == 0x5E -- '^'
    if negated then
        advance(state)
    end

    local ranges: { Range } = {}

    while peek(state) and peek(state) ~= 0x5D do
        local low = next_class_atom(state, ranges)
        if low == nil then
            -- Was a shorthand class, already added to ranges.
            continue
        end

        -- Not a range, just a single character.
        if peek(state) ~= 0x2D then -- '-'
            table.insert(ranges, { low = low, high = low })
            continue
        end

        -- Consume '-'.
        advance(state)

        -- Trailing '-', treat as two literals.
        if peek(state) == 0x5D or peek(state) == nil then
            table.insert(ranges, { low = low, high = low })
            table.insert(ranges, { low = 0x2D, high = 0x2D })
            continue
        end

        local high = next_class_atom(state, ranges)

        -- '-' followed by shorthand class; treat '-' as literal.
        if high == nil then
            table.insert(ranges, { low = low, high = low })
            table.insert(ranges, { low = 0x2D, high = 0x2D })
            continue
        end

        table.insert(ranges, { low = low, high = high })
    end

    expect(state, 0x5D) -- ']'

    if negated then
        ranges = hir.negate_class(ranges)
    end

    return hir.class(ranges)
end

local function is_digit(byte: number): boolean
    return byte >= 0x30 and byte <= 0x39
end

local function parse_quantifier(state: ParserState): (boolean, number, number?, boolean)
    local byte = peek(state)
    if not byte then
        return false, 0, nil, true
    end

    local char = string.char(byte)
    local min: number
    local max: number? = nil

    if char == "*" then
        advance(state)
        min, max = 0, nil
    elseif char == "+" then
        advance(state)
        min, max = 1, nil
    elseif char == "?" then
        advance(state)
        min, max = 0, 1
    elseif char == "{" then
        advance(state)
        -- Parse {n}, {n,}, {n,m}.
        local min_string = ""
        while peek(state) and is_digit(peek(state) :: number) do
            min_string ..= string.char(advance(state) :: number)
        end
        local parsed_min = tonumber(min_string)
        if not parsed_min then
            error("Invalid repetition count in '{}'.")
        end
        min = parsed_min
        max = parsed_min

        if peek(state) == 0x2C then -- ','
            advance(state)
            local max_string = ""
            while peek(state) and is_digit(peek(state) :: number) do
                max_string ..= string.char(advance(state) :: number)
            end
            max = if #max_string > 0 then tonumber(max_string) else nil
        end

        expect(state, 0x7D) -- '}'
    else
        return false, 0, nil, true
    end

    -- Check for lazy modifier.
    local greedy = true
    if peek(state) == 0x3F then -- '?'
        advance(state)
        greedy = false
    end

    return true, min, max, greedy
end

local function parse_group(state: ParserState): HirNode
    -- Opening '(' already consumed.

    -- Check for non-capturing group (?:...).
    if peek(state) == 0x3F then -- '?'
        local saved_pos = state.pos
        advance(state)
        if peek(state) == 0x3A then -- ':'
            advance(state)
            local inner = parse_alternation(state)
            expect(state, 0x29) -- ')'
            return hir.group(inner)
        end
        -- Unknown group modifier; backtrack.
        state.pos = saved_pos
    end

    local inner = parse_alternation(state)
    expect(state, 0x29) -- ')'
    return hir.group(inner)
end

local function parse_atom(state: ParserState): HirNode?
    local byte = peek(state)
    if not byte then
        return nil
    end

    local char = string.char(byte)

    -- These characters end the current context.
    if char == ")" or char == "|" then
        return nil
    end

    advance(state)

    if char == "(" then return parse_group(state) end
    if char == "[" then return parse_class(state) end
    if char == "." then return hir.dot() end
    if char == "^" then return hir.anchor("start") end
    if char == "$" then return hir.anchor("end") end
    if char == "\\" then return parse_escape(state) end

    return hir.literal(byte)
end

local function parse_repetition(state: ParserState): HirNode?
    local atom = parse_atom(state)
    if not atom then
        return nil
    end

    local found, min, max, greedy = parse_quantifier(state)
    if not found then
        return atom
    end

    return hir.repetition(atom, min, max, greedy)
end

local function parse_concat(state: ParserState): HirNode
    local children: { HirNode } = {}

    while not at_end(state) do
        local node = parse_repetition(state)
        if not node then
            break
        end
        table.insert(children, node)
    end

    if #children == 0 then
        return hir.empty()
    end

    return hir.concat(children)
end

parse_alternation = function(state: ParserState): HirNode
    local first = parse_concat(state)
    local branches: { HirNode } = { first }

    while peek(state) == 0x7C do -- '|'
        advance(state)
        table.insert(branches, parse_concat(state))
    end

    return hir.alternation(branches)
end

function parser.parse(source: string): HirNode
    local state = new_parser(source)
    local result = parse_alternation(state)
    if not at_end(state) then
        error(`Unexpected character '{string.char(peek(state) :: number)}' at position {state.pos}.`)
    end
    return result
end

return parser
