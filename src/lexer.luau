--!strict

local dfa = require("@self/regex/dfa")
type DFA = dfa.DFA

local lexer = {}

-- Create an iterator that lexes content using the compiled DFA.
-- Returns (value, kind) pairs where kind is nil for unmatched bytes.
function lexer.new(
    compiled: DFA,
    skip_id: number,
    pattern_names: { [number]: string },
    content: string
): () -> (string?, string?)
    local position = 1
    local length = #content

    return function(): (string?, string?)
        while position <= length do
            -- Run DFA from current position, find longest match.
            local current_state = compiled.start
            local last_accept_id: number? = nil
            local last_accept_pos: number? = nil
            local cursor = position

            -- Check if start state itself accepts.
            local start_state = compiled.states[current_state]
            if start_state.accept then
                last_accept_id = start_state.accept
                last_accept_pos = cursor
            end

            while cursor <= length do
                local byte = string.byte(content, cursor)
                local next_state = compiled.states[current_state].transitions[byte]
                if not next_state then
                    break
                end

                current_state = next_state
                cursor += 1

                local accept = compiled.states[current_state].accept
                if not accept then
                    continue
                end
                last_accept_id = accept
                last_accept_pos = cursor
            end

            -- A pattern matched.
            if last_accept_id and last_accept_pos then
                local value = string.sub(content, position, last_accept_pos - 1)
                position = last_accept_pos

                -- Skip pattern produces no token.
                if last_accept_id == skip_id then
                    continue
                end

                return value, pattern_names[last_accept_id]
            end

            -- No pattern matched; emit a single byte with nil kind.
            local value = string.sub(content, position, position)
            position += 1
            return value, nil
        end

        -- End of input.
        return nil, nil
    end
end

return lexer
