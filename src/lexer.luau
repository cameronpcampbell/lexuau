--!strict

local dfa = require("./regex/dfa")
type DFA = dfa.DFA

local lexer = {}

function lexer.new(
    compiled: DFA,
    skip_id: number?,
    pattern_names: { [number]: string },
    pattern_callbacks: { [number]: (string) -> string? },
    content: string
): () -> (string?, string?)
    local position = 1
    local length = #content

    local states = compiled.states

    return function(): (string?, string?)
        while position <= length do
            local current_state = compiled.start
            local last_accept_id: number? = nil
            local last_accept_pos: number? = nil
            local cursor = position

            local start_accept = states[current_state].accept

            if start_accept then
                last_accept_id = start_accept
                last_accept_pos = cursor
            end

            while cursor <= length do
                local byte = string.byte(content, cursor)
                local next_state = states[current_state].transitions[byte]

                if not next_state then
                    break
                end

                current_state = next_state
                cursor += 1

                local accept = states[current_state].accept

                if not accept then
                    continue
                end

                last_accept_id = accept
                last_accept_pos = cursor
            end

            if not last_accept_id or not last_accept_pos then
                local value = string.sub(content, position, position)
                position += 1
                return value, nil
            end

            -- Cast needed: Luau can't narrow `number?` across `continue` boundaries.
            local accept_pos = last_accept_pos :: number
            local value = string.sub(content, position, accept_pos - 1)
            position = accept_pos

            if last_accept_id == skip_id then
                continue
            end

            local callback = pattern_callbacks[last_accept_id]

            if callback then
                local result = callback(value)

                if result == nil then
                    continue
                end

                value = result
            end

            return value, pattern_names[last_accept_id]
        end

        return nil, nil
    end
end

return lexer
