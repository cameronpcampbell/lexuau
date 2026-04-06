--!strict
--!optimize 2

local dfa = require("./regex/dfa")
type DFA = dfa.DFA

local Session = {}
Session.__index = Session

export type Profile = {
	compiled_dfa: DFA,
	skip_id: number?,
	pattern_names: { [number]: string },
	pattern_callbacks: { [number]: (string, Session) -> (string?, Session?) },
}

export type Session = setmetatable<{
	position: number,
	length: number,
	content: string,
	states: { [number]: dfa.DFAState },
	start: number,
	skip_id: number?,
	pattern_names: { [number]: string },
	pattern_callbacks: { [number]: (string, Session) -> (string?, Session?) },
	morphed: boolean,
	successor: Session?,
}, typeof(Session)>

function Session.new(profile: Profile, content: string, position: number?): Session
	return setmetatable({
		position = position or 1,
		length = #content,
		content = content,
		states = profile.compiled_dfa.states,
		start = profile.compiled_dfa.start,
		skip_id = profile.skip_id,
		pattern_names = profile.pattern_names,
		pattern_callbacks = profile.pattern_callbacks,
		morphed = false,
		successor = nil :: Session?,
	}, Session)
end

function Session.morph(self: Session, target: { _profile: Profile }): Session
	if self.morphed then
		error("Cannot morph an already morphed session.")
	end

	self.morphed = true
	local new_session = Session.new(target._profile, self.content, self.position)
	self.successor = new_session
	return new_session
end

function Session.iter(self: Session): () -> (string?, string?)
	return function(): (string?, string?)
		while self.position <= self.length do
			if self.morphed then
				return nil, nil
			end

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
				local result, morph_session = callback(value, self)

				-- If the callback morphed, follow the successor.
				if morph_session then
					self = morph_session
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

function Session.__iter(self: Session)
	return self:iter()
end

return Session
