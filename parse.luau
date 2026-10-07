-- Git's -z porcelain format separates fields with NUL and records with an
-- empty field. Paths and branch names therefore need no shell or line parsing.
local function parse_porcelain(bytes)
	local entries = {}
	local entry = nil
	local start = 1
	while start <= #bytes do
		local stop = string.find(bytes, "\0", start, true)
		if not stop then
			return nil, "incomplete Git worktree output"
		end
		local field = string.sub(bytes, start, stop - 1)
		start = stop + 1
		if field == "" then
			if entry then
				if not entry.path or not entry.head then
					return nil, "missing worktree path or HEAD"
				end
				table.insert(entries, entry)
				entry = nil
			end
		else
			local key, value = string.match(field, "^([^ ]+) (.*)$")
			if not key then key = field end
			if key == "worktree" then
				if entry then return nil, "missing worktree separator" end
				entry = { path = value }
			elseif not entry then
				return nil, "field before worktree path"
			elseif key == "HEAD" then
				entry.head = value
			elseif key == "branch" then
				entry.branch = value
			elseif key == "detached" then
				entry.detached = true
			elseif key == "bare" then
				entry.bare = true
			elseif key == "locked" then
				entry.locked = value or true
			elseif key == "prunable" then
				entry.prunable = value or true
			end
		end
	end
	if entry then return nil, "unterminated worktree record" end
	return entries
end

return { parse_porcelain = parse_porcelain }
