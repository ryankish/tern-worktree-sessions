local parse = require("./parse")
local ui = tern.ui

local function alive(pane)
	for _, item in tern.pane.list() do
		if item.pane == pane then return true end
	end
	return false
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
		local rows = {
			ui.text({ ui.span("Repository worktrees", "strong") }),
			ui.text({ ui.span("Host: " .. state.host, "muted") }),
		}
		if state.common_dir then
			table.insert(rows, ui.text({ ui.span("Git common dir: " .. state.common_dir, "muted") }))
		end
		if state.error then table.insert(rows, ui.text({ ui.span(state.error, "error") })) end
		if state.loading then table.insert(rows, ui.text({ ui.span("Refreshing…", "muted") })) end
		for _, entry in state.entries do
			local label = entry.branch and string.gsub(entry.branch, "^refs/heads/", "")
				or (entry.bare and "(bare)" or "(detached " .. string.sub(entry.head, 1, 8) .. ")")
			local flags = entry.prunable and " [prunable]" or (entry.locked and " [locked]" or "")
			table.insert(rows, ui.text({ ui.span(label .. flags, "strong") }))
			table.insert(rows, ui.text({ ui.span("  " .. entry.path, "muted") }))
		end
		return { main = ui.col(rows), dock = ui.col({ ui.text({ ui.span("Press r to refresh", "muted") }) }) }
	end,
	key = function(state, key, cx)
		if key.name ~= "r" then return false end
		refresh(state, cx)
		return true
	end,
	save = function(state)
		return { cwd = state.cwd, host = state.host, common_dir = state.common_dir,
			entries = tern.json.array(state.entries) }
	end,
})
