--!strict

local hir = require("./hir")
type HirNode = hir.HirNode
type Range = hir.Range

export type NFAState = {
    id: number,
    transitions: { { ranges: { Range }, target: number } },
    epsilon: { number },
    accept: number?,
}

export type NFA = {
    states: { [number]: NFAState },
    start: number,
    _next_id: number,
}

type Fragment = {
    start: number,
    finish: number,
}

local nfa = {}

local function new_state(automaton: NFA): NFAState
    local id = automaton._next_id
    automaton._next_id += 1

    local state: NFAState = {
        id = id,
        transitions = {},
        epsilon = {},
        accept = nil,
    }

    automaton.states[id] = state
    return state
end

local function add_epsilon(automaton: NFA, from: number, to: number)
    table.insert(automaton.states[from].epsilon, to)
end

local function add_transition(automaton: NFA, from: number, ranges: { Range }, to: number)
    table.insert(automaton.states[from].transitions, { ranges = ranges, target = to })
end

-- Swaps epsilon order so the "skip" branch is tried first (lazy quantifier).
local function make_lazy(automaton: NFA, state_id: number)
    local epsilon_list = automaton.states[state_id].epsilon

    epsilon_list[#epsilon_list], epsilon_list[#epsilon_list - 1] =
        epsilon_list[#epsilon_list - 1], epsilon_list[#epsilon_list]
end

local DOT_RANGES: { Range } = {
    { low = 0x00, high = 0x09 },
    { low = 0x0B, high = 0xFF },
}

local function chain_fragments(automaton: NFA, fragments: { Fragment }): Fragment
    for index = 1, #fragments - 1 do
        add_epsilon(automaton, fragments[index].finish, fragments[index + 1].start)
    end

    return { start = fragments[1].start, finish = fragments[#fragments].finish }
end

local function build_optional(automaton: NFA, node: HirNode, greedy: boolean): Fragment
    local start_state = new_state(automaton)
    local end_state = new_state(automaton)
    local fragment = build_fragment(automaton, node)

    add_epsilon(automaton, start_state.id, fragment.start)
    add_epsilon(automaton, start_state.id, end_state.id)
    add_epsilon(automaton, fragment.finish, end_state.id)

    if not greedy then
        make_lazy(automaton, start_state.id)
    end

    return { start = start_state.id, finish = end_state.id }
end

local function build_star(automaton: NFA, node: HirNode, greedy: boolean): Fragment
    local start_state = new_state(automaton)
    local end_state = new_state(automaton)
    local fragment = build_fragment(automaton, node)

    add_epsilon(automaton, start_state.id, fragment.start)
    add_epsilon(automaton, start_state.id, end_state.id)
    add_epsilon(automaton, fragment.finish, fragment.start)
    add_epsilon(automaton, fragment.finish, end_state.id)

    if not greedy then
        make_lazy(automaton, start_state.id)
    end

    return { start = start_state.id, finish = end_state.id }
end

local function build_plus(automaton: NFA, node: HirNode, greedy: boolean): Fragment
    local start_state = new_state(automaton)
    local end_state = new_state(automaton)
    local fragment = build_fragment(automaton, node)

    add_epsilon(automaton, start_state.id, fragment.start)
    add_epsilon(automaton, fragment.finish, fragment.start)
    add_epsilon(automaton, fragment.finish, end_state.id)

    if not greedy then
        make_lazy(automaton, fragment.finish)
    end

    return { start = start_state.id, finish = end_state.id }
end

local function build_bounded(automaton: NFA, node: HirNode, min: number, max: number, greedy: boolean): Fragment
    local fragments: { Fragment } = {}

    for _ = 1, min do
        table.insert(fragments, build_fragment(automaton, node))
    end

    for _ = 1, max - min do
        table.insert(fragments, build_optional(automaton, node, greedy))
    end

    if #fragments == 0 then
        local empty_state = new_state(automaton)
        return { start = empty_state.id, finish = empty_state.id }
    end

    return chain_fragments(automaton, fragments)
end

local function build_unbounded(automaton: NFA, node: HirNode, min: number, greedy: boolean): Fragment
    local fragments: { Fragment } = {}

    for _ = 1, min do
        table.insert(fragments, build_fragment(automaton, node))
    end

    table.insert(fragments, build_star(automaton, node, greedy))

    return chain_fragments(automaton, fragments)
end

function build_fragment(automaton: NFA, node: HirNode): Fragment
    if node.tag == "empty" or node.tag == "anchor" then
        local only_state = new_state(automaton)
        return { start = only_state.id, finish = only_state.id }

    elseif node.tag == "literal" then
        local start_state = new_state(automaton)
        local end_state = new_state(automaton)
        add_transition(automaton, start_state.id, { { low = node.byte, high = node.byte } }, end_state.id)
        return { start = start_state.id, finish = end_state.id }

    elseif node.tag == "dot" then
        local start_state = new_state(automaton)
        local end_state = new_state(automaton)
        add_transition(automaton, start_state.id, DOT_RANGES, end_state.id)
        return { start = start_state.id, finish = end_state.id }

    elseif node.tag == "class" then
        local start_state = new_state(automaton)
        local end_state = new_state(automaton)
        local ranges = if node.negated then hir.negate_class(node.ranges) else node.ranges
        add_transition(automaton, start_state.id, ranges, end_state.id)
        return { start = start_state.id, finish = end_state.id }

    elseif node.tag == "concat" then
        local fragments: { Fragment } = {}

        for _, child in node.children do
            table.insert(fragments, build_fragment(automaton, child))
        end

        return chain_fragments(automaton, fragments)

    elseif node.tag == "alternation" then
        local start_state = new_state(automaton)
        local end_state = new_state(automaton)

        for _, child in node.children do
            local fragment = build_fragment(automaton, child)
            add_epsilon(automaton, start_state.id, fragment.start)
            add_epsilon(automaton, fragment.finish, end_state.id)
        end

        return { start = start_state.id, finish = end_state.id }

    elseif node.tag == "repetition" then
        local min = node.min
        local max = node.max
        local greedy = node.greedy

        return
            if min == 0 and max == nil then
                build_star(automaton, node.child, greedy)

            elseif min == 1 and max == nil then
                build_plus(automaton, node.child, greedy)

            elseif min == 0 and max == 1 then
                build_optional(automaton, node.child, greedy)

            elseif max then
                build_bounded(automaton, node.child, min, max, greedy)

            else build_unbounded(automaton, node.child, min, greedy)

    elseif node.tag == "group" then
        return build_fragment(automaton, node.child)
    end

    error(`Unknown HIR node tag.`)
end

-- Single start state with epsilon transitions to each pattern's NFA.
-- Accept state for pattern i is tagged with index i.
function nfa.build(patterns: { HirNode }): NFA
    local automaton: NFA = {
        states = {},
        start = 0,
        _next_id = 0,
    }

    local start_state = new_state(automaton)
    automaton.start = start_state.id

    for index, pattern in patterns do
        local fragment = build_fragment(automaton, pattern)

        add_epsilon(automaton, start_state.id, fragment.start)

        automaton.states[fragment.finish].accept = index
    end

    return automaton
end

function nfa.epsilon_closure(automaton: NFA, state_ids: { number }): { number }
    local visited: { [number]: boolean } = {}
    local stack = table.clone(state_ids)
    local result: { number } = {}

    while #stack > 0 do
        local current = table.remove(stack) :: number

        if visited[current] then
            continue
        end

        visited[current] = true
        table.insert(result, current)

        for _, target in automaton.states[current].epsilon do
            if not visited[target] then
                table.insert(stack, target)
            end
        end
    end

    table.sort(result)

    return result
end

function nfa.move(automaton: NFA, state_ids: { number }, byte: number): { number }
    local result: { number } = {}
    local seen: { [number]: boolean } = {}

    for _, state_id in state_ids do
        for _, transition in automaton.states[state_id].transitions do
            if seen[transition.target] then
                continue
            end

            for _, range in transition.ranges do
                if byte < range.low or byte > range.high then
                    continue
                end

                seen[transition.target] = true

                table.insert(result, transition.target)

                break
            end
        end
    end

    return result
end

return nfa
