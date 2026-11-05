local parse = require("./parse")
local config = require("./config")
local setup_policy = require("./setup_policy")
local github_pr = require("./github_pr")
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

local function has_setup_hook(entry)
	return not entry.bare and not entry.prunable
		and tern.fs.exists(entry.path .. "/" .. config.setup_hook)
end

local function any_setup_hook(entries)
	for _, entry in entries do
		if has_setup_hook(entry) then return true end
	end
	return false
end

local function remove_candidate(state, index)
	local entry = state.entries[index]
	-- Git lists the main worktree first. Keep it as the stable anchor for -C.
	if not entry or index == 1 or entry.bare or entry.prunable or entry.locked then return nil end
	return entry
end

local function available_anchor(state, excluded)
	for _, entry in state.entries do
		if entry.path ~= excluded and not entry.prunable and tern.fs.exists(entry.path) then
			return entry.path
		end
	end
	return nil
end

local function unavailable_sessions(state)
	local entries = {}
	if not state.ready then return entries end
	for _, path in state.managed_paths or {} do
		local found = nil
		for _, entry in state.entries do
			if entry.path == path then found = entry; break end
		end
		if not found or found.prunable or not tern.fs.exists(path) then
			table.insert(entries, { path = path, entry = found })
		end
	end
	return entries
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
	state.setup_questions = nil
	state.setup_answers = nil
	state.setup_selected = false
	if state.ready then state.error = nil end
	cx:render()
	cx:frame({ { "focus", "main.branch" } })
end

local function finish_created(state, cx)
	local created = state.created
	if not created then return end
	local completed = state.setup_error == nil
	tern.kv.set("setup:" .. hex(state.common_dir) .. ":" .. hex(created.path), {
		choices = created.setup_answers or {}, policy_root = created.source_root or created.repo_root,
		completed = completed,
	})
	state.created = nil
	state.creating = false
	state.mode = "list"
	state.branch = ""
	state.error = nil
	state.setup_error = nil
	state.setup_questions = nil
	state.setup_answers = nil
	state.setup_selected = false
	cx:save()
	refresh(state, cx)
	if created.existing then
		cx:toast(completed and "success" or "info",
			completed and "Worktree setup complete" or "Worktree setup skipped", created.path)
	else
		cx:open("tern-worktree://created/" .. hex(state.common_dir) .. "/" .. hex(created.path))
	end
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
	local hook = (created.source_root or created.repo_root) .. "/" .. config.setup_hook
	if not tern.fs.exists(hook) then
		if created.has_policy then
			setup_failed(state, cx, "Configured setup hook is missing: " .. hook)
		else
			finish_created(state, cx)
		end
		return
	end
	state.creating = true
	state.mode = "setup_running"
	state.setup_error = nil
	state.progress = "Running worktree setup…"
	cx:render()
	local ok, err = pcall(function()
		tern.process.run({ hook, created.repo_root, created.path, created.branch }, {
			cwd = created.path,
			env = {
				WORKTREE_SESSION_REPO_ROOT = created.repo_root,
				WORKTREE_SESSION_PATH = created.path,
				WORKTREE_SESSION_BRANCH = created.branch,
				WORKTREE_SESSION_SETUP_SOURCE = created.source_root or created.repo_root,
				WORKTREE_SESSION_HOST = state.host,
				WORKTREE_SESSION_HOST_KIND = state.host_kind,
				WORKTREE_SESSION_SETUP_CHOICES_JSON = created.has_policy
					and tern.json.encode(created.setup_answers) or "{}",
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
	local source = active_worktree(state)
	if not source or source.prunable or source.bare then
		state.error = "Select an available worktree before creating another"
		cx:render()
		return
	end
	local source_root = source.path
	if not state.setup_selected then
		local policy_path = source_root .. "/" .. config.setup_hook .. ".json"
		if tern.fs.exists(policy_path) then
			local ok, bytes = pcall(tern.fs.read, policy_path, 65536)
			if not ok then state.error = "Cannot read setup policy: " .. tostring(bytes); cx:render(); return end
			local questions, err = setup_policy.parse(bytes)
			if not questions then state.error = err; cx:render(); return end
			if not tern.fs.exists(source_root .. "/" .. config.setup_hook) then
				state.error = "Setup policy exists, but its hook is missing"
				cx:render()
				return
			end
			state.setup_questions = questions
			state.setup_answers = {}
			state.setup_index = 1
			state.has_policy = true
			if #questions > 0 then
				state.mode = "setup_choices"
				state.error = nil
				cx:frame({ { "focus", tern.json.null } })
				cx:render()
				return
			end
		else
			state.setup_questions = nil
			state.setup_answers = {}
			state.has_policy = false
		end
		state.setup_selected = true
	end
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
						state.created = { path = path, branch = branch, repo_root = repo_root,
							source_root = source_root,
							setup_answers = state.setup_answers, has_policy = state.has_policy }
						cx:save()
						run_setup(state, cx)
					end)
				end)
		end)
end

local function begin_existing_setup(state, cx, index)
	if state.creating or state.created or not state.ready then return end
	local entry = state.entries[index]
	if not entry or entry.bare or entry.prunable or not tern.fs.exists(entry.path) then
		state.error = "Choose an available worktree"
		cx:render()
		return
	end
	local hook = entry.path .. "/" .. config.setup_hook
	if not has_setup_hook(entry) then
		state.error = "This worktree has no setup hook: " .. hook
		cx:render()
		return
	end
	local policy_path = hook .. ".json"
	local questions = nil
	if tern.fs.exists(policy_path) then
		local ok, bytes = pcall(tern.fs.read, policy_path, 65536)
		if not ok then state.error = "Cannot read setup policy: " .. tostring(bytes); cx:render(); return end
		local err
		questions, err = setup_policy.parse(bytes)
		if not questions then state.error = err; cx:render(); return end
	end
	local primary = nil
	for _, candidate in state.entries do
		if not candidate.bare and not candidate.prunable then primary = candidate; break end
	end
	if not primary then
		state.error = "Cannot determine an available checkout for setup"
		cx:render()
		return
	end
	local branch = entry.branch and string.gsub(entry.branch, "^refs/heads/", "") or "HEAD"
	state.setup_answers = {}
	state.setup_questions = questions
	state.setup_index = 1
	state.has_policy = questions ~= nil
	state.setup_selected = questions == nil
	state.setup_error = nil
	state.error = nil
	state.created = { path = entry.path, branch = branch, repo_root = primary.path,
		source_root = entry.path, setup_answers = state.setup_answers,
		has_policy = state.has_policy, existing = true, choices_complete = questions == nil }
	if questions then
		state.mode = "setup_choices"
		cx:save()
		cx:render()
	else
		cx:save()
		run_setup(state, cx)
	end
end

local function select_setup_choice(state, cx, index)
	if state.mode ~= "setup_choices" or state.creating then return end
	local question = state.setup_questions and state.setup_questions[state.setup_index]
	local choice = question and question.choices[index]
	if not choice then return end
	state.setup_answers[question.id] = choice.id
	if state.setup_index < #state.setup_questions then
		state.setup_index += 1
		cx:render()
		return
	end
	state.setup_selected = true
	if state.created and state.created.existing then
		state.created.choices_complete = true
		state.mode = "setup_running"
		cx:save()
		run_setup(state, cx)
	else
		state.mode = "new"
		create_worktree(state, cx)
	end
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
					tern.kv.set("setup:" .. hex(state.common_dir) .. ":" .. hex(target.path), nil)
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

local function cleanup_stale_session(state, cx)
	local target = state.stale_target
	if state.creating or not target or not state.common_dir or not state.ready then return end
	local anchor = available_anchor(state, target)
	if not anchor then
		state.error = "No available worktree can anchor this repository; reconnect or restore one first"
		cx:render()
		return
	end
	state.creating = true
	state.progress = "Checking worktrees…"
	cx:render()
	tern.process.run({ "git", "-C", anchor, "worktree", "list", "--porcelain", "-z" },
		{ timeout_ms = 10000 }, function(result)
			if not alive(cx.pane) then return end
			local entries, err = nil, nil
			if result.status == 0 then entries, err = parse.parse_porcelain(result.stdout) end
			state.creating = false
			if not entries then
				state.error = result.status ~= 0 and process_error(result, "Could not check worktrees") or err
				cx:render()
				return
			end
			for _, entry in entries do
				if entry.path == target and not entry.prunable and tern.fs.exists(target) then
					state.error = "Worktree is available again; refresh before cleaning up"
					state.stale_target = nil
					state.mode = "list"
					cx:render()
					return
				end
			end
			tern.kv.set("setup:" .. hex(state.common_dir) .. ":" .. hex(target), nil)
			state.stale_target = nil
			state.mode = "list"
			state.error = nil
			state.cwd = anchor
			cx:save()
			cx:open("tern-worktree://stale-cleanup/" .. hex(state.common_dir) .. "/"
				.. hex(target) .. "/" .. hex(anchor))
		end)
end

refresh = function(state, cx, force_pr)
	state.generation += 1
	local generation = state.generation
	state.loading = true
	state.ready = false
	state.error = nil
	cx:render()
	local cwd = available_anchor(state) or state.cwd
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
							github_pr.attach(state.common_dir, cwd, entries, cx, force_pr)
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
					if state.auto_enter and state.ready and state.mode == "list" then
						state.auto_enter = false
						local entry = active_worktree(state)
						if entry and not entry.bare and not entry.prunable
							and tern.fs.exists(entry.path) then
							cx:open("tern-worktree://switch/" .. hex(state.common_dir) .. "/" .. hex(entry.path))
						end
					end
					cx:save()
				end)
		end)
end

local function refresh_repo(state, cx)
	if state.common_dir then
		cx:open("tern-worktree://refresh-pr/" .. hex(state.common_dir))
	else
		refresh(state, cx, true)
	end
end

local function pr_button(status, busy)
	if busy then return "↑ Pushing", "pushing" end
	local labels = {
		none = "↑ Push + PR", open = "● Open PR", draft = "◐ Draft PR",
		merged = "✓ Merged", closed = "× Closed", checking = "… PR",
		unavailable = "? PR", base = "PRs", detached = "Detached",
	}
	return labels[status.kind] or "? PR", status.kind
end

tern.block.define("inventory", {
	init = function(cx, args, saved)
		local pending = saved and saved.pending or nil
		-- A reopened choice prompt has not run anything yet. Never retry its
		-- partially collected answers as if setup had already begun.
		if pending and pending.existing and not pending.choices_complete then pending = nil end
		local state = {
			cwd = (saved and saved.cwd) or args[1] or cx.cwd or "",
			host = (saved and saved.host) or args[2] or "unknown",
			common_dir = saved and saved.common_dir or nil,
			entries = saved and saved.entries or {},
			loading = false,
			ready = false,
			error = nil,
			generation = 0,
			mode = pending and "setup_failed"
				or ((args[3] == "new" or args[3] == "remove") and args[3]
					or (args[3] == "setup" and "setup_select") or "list"),
			host_kind = (saved and saved.host_kind) or args[4] or "unknown",
			branch = "",
			creating = false,
			progress = nil,
			pending_branch = nil,
			created = pending,
			setup_error = pending and saved.setup_error or nil,
			setup_questions = nil,
			setup_answers = nil,
			setup_index = 1,
			setup_selected = false,
			has_policy = false,
			remove_target = nil,
			stale_target = nil,
			managed_paths = {},
			auto_enter = not saved and args[3] == "discover",
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
		if state.mode == "setup_choices" then
			local question = state.setup_questions[state.setup_index]
			table.insert(rows, ui.text({ ui.span("SETUP CHOICES", "strong") }))
			table.insert(rows, ui.text({ ui.span(state.created and state.created.path or state.branch, "muted") }))
			table.insert(rows, ui.text(question.label))
			if question.description then table.insert(rows, ui.text({ ui.span(question.description, "muted") })) end
			for index, choice in question.choices do
				table.insert(rows, ui.node("item", {
					key = "setup-choice-" .. tostring(index),
					label = tostring(index) .. ". " .. choice.label,
					detail = choice.description,
					value = choice.id == question.default and "default" or nil,
					actions = { click = "setup_choice=" .. tostring(index) },
				}))
			end
			table.insert(rows, ui.node("item", {
				key = "setup-back", label = state.created and "Back to worktrees" or "Back to branch",
				actions = { click = "setup_back" },
			}))
		end
		if state.mode == "setup_select" then
			table.insert(rows, ui.text({ ui.span("RUN SETUP", "strong") }))
			table.insert(rows, ui.text({ ui.span(any_setup_hook(state.entries)
				and "Choose a worktree whose setup hook you want to rerun"
				or "No worktree has a setup hook. Setup is optional; select a worktree below to switch.", "muted") }))
			for index, entry in state.entries do
				if has_setup_hook(entry) then
					table.insert(rows, ui.node("item", {
						key = "setup-" .. tostring(index),
						label = tostring(index) .. ". " .. worktree_label(entry), detail = entry.path,
						actions = { click = "setup_select=" .. tostring(index) },
					}))
				end
			end
		end
		if state.mode == "setup_running" or state.mode == "setup_failed" then
			local created = state.created
			if created then
				table.insert(rows, ui.text({ ui.span(created.existing and "WORKTREE SETUP"
					or "NEW WORKTREE", "strong") }))
				table.insert(rows, ui.text(created.path))
				if state.creating then
					table.insert(rows, ui.text({ ui.span(state.progress or "Running setup…", "muted") }))
				else
					table.insert(rows, ui.el("div", { class = "ws-setup-actions" }, {
						ui.el("button", {
							key = "retry", class = "ws-setup-button primary", text = "Retry setup",
							actions = { click = "retry_setup" },
						}),
						ui.el("button", {
							key = "continue", class = "ws-setup-button secondary",
							text = created.existing and "Dismiss setup failure" or "Open workspace anyway",
							actions = { click = "continue_setup" },
						}),
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
		if state.mode == "stale_confirm" and state.stale_target then
			table.insert(rows, ui.text({ ui.span("CLOSE UNAVAILABLE SESSION?", "strong") }))
			table.insert(rows, ui.text(state.stale_target))
			table.insert(rows, ui.text({ ui.span(
				"This ends its Tern panes and processes. Git files and branches are untouched.", "warning") }))
			if state.creating then
				table.insert(rows, ui.text({ ui.span(state.progress, "muted") }))
			else
				table.insert(rows, ui.el("div", { class = "ws-setup-actions" }, {
					ui.el("button", { key = "close-stale", class = "ws-setup-button primary",
						text = "Close Tern session", actions = { click = "confirm_stale" } }),
					ui.el("button", { key = "cancel-stale", class = "ws-setup-button secondary",
						text = "Cancel", actions = { click = "cancel_stale" } }),
				}))
			end
		end
		local active = active_worktree(state)
		local stale_sessions = unavailable_sessions(state)
		local stale_paths = {}
		for _, stale in stale_sessions do stale_paths[stale.path] = true end
		local items = {}
		for index, entry in state.entries do
			if stale_paths[entry.path] then continue end
			local label = worktree_label(entry)
			local unavailable = entry.prunable or not tern.fs.exists(entry.path)
			local value = unavailable and "unavailable" or (entry.locked and "locked" or nil)
			local status = github_pr.status(state.common_dir, entry)
			local busy = github_pr.busy(state.common_dir, entry)
			local button_text, button_kind = pr_button(status, busy)
			local button_title = status.kind == "base" and
				"Open all pull requests for this repository"
				or (status.kind == "none" and
				"Push this branch, then open GitHub's new pull request page")
				or (status.error or (status.url and "Open pull request on GitHub" or button_text))
			local actionable = not (busy or unavailable or entry.bare
				or status.kind == "detached"
				or status.kind == "checking")
			local pr_control = actionable and ui.el("button", {
				key = "pr", class = "ws-pr-button " .. button_kind,
				text = button_text, aria = status.kind == "base"
					and "Repository pull requests" or "Pull request: " .. button_text,
				title = button_title, actions = { click = "pr_action=" .. tostring(index) },
			}) or ui.el("span", {
				key = "pr", class = "ws-pr-button ws-pr-inert " .. button_kind,
				text = button_text, aria = "Pull request: " .. button_text,
				title = button_title,
			})
			table.insert(items, ui.el("div", { key = "worktree-" .. tostring(index),
				class = "ws-worktree-row" }, {
				ui.node("item", {
					key = "switch", label = (entry == active and "● " or "  ") .. label,
					detail = entry.path, value = value, icon = "branch",
					tone = unavailable and "warning" or (entry == active and "accent" or nil),
					disabled = state.mode == "remove" or state.mode == "remove_confirm"
						or state.mode == "stale_confirm" or state.error ~= nil or unavailable or entry.bare,
					actions = { click = "switch=" .. tostring(index) },
				}),
				pr_control,
			}))
		end
		table.insert(rows, ui.section("WORKTREES", items))
		local stale_items = {}
		for index, stale in stale_sessions do
			local name = stale.entry and worktree_label(stale.entry)
				or (string.match(stale.path, "([^/]+)$") or stale.path)
			table.insert(stale_items, ui.node("item", {
				key = "stale-" .. tostring(index), label = (state.cwd == stale.path and "● " or "  ") .. name,
				detail = stale.path, value = "unavailable", tone = "warning", icon = "branch",
				disabled = state.mode ~= "list" or state.creating,
				actions = { click = "stale_select=" .. tostring(index) },
			}))
		end
		if #stale_items > 0 then
			table.insert(rows, ui.section("UNAVAILABLE SESSIONS", stale_items))
		end
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
			key = "setup", label = "Run Setup", icon = "play",
			disabled = state.mode ~= "list" or state.creating or state.created ~= nil
				or not any_setup_hook(state.entries),
			actions = { click = "setup" },
		}))
		table.insert(rows, ui.node("item", {
			key = "refresh", label = "↻ Refresh", icon = "refresh",
			actions = { click = "refresh_all" },
		}))
		local hint = state.mode == "setup_failed" and "s: retry setup · c: dismiss"
			or (state.mode == "setup_choices" and "1–9: select · Enter: default · Esc: back")
			or (state.mode == "setup_select" and "1–9: select · Esc: cancel")
			or (state.mode == "remove" and "1–9: select · Esc: cancel")
			or (state.mode == "remove_confirm" and "Enter: remove · Esc: cancel")
			or (state.mode == "stale_confirm" and "Enter: close session · Esc: cancel")
			or "n: new · s: setup · d: remove · r: refresh"
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
		if state.mode == "setup_choices" then
			if key.name == "escape" then
				local existing = state.created and state.created.existing
				state.mode = existing and "setup_select" or "new"
				if existing then state.created = nil; cx:save() end
				state.setup_selected = false
				if not existing then cx:frame({ { "focus", "main.branch" } }) end
				return true
			end
			local question = state.setup_questions[state.setup_index]
			if key.name == "enter" then
				for index, choice in question.choices do
					if choice.id == question.default then select_setup_choice(state, cx, index); break end
				end
				return true
			end
			local number = tonumber(key.name)
			if number and number >= 1 and number <= 9 then
				select_setup_choice(state, cx, number)
				return true
			end
		end
		if state.mode == "setup_select" then
			if key.name == "escape" then state.mode = "list"; state.error = nil; return true end
			local number = tonumber(key.name)
			if number and number >= 1 and number <= 9 then
				begin_existing_setup(state, cx, number)
				return true
			end
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
		if state.mode == "stale_confirm" then
			if key.name == "escape" and not state.creating then
				state.mode = "list"; state.stale_target = nil; state.error = nil
				return true
			elseif key.name == "enter" then
				cleanup_stale_session(state, cx)
				return true
			end
		end
		if key.name == "n" and state.mode == "list" then begin_new(state, cx); return true end
		if key.name == "d" and state.mode == "list" and not state.creating and not state.created then
			state.mode = "remove"
			state.remove_target = nil
			state.error = nil
			return true
		end
		if key.name == "s" and state.mode == "list" and not state.creating and not state.created then
			state.mode = "setup_select"
			state.error = nil
			return true
		end
		if key.name ~= "r" then return false end
		refresh_repo(state, cx)
		return true
	end,
	event = function(state, ev, cx)
		if ev.ev == "focus" and ev.id == "main.branch" then
			cx:frame({ { "focus", ev.id } })
			return
		end
		if ev.ev ~= "action" then return end
		if ev.act == "refresh" then
			refresh(state, cx, ev.force_pr)
		elseif ev.act == "discover" then
			if state.mode == "list" and not state.creating and not state.created then
				if type(ev.cwd) == "string" and ev.cwd ~= "" then state.cwd = ev.cwd end
				state.auto_enter = true
				refresh(state, cx)
			end
		elseif ev.act == "managed_paths" then
			if type(ev.value) == "table" then
				state.managed_paths = ev.value
				cx:render()
			end
		elseif ev.act == "refresh_all" then
			refresh_repo(state, cx)
		elseif ev.act == "host_kind" then
			if ev.value == "local" or ev.value == "remote" then
				state.host_kind = ev.value
				cx:save()
			end
		elseif ev.act == "new" then
			if state.mode == "list" and not state.creating then begin_new(state, cx) end
		elseif ev.act == "setup_choice" then
			select_setup_choice(state, cx, tonumber(ev.value))
		elseif ev.act == "setup_back" then
			if state.mode == "setup_choices" then
				local existing = state.created and state.created.existing
				state.mode = existing and "setup_select" or "new"
				if existing then state.created = nil; cx:save() end
				state.setup_selected = false
				if not existing then cx:frame({ { "focus", "main.branch" } }) end
			end
		elseif ev.act == "setup" then
			if state.mode == "list" and not state.creating and not state.created then
				state.mode = "setup_select"
				state.error = nil
				cx:render()
			end
		elseif ev.act == "setup_select" then
			if state.mode == "setup_select" then begin_existing_setup(state, cx, tonumber(ev.value)) end
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
		elseif ev.act == "stale_select" then
			if state.mode == "list" and state.ready and not state.creating then
				local stale = unavailable_sessions(state)[tonumber(ev.value)]
				if stale then
					state.stale_target = stale.path
					state.mode = "stale_confirm"
					state.error = nil
					cx:render()
				end
			end
		elseif ev.act == "confirm_stale" then
			if state.mode == "stale_confirm" then cleanup_stale_session(state, cx) end
		elseif ev.act == "cancel_stale" then
			if state.mode == "stale_confirm" and not state.creating then
				state.mode = "list"
				state.stale_target = nil
				state.error = nil
				cx:render()
			end
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
		elseif ev.act == "pr_action" then
			local index = tonumber(ev.value)
			local entry = index and state.entries[index]
			if entry and state.ready and not state.creating and not entry.bare
				and not entry.prunable and tern.fs.exists(entry.path) and state.common_dir then
				local status = github_pr.status(state.common_dir, entry)
				if status.kind ~= "detached"
					and status.kind ~= "checking" then
					github_pr.activate(state.common_dir, entry, cx)
				end
			end
		end
	end,
	save = function(state)
		return { cwd = state.cwd, host = state.host, host_kind = state.host_kind,
			common_dir = state.common_dir, entries = tern.json.array(state.entries),
			pending = state.created, setup_error = state.setup_error }
	end,
})
