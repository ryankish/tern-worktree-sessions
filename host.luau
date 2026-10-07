local parse = require("./parse")
local ui = tern.ui

local function alive(pane)
	for _, item in tern.pane.list() do
		if item.pane == pane then return true end
	end
	return false
end

local function within(path, root)
	return path == root or string.sub(path, 1, #root + 1) == root .. "/"
end

local function active_worktree(state)
	local active = nil
	for _, entry in state.entries do
		if within(state.cwd, entry.path) and (not active or #entry.path > #active.path) then
			active = entry
		end
	end
	return active
end

local function project_name(state)
	local first = state.entries[1]
	local path = first and first.path or state.cwd
	return string.match(path, "([^/]+)/?$") or path
end

local function hex(bytes)
	return (string.gsub(bytes, ".", function(byte)
		return string.format("%02x", string.byte(byte))
	end))
end

local function refresh(state, cx)
	state.generation += 1
	local generation = state.generation
	state.loading = true
	state.error = nil
	cx:render()
	local cwd = state.cwd
	tern.process.run({ "git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir" },
		{ timeout_ms = 10000 }, function(common)
			if not alive(cx.pane) or generation ~= state.generation then return end
			if common.status ~= 0 then
				state.error = common.stderr ~= "" and common.stderr or "Not a Git repository"
				state.loading = false
				cx:render()
				return
			end
			state.common_dir = string.gsub(common.stdout, "\n$", "")
			tern.process.run({ "git", "-C", cwd, "worktree", "list", "--porcelain", "-z" },
				{ timeout_ms = 10000 }, function(result)
					if not alive(cx.pane) or generation ~= state.generation then return end
					if result.status ~= 0 then
						state.error = result.stderr ~= "" and result.stderr or "git worktree list failed"
					else
						local entries, err = parse.parse_porcelain(result.stdout)
						state.error = err
						if entries then state.entries = entries end
					end
					state.loading = false
					cx:render()
					cx:save()
				end)
		end)
end

tern.block.define("inventory", {
	init = function(cx, args, saved)
		local state = {
			cwd = (saved and saved.cwd) or args[1] or cx.cwd or "",
			host = (saved and saved.host) or args[2] or "unknown",
			common_dir = saved and saved.common_dir or nil,
			entries = saved and saved.entries or {},
			loading = false,
			error = nil,
			generation = 0,
		}
		if state.cwd ~= "" then refresh(state, cx) end
		return state
	end,
	title = function() return "worktrees" end,
	view = function(state)
		local rows = { ui.text({ ui.span(string.upper(project_name(state)), "strong") }),
			ui.text({ ui.span(state.host, "muted") }), ui.rule("") }
		if state.error then table.insert(rows, ui.text({ ui.span(state.error, "error") })) end
		if state.loading then table.insert(rows, ui.text({ ui.span("Refreshing…", "muted") })) end
		local active = active_worktree(state)
		local items = {}
		for index, entry in state.entries do
			local label = entry.branch and string.gsub(entry.branch, "^refs/heads/", "")
				or (entry.bare and "(bare)" or "(detached " .. string.sub(entry.head, 1, 8) .. ")")
			local value = entry.prunable and "prunable" or (entry.locked and "locked" or nil)
			table.insert(items, ui.node("item", {
				key = tostring(#items + 1),
				label = (entry == active and "● " or "  ") .. label,
				detail = entry.path,
				value = value,
				icon = "branch",
				tone = entry == active and "accent" or (entry.prunable and "warning" or nil),
				disabled = entry.prunable or entry.bare,
				actions = { click = "switch=" .. tostring(index) },
			}))
		end
		table.insert(rows, ui.section("WORKTREES", items))
		table.insert(rows, ui.rule(""))
		table.insert(rows, ui.node("item", {
			key = "refresh", label = "↻ Refresh", icon = "refresh",
			actions = { click = "refresh" },
		}))
		return { main = ui.col(rows), dock = ui.col({ ui.text({ ui.span("Press r to refresh", "muted") }) }) }
	end,
	key = function(state, key, cx)
		if key.name ~= "r" then return false end
		refresh(state, cx)
		return true
	end,
	event = function(state, ev, cx)
		if ev.ev ~= "action" then return end
		if ev.act == "refresh" then
			refresh(state, cx)
		elseif ev.act == "switch" then
			local index = tonumber(ev.value)
			local entry = index and state.entries[index]
			if entry and not entry.prunable and not entry.bare and state.common_dir then
				cx:open("tern-worktree://switch/" .. hex(state.common_dir) .. "/" .. hex(entry.path))
			end
		end
	end,
	save = function(state)
		return { cwd = state.cwd, host = state.host, common_dir = state.common_dir,
			entries = tern.json.array(state.entries) }
	end,
})
