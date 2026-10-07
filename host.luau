local parse = require("./parse")
local ui = tern.ui

local function alive(pane)
	for _, item in tern.pane.list() do
		if item.pane == pane then return true end
	end
	return false
end

local function within(path, root)
	return path == root or root == "/" or string.sub(path, 1, #root + 1) == root .. "/"
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

local function worktree_label(entry)
	return entry.branch and string.gsub(entry.branch, "^refs/heads/", "")
		or (entry.bare and "(bare)" or "(detached " .. string.sub(entry.head, 1, 8) .. ")")
end

local function remove_candidate(state, index)
	local entry = state.entries[index]
	-- Git lists the main worktree first. Keep it as the stable anchor for -C.
	if not entry or index == 1 or entry.bare or entry.prunable or entry.locked then return nil end
	return entry
end

local refresh

local function process_error(result, fallback)
	local detail = result.stderr ~= "" and result.stderr or result.stdout
	if detail == "" then return fallback end
	return string.sub(detail, 1, 2000)
end

local function new_path(state, branch)
	local main = nil
	for _, entry in state.entries do
		if not entry.bare and not entry.prunable then main = entry.path; break end
	end
	if not main then
		for _, entry in state.entries do
			if not entry.prunable then main = entry.path; break end
		end
	end
	if not main then return nil, "No available Git directory can anchor the new path" end
	local parent, name = string.match(main, "^(.*)/([^/]+)$")
	if not parent or not name then return nil, "Cannot determine the repository parent directory" end
	name = string.gsub(name, "%.git$", "")
	local slug = string.gsub(branch, "[^%w._-]", "-")
	slug = string.gsub(slug, "%-+", "-")
	if slug == "" then return nil, "Branch name has no usable path characters" end
	local base = parent .. "/" .. name .. "-worktrees/" .. slug
	local path = base
	local suffix = 2
	while tern.fs.exists(path) do
		path = base .. "-" .. tostring(suffix)
		suffix += 1
		if suffix > 1000 then return nil, "Could not choose an unused worktree path" end
	end
	return path, nil, main
end

local function begin_new(state, cx)
	if state.created or state.creating then return end
	state.mode = "new"
	state.branch = ""
	if state.ready then state.error = nil end
	cx:render()
	cx:frame({ { "focus", "main.branch" } })
end

local function finish_created(state, cx)
	local created = state.created
	if not created then return end
	state.created = nil
	state.creating = false
	state.mode = "list"
	state.branch = ""
	state.error = nil
	state.setup_error = nil
	cx:save()
	refresh(state, cx)
	cx:open("tern-worktree://created/" .. hex(state.common_dir) .. "/" .. hex(created.path))
end

local function setup_failed(state, cx, message)
	state.creating = false
	state.mode = "setup_failed"
	state.setup_error = message
	cx:render()
	cx:save()
	cx:toast("error", "Worktree setup failed", message)
end

local function run_setup(state, cx)
	local created = state.created
	if not created or state.creating then return end
	local hook = created.repo_root .. "/.tern/worktree-setup"
	if not tern.fs.exists(hook) then finish_created(state, cx); return end
	state.creating = true
	state.mode = "setup_running"
	state.setup_error = nil
	state.progress = "Running worktree setup…"
	cx:render()
	local ok, err = pcall(function()
		tern.process.run({ hook, created.repo_root, created.path, created.branch }, {
			cwd = created.path,
			env = {
				TERN_WORKTREE_REPO_ROOT = created.repo_root,
				TERN_WORKTREE_PATH = created.path,
				TERN_WORKTREE_BRANCH = created.branch,
				TERN_WORKTREE_HOST = state.host,
				TERN_WORKTREE_HOST_KIND = state.host_kind,
			},
			timeout_ms = 900000,
		}, function(result)
			if not alive(cx.pane) then return end
			if result.status == 0 then
				finish_created(state, cx)
			else
				setup_failed(state, cx, process_error(result, result.timed_out and "Setup timed out"
					or "Setup exited with status " .. tostring(result.status)))
			end
		end)
	end)
	if not ok then setup_failed(state, cx, tostring(err)) end
end

local function create_worktree(state, cx)
	if state.creating or state.created then return end
	local branch = string.match(state.branch or "", "^%s*(.-)%s*$")
	if branch == "" then state.error = "Enter a branch name"; cx:render(); return end
	if state.loading and not state.ready then
		state.pending_branch = branch
		state.creating = true
		state.progress = "Waiting for Git discovery…"
		cx:render()
		return
	end
	if not state.ready or not state.common_dir or #state.entries == 0 then
		state.error = "Refresh the repository before creating a worktree"
		cx:render()
		return
	end
	local path, path_error, repo_root = new_path(state, branch)
	if not path then state.error = path_error; cx:render(); return end
	state.creating = true
	state.error = nil
	state.progress = "Checking branch…"
	cx:render()
	tern.process.run({ "git", "check-ref-format", "--branch", branch },
		{ timeout_ms = 10000 }, function(valid)
			if not alive(cx.pane) then return end
			if valid.status ~= 0 then
				state.error = valid.stderr ~= "" and valid.stderr or "Invalid branch name"
				state.creating = false
				cx:render()
				return
			end
			tern.process.run({ "git", "-C", state.cwd, "show-ref", "--verify", "--quiet",
				"refs/heads/" .. branch }, { timeout_ms = 10000 }, function(ref)
					if not alive(cx.pane) then return end
					if ref.status ~= 0 and ref.status ~= 1 then
						state.error = ref.stderr ~= "" and ref.stderr or "Could not check the branch"
						state.creating = false
						cx:render()
						return
					end
					local argv = { "git", "-C", state.cwd, "worktree", "add" }
					if ref.status == 1 then table.insert(argv, "-b"); table.insert(argv, branch) end
					table.insert(argv, path)
					table.insert(argv, ref.status == 0 and branch or "HEAD")
					state.progress = "Creating worktree…"
					cx:render()
					tern.process.run(argv, { timeout_ms = 600000 }, function(result)
						if not alive(cx.pane) then return end
						state.creating = false
						if result.status ~= 0 then
							state.error = result.stderr ~= "" and result.stderr or "git worktree add failed"
							cx:render()
							return
						end
						state.created = { path = path, branch = branch, repo_root = repo_root }
						cx:save()
						run_setup(state, cx)
					end)
				end)
		end)
end

local function select_removal(state, cx, index)
	if state.creating or state.created then return end
	local entry = remove_candidate(state, index)
	if not entry then
		state.error = "Choose an available secondary worktree"
	else
		state.remove_target = { path = entry.path, head = entry.head, branch = entry.branch }
		state.mode = "remove_confirm"
		state.error = nil
	end
	cx:render()
end

local function remove_worktree(state, cx)
	local target = state.remove_target
	local anchor = state.entries[1]
	if state.creating or not target or not anchor or not state.common_dir then return end
	state.creating = true
	state.progress = "Checking worktree…"
	cx:render()
	tern.process.run({ "git", "-C", anchor.path, "worktree", "list", "--porcelain", "-z" },
		{ timeout_ms = 10000 }, function(listed)
			if not alive(cx.pane) then return end
			local entries, err = nil, nil
			if listed.status == 0 then entries, err = parse.parse_porcelain(listed.stdout) end
			if not entries then
				state.error = listed.status ~= 0 and process_error(listed, "Could not check worktrees") or err
				state.creating = false
				cx:render()
				return
			end
			local current = nil
			for index, entry in entries do
				if index > 1 and entry.path == target.path and not entry.bare
					and not entry.locked and not entry.prunable then current = entry; break end
			end
			if not current or current.head ~= target.head or current.branch ~= target.branch then
				state.error = "Worktree changed since selection; refresh and choose it again"
				state.creating = false
				state.remove_target = nil
				state.mode = "remove"
				cx:render()
				return
			end
			state.progress = "Removing worktree…"
			cx:render()
			tern.process.run({ "git", "-C", anchor.path, "worktree", "remove", "--", target.path },
				{ timeout_ms = 600000 }, function(result)
					if not alive(cx.pane) then return end
					state.creating = false
					if result.status ~= 0 then
						state.error = process_error(result, "git worktree remove failed")
						cx:render()
						return
					end
					state.remove_target = nil
					state.mode = "list"
					state.error = nil
					state.cwd = anchor.path
					cx:save()
					cx:open("tern-worktree://removed/" .. hex(state.common_dir) .. "/"
						.. hex(target.path) .. "/" .. hex(anchor.path))
					refresh(state, cx)
				end)
		end)
end

refresh = function(state, cx)
	state.generation += 1
	local generation = state.generation
	state.loading = true
	state.ready = false
	state.error = nil
	cx:render()
	local cwd = state.cwd
	tern.process.run({ "git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir" },
		{ timeout_ms = 10000 }, function(common)
			if not alive(cx.pane) or generation ~= state.generation then return end
			if common.status ~= 0 then
				state.error = common.stderr ~= "" and common.stderr or "Not a Git repository"
				state.loading = false
				if state.pending_branch then
					state.pending_branch = nil
					state.creating = false
				end
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
						if entries then
							state.entries = entries
							state.ready = true
						end
					end
					state.loading = false
					if state.pending_branch and state.ready then
						state.branch = state.pending_branch
						state.pending_branch = nil
						state.creating = false
						create_worktree(state, cx)
					else
						local waiting = state.pending_branch ~= nil
						state.pending_branch = nil
						if waiting then state.creating = false end
						cx:render()
					end
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
			ready = false,
			error = nil,
			generation = 0,
			mode = saved and saved.pending and "setup_failed"
				or ((args[3] == "new" or args[3] == "remove") and args[3] or "list"),
			host_kind = (saved and saved.host_kind) or args[4] or "unknown",
			branch = "",
			creating = false,
			progress = nil,
			pending_branch = nil,
			created = saved and saved.pending or nil,
			setup_error = saved and saved.setup_error or nil,
			remove_target = nil,
		}
		if state.created and not state.setup_error then
			state.setup_error = "Setup status is unknown after restart; retry or open anyway"
		end
		if state.cwd ~= "" then refresh(state, cx) end
		if state.mode == "new" then
			tern.timer(50, function()
				if alive(cx.pane) then cx:frame({ { "focus", "main.branch" } }) end
			end)
		end
		return state
	end,
	title = function() return "worktrees" end,
	view = function(state)
		local rows = { ui.text({ ui.span(string.upper(project_name(state)), "strong") }),
			ui.text({ ui.span(state.host, "muted") }), ui.rule("") }
		if state.error then table.insert(rows, ui.text({ ui.span(state.error, "error") })) end
		if state.setup_error then table.insert(rows, ui.text({ ui.span(state.setup_error, "error") })) end
		if state.loading then table.insert(rows, ui.text({ ui.span("Refreshing…", "muted") })) end
		if state.mode == "new" then
			table.insert(rows, ui.text({ ui.span("NEW WORKTREE", "strong") }))
			table.insert(rows, ui.node("input", {
				key = "branch", text = state.branch, cursor = #state.branch,
				placeholder = "Branch name", aria = "New worktree branch",
			}))
			if state.creating then
				table.insert(rows, ui.text({ ui.span(state.progress or "Working…", "muted") }))
			else
				table.insert(rows, ui.node("item", {
					key = "create", label = "Create worktree", icon = "plus",
					actions = { click = "create" },
				}))
			end
			table.insert(rows, ui.node("item", {
				key = "cancel", label = "Cancel", actions = { click = "cancel" },
			}))
		end
		if state.mode == "setup_running" or state.mode == "setup_failed" then
			local created = state.created
			if created then
				table.insert(rows, ui.text({ ui.span("NEW WORKTREE", "strong") }))
				table.insert(rows, ui.text(created.path))
				if state.creating then
					table.insert(rows, ui.text({ ui.span(state.progress or "Running setup…", "muted") }))
				else
					table.insert(rows, ui.node("item", {
						key = "retry", label = "Retry setup", actions = { click = "retry_setup" },
					}))
					table.insert(rows, ui.node("item", {
						key = "continue", label = "Open workspace anyway",
						actions = { click = "continue_setup" },
					}))
				end
			end
		end
		if state.mode == "remove" then
			table.insert(rows, ui.text({ ui.span("REMOVE WORKTREE", "strong") }))
			table.insert(rows, ui.text({ ui.span("Select a secondary worktree", "muted") }))
			for index, entry in state.entries do
				if remove_candidate(state, index) then
					table.insert(rows, ui.node("item", {
						key = "remove-" .. tostring(index),
						label = tostring(index - 1) .. ". " .. worktree_label(entry),
						detail = entry.path, actions = { click = "remove_select=" .. tostring(index) },
					}))
				end
			end
			table.insert(rows, ui.node("item", {
				key = "cancel-remove", label = "Cancel", actions = { click = "cancel_remove" },
			}))
		elseif state.mode == "remove_confirm" and state.remove_target then
			table.insert(rows, ui.text({ ui.span("REMOVE WORKTREE?", "strong") }))
			table.insert(rows, ui.text(state.remove_target.path))
			table.insert(rows, ui.text({ ui.span("Its Tern session and running processes will close after Git removes it.", "warning") }))
			if state.creating then
				table.insert(rows, ui.text({ ui.span(state.progress, "muted") }))
			else
				table.insert(rows, ui.node("item", {
					key = "confirm-remove", label = "Remove worktree", icon = "trash",
					actions = { click = "confirm_remove" },
				}))
				table.insert(rows, ui.node("item", {
					key = "cancel-remove", label = "Cancel", actions = { click = "cancel_remove" },
				}))
			end
		end
		local active = active_worktree(state)
		local items = {}
		for index, entry in state.entries do
			local label = worktree_label(entry)
			local value = entry.prunable and "prunable" or (entry.locked and "locked" or nil)
			table.insert(items, ui.node("item", {
				key = tostring(#items + 1),
				label = (entry == active and "● " or "  ") .. label,
				detail = entry.path,
				value = value,
				icon = "branch",
				tone = entry == active and "accent" or (entry.prunable and "warning" or nil),
				disabled = state.mode == "remove" or state.mode == "remove_confirm"
					or state.error ~= nil or entry.prunable or entry.bare,
				actions = { click = "switch=" .. tostring(index) },
			}))
		end
		table.insert(rows, ui.section("WORKTREES", items))
		table.insert(rows, ui.rule(""))
		table.insert(rows, ui.node("item", {
			key = "new", label = "+ New Worktree", icon = "plus",
			disabled = state.mode ~= "list" or state.creating or state.created ~= nil,
			actions = { click = "new" },
		}))
		table.insert(rows, ui.node("item", {
			key = "remove", label = "− Remove Worktree", icon = "trash",
			disabled = state.mode ~= "list" or state.creating or state.created ~= nil,
			actions = { click = "remove" },
		}))
		table.insert(rows, ui.node("item", {
			key = "refresh", label = "↻ Refresh", icon = "refresh",
			actions = { click = "refresh" },
		}))
		local hint = state.mode == "setup_failed" and "s: retry setup · c: open anyway"
			or (state.mode == "remove" and "1–9: select · Esc: cancel")
			or (state.mode == "remove_confirm" and "Enter: remove · Esc: cancel")
			or "n: new · d: remove · r: refresh"
		return { main = ui.col(rows), dock = ui.col({ ui.text({ ui.span(hint, "muted") }) }) }
	end,
	key = function(state, key, cx)
		if state.mode == "setup_failed" then
			if key.name == "s" then run_setup(state, cx); return true end
			if key.name == "c" then finish_created(state, cx); return true end
		end
		if state.mode == "new" then
			if key.name == "escape" then
				if state.creating then return false end
				state.mode = "list"
				state.error = nil
				cx:frame({ { "focus", tern.json.null } })
			elseif key.name == "enter" then
				create_worktree(state, cx)
			elseif state.creating then
				return false
			elseif key.name == "backspace" then
				local n = #state.branch
				while n > 1 and string.byte(state.branch, n) >= 128
					and string.byte(state.branch, n) <= 191 do n -= 1 end
				state.branch = string.sub(state.branch, 1, n - 1)
			elseif key.text and not (key.ctrl or key.meta) then
				state.branch ..= key.text
			else
				return false
			end
			return true
		end
		if key.name == "escape" and (state.mode == "remove" or state.mode == "remove_confirm") then
			if state.creating then return false end
			state.mode = "list"
			state.remove_target = nil
			state.error = nil
			return true
		end
		if state.mode == "remove" then
			local number = tonumber(key.name)
			if number and number >= 1 and number <= 9 then
				select_removal(state, cx, number + 1)
				return true
			end
		end
		if state.mode == "remove_confirm" and key.name == "enter" then
			remove_worktree(state, cx)
			return true
		end
		if key.name == "n" and state.mode == "list" then begin_new(state, cx); return true end
		if key.name == "d" and state.mode == "list" and not state.creating and not state.created then
			state.mode = "remove"
			state.remove_target = nil
			state.error = nil
			return true
		end
		if key.name ~= "r" then return false end
		refresh(state, cx)
		return true
	end,
	event = function(state, ev, cx)
		if ev.ev == "focus" and ev.id == "main.branch" then
			cx:frame({ { "focus", ev.id } })
			return
		end
		if ev.ev ~= "action" then return end
		if ev.act == "refresh" then
			refresh(state, cx)
		elseif ev.act == "host_kind" then
			if ev.value == "local" or ev.value == "remote" then
				state.host_kind = ev.value
				cx:save()
			end
		elseif ev.act == "new" then
			if state.mode == "list" and not state.creating then begin_new(state, cx) end
		elseif ev.act == "remove" then
			if state.mode == "list" and not state.creating and not state.created then
				state.mode = "remove"
				state.remove_target = nil
				state.error = nil
				cx:render()
			end
		elseif ev.act == "remove_select" then
			if state.mode == "remove" then select_removal(state, cx, tonumber(ev.value)) end
		elseif ev.act == "confirm_remove" then
			if state.mode == "remove_confirm" then remove_worktree(state, cx) end
		elseif ev.act == "cancel_remove" then
			if not state.creating then
				state.mode = "list"
				state.remove_target = nil
				state.error = nil
				cx:render()
			end
		elseif ev.act == "cancel" then
			if not state.creating then
				state.mode = "list"
				state.error = nil
				cx:frame({ { "focus", tern.json.null } })
			end
		elseif ev.act == "create" then
			create_worktree(state, cx)
		elseif ev.act == "retry_setup" then
			run_setup(state, cx)
		elseif ev.act == "continue_setup" then
			if not state.creating then finish_created(state, cx) end
		elseif ev.act == "switch" then
			local index = tonumber(ev.value)
			local entry = index and state.entries[index]
			if entry and state.mode ~= "remove" and state.mode ~= "remove_confirm"
				and not state.error and not entry.prunable and not entry.bare and state.common_dir then
				cx:open("tern-worktree://switch/" .. hex(state.common_dir) .. "/" .. hex(entry.path))
			end
		end
	end,
	save = function(state)
		return { cwd = state.cwd, host = state.host, host_kind = state.host_kind,
			common_dir = state.common_dir, entries = tern.json.array(state.entries),
			pending = state.created, setup_error = state.setup_error }
	end,
})
