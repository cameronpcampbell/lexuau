--!strict
--!optimize 2

local nfa = require("./nfa")
type NFA = nfa.NFA

export type DFAState = {
    id: number,
    transitions: { [number]: number },
    accept: number?,
}

export type DFA = {
    states: { [number]: DFAState },
    start: number,
}

local dfa = {}

local function state_set_key(ids: { number }): string
    return table.concat(ids, ",")
end

export type Conflict = {
    pattern_a: number,
    pattern_b: number,
    priority: number,
}

-- Highest priority wins. Lowest pattern index breaks ties.
-- Records a conflict when multiple patterns share the top priority.
local function find_accept(
    automaton: NFA,
    nfa_ids: { number },
    priorities: { [number]: number },
    conflicts: { Conflict }
): number?
    local accepting: { { id: number, priority: number } } = {}

    for _, state_id in nfa_ids do
        local accept = automaton.states[state_id].accept

        if not accept then
            continue
        end

        local priority = priorities[accept] or 0
        table.insert(accepting, { id = accept, priority = priority })
    end

    if #accepting == 0 then
        return nil
    end

    local best_priority = -math.huge

    for _, entry in accepting do
        if entry.priority > best_priority then
            best_priority = entry.priority
        end
    end

    local top: { number } = {}
    local seen: { [number]: boolean } = {}

    for _, entry in accepting do
        if entry.priority ~= best_priority or seen[entry.id] then
            continue
        end

        seen[entry.id] = true
        table.insert(top, entry.id)
    end

    if #top > 1 then
        table.sort(top)

        for index = 2, #top do
            table.insert(conflicts, {
                pattern_a = top[1],
                pattern_b = top[index],
                priority = best_priority,
            })
        end
    end

    table.sort(top)
    return top[1]
end

local function collect_active_bytes(automaton: NFA, nfa_ids: { number }): { number }
    local seen: { [number]: boolean } = {}
    local result: { number } = {}

    for _, state_id in nfa_ids do
        for _, transition in automaton.states[state_id].transitions do
            for _, range in transition.ranges do
                for byte = range.low, range.high do
                    if seen[byte] then
                        continue
                    end

                    seen[byte] = true
                    table.insert(result, byte)
                end
            end
        end
    end

    table.sort(result)

    return result
end

-- Subset (powerset) construction.
function dfa.build(automaton: NFA, priorities: { [number]: number }): (DFA, { Conflict })
    local result: DFA = {
        states = {},
        start = 0,
    }
    local conflicts: { Conflict } = {}

    local next_id = 1
    local key_to_id: { [string]: number } = {}
    local queue: { { number } } = {}

    local start_set = nfa.epsilon_closure(automaton, { automaton.start })
    local start_key = state_set_key(start_set)

    result.start = next_id
    key_to_id[start_key] = next_id

    result.states[next_id] = {
        id = next_id,
        transitions = {},
        accept = find_accept(automaton, start_set, priorities, conflicts),
    }

    next_id += 1
    table.insert(queue, start_set)

    local queue_index = 1

    while queue_index <= #queue do
        local current_set = queue[queue_index]
        local current_key = state_set_key(current_set)
        local current_id = key_to_id[current_key]
        queue_index += 1

        local active_bytes = collect_active_bytes(automaton, current_set)

        for _, byte in active_bytes do
            local moved = nfa.move(automaton, current_set, byte)

            if #moved == 0 then
                continue
            end

            local target_set = nfa.epsilon_closure(automaton, moved)
            local target_key = state_set_key(target_set)
            local target_id = key_to_id[target_key]

            if not target_id then
                target_id = next_id
                next_id += 1
                key_to_id[target_key] = target_id

                result.states[target_id] = {
                    id = target_id,
                    transitions = {},
                    accept = find_accept(automaton, target_set, priorities, conflicts),
                }

                table.insert(queue, target_set)
            end

            result.states[current_id].transitions[byte] = target_id
        end
    end

    return result, conflicts
end

-- Backwards reachability: remove states that can never reach an accept.
function dfa.prune_dead_states(compiled: DFA)
    local reverse: { [number]: { number } } = {}

    for state_id in compiled.states do
        reverse[state_id] = {}
    end

    for state_id, state in compiled.states do
        for _, target in state.transitions do
            table.insert(reverse[target], state_id)
        end
    end

    local reachable: { [number]: boolean } = {}
    local queue: { number } = {}

    for state_id, state in compiled.states do
        if not state.accept then
            continue
        end

        reachable[state_id] = true
        table.insert(queue, state_id)
    end

    local queue_index = 1

    while queue_index <= #queue do
        local current = queue[queue_index]
        queue_index += 1

        for _, predecessor in reverse[current] do
            if reachable[predecessor] then
                continue
            end

            reachable[predecessor] = true
            table.insert(queue, predecessor)
        end
    end

    reachable[compiled.start] = true

    for state_id in compiled.states do
        if reachable[state_id] then
            continue
        end

        compiled.states[state_id] = nil
    end

    for _, state in compiled.states do
        for byte, target in state.transitions do
            if not compiled.states[target] then
                state.transitions[byte] = nil
            end
        end
    end
end

local function state_signature(state: DFAState): string
    local parts: { string } = {}
    table.insert(parts, `accept={state.accept or "nil"}`)

    local bytes: { number } = {}

    for byte in state.transitions do
        table.insert(bytes, byte)
    end

    table.sort(bytes)

    for _, byte in bytes do
        table.insert(parts, `{byte}->{state.transitions[byte]}`)
    end

    return table.concat(parts, ";")
end

-- Iteratively merges states with identical signatures until stable.
function dfa.deduplicate(compiled: DFA)
    while true do
        local signature_to_ids: { [string]: { number } } = {}

        for state_id, state in compiled.states do
            local signature = state_signature(state)

            if not signature_to_ids[signature] then
                signature_to_ids[signature] = {}
            end

            table.insert(signature_to_ids[signature], state_id)
        end

        local merge_map: { [number]: number } = {}
        local changed = false

        for _, ids in signature_to_ids do
            if #ids <= 1 then
                continue
            end

            table.sort(ids)

            local canonical = ids[1]

            for index = 2, #ids do
                merge_map[ids[index]] = canonical
                changed = true
            end
        end

        if not changed then
            break
        end

        for _, state in compiled.states do
            for byte, target in state.transitions do
                if merge_map[target] then
                    state.transitions[byte] = merge_map[target]
                end
            end
        end

        if merge_map[compiled.start] then
            compiled.start = merge_map[compiled.start]
        end

        for old_id in merge_map do
            compiled.states[old_id] = nil
        end
    end
end

function dfa.from_nfa(automaton: NFA, priorities: { [number]: number }): (DFA, { Conflict })
    local compiled, conflicts = dfa.build(automaton, priorities)

    dfa.prune_dead_states(compiled)
    dfa.deduplicate(compiled)

    return compiled, conflicts
end

return dfa
