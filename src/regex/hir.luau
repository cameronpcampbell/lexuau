--!strict

export type Range = { low: number, high: number }

export type HirNode =
    | { tag: "literal", byte: number }
    | { tag: "class", ranges: { Range }, negated: boolean }
    | { tag: "dot" }
    | { tag: "concat", children: { HirNode } }
    | { tag: "alternation", children: { HirNode } }
    | { tag: "repetition", child: HirNode, min: number, max: number?, greedy: boolean }
    | { tag: "group", child: HirNode }
    | { tag: "anchor", kind: "start" | "end" }
    | { tag: "empty" }

local hir = {}

function hir.literal(byte: number): HirNode
    return { tag = "literal", byte = byte }
end

function hir.class(ranges: { Range }, negated: boolean?): HirNode
    return { tag = "class", ranges = ranges, negated = negated or false }
end

function hir.dot(): HirNode
    return { tag = "dot" }
end

function hir.concat(children: { HirNode }): HirNode
    if #children == 1 then
        return children[1]
    end
    return { tag = "concat", children = children }
end

function hir.alternation(children: { HirNode }): HirNode
    if #children == 1 then
        return children[1]
    end
    return { tag = "alternation", children = children }
end

function hir.repetition(child: HirNode, min: number, max: number?, greedy: boolean?): HirNode
    return {
        tag = "repetition",
        child = child,
        min = min,
        max = max,
        greedy = if greedy == nil then true else greedy,
    }
end

function hir.group(child: HirNode): HirNode
    return { tag = "group", child = child }
end

function hir.anchor(kind: "start" | "end"): HirNode
    return { tag = "anchor", kind = kind }
end

function hir.empty(): HirNode
    return { tag = "empty" }
end

-- Predefined character classes as sorted ranges of byte values.
hir.classes = {}

hir.classes.digit = { { low = 0x30, high = 0x39 } }

hir.classes.word = {
    { low = 0x30, high = 0x39 },
    { low = 0x41, high = 0x5A },
    { low = 0x5F, high = 0x5F },
    { low = 0x61, high = 0x7A },
}

hir.classes.space = {
    { low = 0x09, high = 0x0D },
    { low = 0x20, high = 0x20 },
}

function hir.negate_class(ranges: { Range }): { Range }
    local sorted = table.clone(ranges)
    table.sort(sorted, function(left: Range, right: Range) return left.low < right.low end)

    local result: { Range } = {}
    local position = 0

    for _, range in sorted do
        if range.low > position then
            table.insert(result, { low = position, high = range.low - 1 })
        end
        position = range.high + 1
    end

    if position <= 255 then
        table.insert(result, { low = position, high = 255 })
    end

    return result
end

-- Compute priority from HIR structure, matching Logos's formula.
-- Higher priority wins when multiple patterns match same length.
function hir.priority(node: HirNode): number
    if node.tag == "literal" or node.tag == "class" or node.tag == "dot" then
        return 2

    elseif node.tag == "concat" then
        local total = 0
        for _, child in node.children do
            total += hir.priority(child)
        end
        return total

    elseif node.tag == "alternation" then
        local minimum = math.huge
        for _, child in node.children do
            minimum = math.min(minimum, hir.priority(child))
        end
        return minimum

    elseif node.tag == "repetition" then
        return node.min * hir.priority(node.child)

    elseif node.tag == "group" then
        return hir.priority(node.child)
    end

    -- Anchor, empty.
    return 0
end

return hir
