--!strict

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

-- Convert a sorted list of NFA state IDs into a string key for deduplication.
local function state_set_key(ids: { number }): string
    return table.concat(ids, ",")
end

-- Determine the accepting pattern for a DFA state.
-- Highest priority wins. Lowest pattern index breaks ties.
local function find_accept(automaton: NFA, nfa_ids: { number }, priorities: { [number]: number }): number?
    local best: number? = nil
    local best_priority = -math.huge
    for _, state_id in nfa_ids do
        local accept = automaton.states[state_id].accept
        if not accept then
            continue
        end
        local priority = priorities[accept] or 0
        if not best or priority > best_priority or (priority == best_priority and accept < best) then
            best = accept
            best_priority = priority
        end
    end
    return best
end

-- Collect all distinct byte values that cause transitions from a set of NFA states.
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

-- Build a DFA from an NFA using subset (powerset) construction.
-- Priorities maps pattern index to its priority value.
function dfa.build(automaton: NFA, priorities: { [number]: number }): DFA
    local result: DFA = {
        states = {},
        start = 0,
    }

    local next_id = 0
    local key_to_id: { [string]: number } = {}
    local queue: { { number } } = {}

    -- Create the start state from epsilon closure of NFA start.
    local start_set = nfa.epsilon_closure(automaton, { automaton.start })
    local start_key = state_set_key(start_set)

    result.start = next_id
    key_to_id[start_key] = next_id
    result.states[next_id] = {
        id = next_id,
        transitions = {},
        accept = find_accept(automaton, start_set, priorities),
    }
    next_id += 1
    table.insert(queue, start_set)

    -- BFS over DFA states.
    local queue_index = 1
    while queue_index <= #queue do
        local current_set = queue[queue_index]
        local current_key = state_set_key(current_set)
        local current_id = key_to_id[current_key]
        queue_index += 1

        -- Only iterate over bytes that actually produce transitions.
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
                    accept = find_accept(automaton, target_set, priorities),
                }
                table.insert(queue, target_set)
            end

            result.states[current_id].transitions[byte] = target_id
        end
    end

    return result
end

-- Remove states that can never reach an accepting state.
function dfa.prune_dead_states(compiled: DFA)
    -- Find all states that can reach an accept state (backwards reachability).
    local reachable: { [number]: boolean } = {}

    -- Build reverse adjacency list.
    local reverse: { [number]: { number } } = {}
    for state_id in compiled.states do
        reverse[state_id] = {}
    end
    for state_id, state in compiled.states do
        for _, target in state.transitions do
            table.insert(reverse[target], state_id)
        end
    end

    -- BFS backwards from accepting states.
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

    -- Always keep the start state.
    reachable[compiled.start] = true

    -- Remove unreachable states and their transitions.
    for state_id in compiled.states do
        if reachable[state_id] then
            continue
        end
        compiled.states[state_id] = nil
    end

    -- Clean transitions pointing to removed states.
    for _, state in compiled.states do
        for byte, target in state.transitions do
            if not compiled.states[target] then
                state.transitions[byte] = nil
            end
        end
    end
end

-- Build a signature string for a DFA state (for deduplication).
local function state_signature(state: DFAState): string
    local parts: { string } = {}
    table.insert(parts, `accept={state.accept or "nil"}`)

    -- Collect transitions sorted by byte.
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

-- Merge states with identical transitions and accept values.
function dfa.deduplicate(compiled: DFA)
    while true do
        -- Group states by signature.
        local signature_to_ids: { [string]: { number } } = {}
        for state_id, state in compiled.states do
            local signature = state_signature(state)
            if not signature_to_ids[signature] then
                signature_to_ids[signature] = {}
            end
            table.insert(signature_to_ids[signature], state_id)
        end

        -- Build merge map: higher IDs map to the lowest ID in their group.
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

        -- Apply merge map to all transitions.
        for _, state in compiled.states do
            for byte, target in state.transitions do
                if merge_map[target] then
                    state.transitions[byte] = merge_map[target]
                end
            end
        end

        -- Update start state if needed.
        if merge_map[compiled.start] then
            compiled.start = merge_map[compiled.start]
        end

        -- Remove merged states.
        for old_id in merge_map do
            compiled.states[old_id] = nil
        end
    end
end

-- Full build pipeline: NFA -> DFA -> optimized DFA.
-- Priorities maps pattern index to its priority value.
function dfa.from_nfa(automaton: NFA, priorities: { [number]: number }): DFA
    local compiled = dfa.build(automaton, priorities)
    dfa.prune_dead_states(compiled)
    dfa.deduplicate(compiled)
    return compiled
end

return dfa
