--!strict
--!optimize 2

local dfa = require("./regex/dfa")
type DFA = dfa.DFA

local Session = {}
Session.__index = Session

export type Profile<S> = {
	compiled_dfa: DFA,
	skip_id: number?,
	pattern_names: { [number]: string },
	pattern_callbacks: { [number]: (string, S) -> (string?, { _profile: Profile<S> }?) },
	init_state: () -> S,
}

export type Session<S> = setmetatable<{
	position: number,
	length: number,
	content: string,
	states: { [number]: dfa.DFAState },
	start: number,
	skip_id: number?,
	pattern_names: { [number]: string },
	pattern_callbacks: { [number]: (string, S) -> (string?, { _profile: Profile<S> }?) },
	state: S,
}, typeof(Session)>

function Session.new<S>(profile: Profile<S>, content: string, state: S, position: number?): Session<S>
	return setmetatable({
		position = position or 1,
		length = #content,
		content = content,
		states = profile.compiled_dfa.states,
		start = profile.compiled_dfa.start,
		skip_id = profile.skip_id,
		pattern_names = profile.pattern_names,
		pattern_callbacks = profile.pattern_callbacks,
		state = state,
	}, Session)
end

function Session.__iter<S>(self: Session<S>)
	return function(): (string?, string?)
		while self.position <= self.length do
			local states = self.states
			local current_state = self.start
			local last_accept_id: number? = nil
			local last_accept_pos: number? = nil
			local cursor = self.position
			local content = self.content

			local start_accept = states[current_state].accept

			if start_accept then
				last_accept_id = start_accept
				last_accept_pos = cursor
			end

			while cursor <= self.length do
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
				local value = string.sub(content, self.position, self.position)
				self.position += 1
				return value, nil
			end

			-- Cast needed: Luau can't narrow `number?` across `continue` boundaries.
			local accept_pos = last_accept_pos :: number
			local value = string.sub(content, self.position, accept_pos - 1)
			self.position = accept_pos

			if last_accept_id == self.skip_id then
				continue
			end

			local kind = self.pattern_names[last_accept_id]
			local callback = self.pattern_callbacks[last_accept_id]

			if callback then
				local result, morph_target = callback(value, self.state)

				if morph_target then
					self = Session.new(morph_target._profile, self.content, self.state, self.position)
				end

				if result == nil then
					continue
				end

				value = result
			end

			return value, kind
		end

		return nil, nil
	end
end

return Session
