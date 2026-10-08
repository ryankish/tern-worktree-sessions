local PREFIX = "tern-wt:"
local config = require("./config")
local current_repo = nil
local window_common_dir = nil
local host_kind_sent = {}
local initialized_shells = {}
local initialized_sessions = {}
local AUTO_REFRESH_MS = 30000
local AUTO_POLL_MS = 5000
local last_refresh_at = -AUTO_REFRESH_MS
local last_visible_session = nil
local last_host_id = nil
local last_host_state = nil

local function hex(bytes)
	return (string.gsub(bytes, ".", function(byte)
		return string.format("%02x", string.byte(byte))
	end))
end

local function unhex(value)
	if #value == 0 or #value % 2 ~= 0 or not string.match(value, "^[0-9a-f]+$") then
		return nil
	end
	return (string.gsub(value, "..", function(byte)
		return string.char(tonumber(byte, 16))
	end))
end

local function session_name(common_dir, path)
	-- Exact paths keep identity independent of the branch and avoid hash collisions.
	return PREFIX .. hex(common_dir) .. ":" .. hex(path)
end

local function session_identity(name)
	local encoded_common, encoded_path = string.match(name,
		"^tern%-wt:([0-9a-f]+):([0-9a-f]+)$")
	if not encoded_common then return nil end
	local common_dir, path = unhex(encoded_common), unhex(encoded_path)
	if not common_dir or not path then return nil end
	return { common_dir = common_dir, path = path }
end

local function repo_from_session(name)
	local identity = session_identity(name)
	if not identity then return nil end
	local common_dir = identity.common_dir
	local root = string.gsub(common_dir, "/%.git$", "")
	return string.match(root, "([^/]+)$") or root
end

local function inventory_launch(path, host_name, host_kind)
	return { cwd = path, block = "worktree.inventory", args = { path, host_name, "", host_kind } }
end

local function shell_quote(value)
	return "'" .. string.gsub(value, "'", "'\"'\"'") .. "'"
end

local function within(path, root)
	return path == root or root == "/" or string.sub(path, 1, #root + 1) == root .. "/"
end

local function shell_startup(path, command)
	local root = shell_quote(path)
	local hook = shell_quote(path .. "/" .. config.shell_hook)
	local init = "export TERN_WORKTREE_PATH=" .. root
		.. "; if [ -f " .. hook .. " ]; then . " .. hook .. "; fi"
	return init .. (command and " && " .. command or "") .. "\r"
end

local function start_shell(cx, pane, path, command)
	initialized_shells[pane] = true
	local info = cx.session:pane(pane)
	local program = info and string.match(info.program or "", "([^/]+)$") or nil
	if program == "fish" or program == "nu" or program == "pwsh" then
		cx:toast("error", "Worktree shell hook needs a POSIX-compatible shell", program)
		if command then cx:run(pane, command .. "\r") end
		return
	end
	cx:run(pane, shell_startup(path, command))
end

local function leaves(tree, into)
	if tree.pane then
		table.insert(into, tree.pane)
		return
	end
	if tree[1] then leaves(tree[1], into) end
	if tree[2] then leaves(tree[2], into) end
end

local function set_share(cx, pane, direction, wanted, read_share)
	local before = read_share()
	if not before then return false end
	if math.abs(before - wanted) < 0.005 then return true end
	if not cx.layout:resize(pane, direction, 1) then return false end
	local after = read_share()
	cx.layout:resize(pane, direction, -1)
	local restored = read_share()
	if not after or not restored or after == before then return false end
	local cells = math.floor((wanted - restored) / (after - before) + 0.5)
	if cells ~= 0 and not cx.layout:resize(pane, direction, cells) then return false end
	return true
end

local function normalize_ratios(cx, tab, nav)
	local key = "layout-v2:" .. tostring(tab.id)
	if tern.kv.get(key) then return end
	local function root_share()
		local layout = cx.session:layout(tab.id)
		local root = layout and layout.root
		if root and root.split == "right" and root[1] and root[1].pane == nav then
			return root.ratio or 0.5
		end
		return nil
	end
	if not set_share(cx, nav, "right", 0.22, root_share) then return end
	if tab.name == "editor" then
		local layout = cx.session:layout(tab.id)
		local content = layout and layout.root[2]
		if content and content.split == "down" and content[1] and content[1].pane then
			local function editor_share()
				local current = cx.session:layout(tab.id)
				local right = current and current.root[2]
				return right and right.ratio or nil
			end
		if not set_share(cx, content[1].pane, "down", config.editor_split_ratio, editor_share) then return end
		end
	end
	tern.kv.set(key, true)
end

local function ensure_inventories(cx, session_id, path)
	local host = cx.hosts:current()
	if host.state ~= "connected" then return end
	local host_name = host.name
	for _, tab in cx.session:tabs() do
		if tab.session == session_id then
			local layout = cx.session:layout(tab.id)
			if not layout then continue end
			local ordered = {}
			leaves(layout.root, ordered)
			local nav, content = nil, {}
			local pane_info = {}
			for _, pane in cx.session:panes() do
				if pane.tab == tab.id then pane_info[pane.pane] = pane end
			end
			for _, pane in ordered do
				local info = pane_info[pane]
				if info and info.block == "worktree.inventory" then
					nav = nav or pane
				else
					table.insert(content, pane)
				end
			end
			if not nav and content[1] then
				nav = cx.layout:split(content[1], "left", inventory_launch(path, host_name, host.kind),
					{ focus = false })
				if not nav then
					cx:toast("error", "Could not show worktrees in " .. (tab.name or "tab"))
				end
			end
			if nav then
				if not host_kind_sent[nav] then
					cx.session:event(nav, { ev = "action", act = "host_kind", value = host.kind })
					host_kind_sent[nav] = true
				end
				layout = cx.session:layout(tab.id)
				local at_left = layout and layout.root.split == "right"
					and layout.root[1] and layout.root[1].pane == nav
				if not at_left and content[1] then
					cx.layout:move(nav, content[1], "left", { focus = false })
					if content[2] and (tab.name == "editor" or tab.name == "agents") then
						cx.layout:move(content[2], content[1],
							tab.name == "editor" and "down" or "right", { focus = false })
					end
				end
				normalize_ratios(cx, tab, nav)
			end
		end
	end
end

local function set_repo(repo)
	if current_repo ~= repo then
		current_repo = repo
		tern.chrome.refresh()
	end
end

local function open_inventory(cx, intent)
	local pane = cx.session:focused()
	local info = pane and cx.session:pane(pane)
	local host = cx.hosts:current()
	local tab = pane and cx.session:tab_of(pane)
	for _, existing in cx.session:panes() do
		if existing.block == "worktree.inventory" and existing.tab == tab then
			cx.layout:focus(existing.pane)
			if intent then cx.session:event(existing.pane, { ev = "action", act = intent }) end
			return
		end
	end
	if not info or not info.cwd or info.cwd == "" then
		cx:toast("error", "Cannot discover worktrees", "Focused pane has no known working directory")
		return
	end
	local opened = cx.layout:split(pane, "left", {
		cwd = info.cwd,
		block = "worktree.inventory",
		args = { info.cwd, host.name, intent or "", host.kind },
	})
	if not opened then
		cx:toast("error", "Cannot open worktree panel", "Install the plugin on " .. host.name)
	end
end

local function named_tab(cx, session_id, name)
	for _, tab in cx.session:tabs() do
		if tab.session == session_id and tab.name == name then return tab.id end
	end
	return nil
end

local function keep_git_last(cx, session_id)
	local git_tab, count, position = nil, 0, nil
	for _, tab in cx.session:tabs() do
		if tab.session == session_id then
			count += 1
			if tab.name == "git" then
				git_tab = tab.id
				position = tab.position
			end
		end
	end
	if git_tab and position ~= count then cx.layout:order_tab(git_tab, count) end
end

local function create_tab(cx, session_id, name, spec)
	local existing = named_tab(cx, session_id, name)
	if existing then return existing, false end
	local tab, err = cx.layout:tab(spec)
	if err then
		cx:toast("error", "Could not create " .. name .. " tab", err)
		-- A later leaf can fail after Tern has already created part of the tab.
		-- Discard only this new, incomplete tab so a later switch can retry.
		if tab then
			for _, pane in cx.session:panes() do
				if pane.tab == tab then cx.layout:close(pane.pane) end
			end
		end
		return nil, false
	end
	if not tab then
		cx:toast("error", "Could not create " .. name .. " tab")
		return nil, false
	end
	return tab, true
end

local function initialize(cx, session, path, starter)
	local host = cx.hosts:current()
	if host.state ~= "connected" then return end
	local host_name = host.name

	local editor, new_editor = create_tab(cx, session.id, "editor", {
		name = "editor", cwd = path, split = "right", ratio = 0.22,
		[1] = { launch = inventory_launch(path, host_name, host.kind) },
		[2] = { split = "down", ratio = config.editor_split_ratio,
			[1] = { launch = { cwd = path } },
			[2] = { launch = { cwd = path } },
		},
	})
	if not editor then return end
	if new_editor then
		-- Type into login shells so aliases work and failed commands leave a prompt.
		local tree = cx.session:layout(editor)
		local content = tree and tree.root[2]
		if content and content[1] and content[1].pane and content[2] and content[2].pane then
			start_shell(cx, content[1].pane, path, config.editor_command)
			start_shell(cx, content[2].pane, path, config.agent_command)
		else
			cx:toast("error", "Could not start editor commands", "Editor pane layout is unavailable")
		end
	end
	local agents, new_agents = create_tab(cx, session.id, "agents", {
		name = "agents", cwd = path, split = "right", ratio = 0.22,
		[1] = { launch = inventory_launch(path, host_name, host.kind) },
		[2] = { split = "right", ratio = config.agents_split_ratio,
			[1] = { launch = { cwd = path } },
			[2] = { launch = { cwd = path } },
		},
	})
	if not agents then return end
	if new_agents then
		local tree = cx.session:layout(agents)
		local content = tree and tree.root[2]
		if content and content[1] and content[1].pane and content[2] and content[2].pane then
			start_shell(cx, content[1].pane, path)
			start_shell(cx, content[2].pane, path)
		end
	end
	local git_tab, new_git = create_tab(cx, session.id, "git", {
		name = "git", cwd = path, split = "right", ratio = 0.22,
		[1] = { launch = inventory_launch(path, host_name, host.kind) },
		[2] = { launch = { cwd = path } },
	})
	if not git_tab then return end
	if new_git then
		local tree = cx.session:layout(git_tab)
		if tree and tree.root[2] and tree.root[2].pane then
			start_shell(cx, tree.root[2].pane, path, config.git_command)
		else
			cx:toast("error", "Could not start lazygit", "Git pane layout is unavailable")
		end
	end
	if starter then cx.layout:close(starter) end
	if starter then
		local layout = cx.session:layout(editor)
		if layout then cx.layout:focus(layout.focus) end
	end
	keep_git_last(cx, session.id)
end

local function ensure_initialized(cx, session, path, starter)
	if initialized_sessions[session.id] then return end
	initialize(cx, session, path, starter)
	if named_tab(cx, session.id, "editor") and named_tab(cx, session.id, "agents")
		and named_tab(cx, session.id, "git") then
		initialized_sessions[session.id] = true
	end
end

local function open_managed_tab(cx, name)
	local session = cx.sessions:current()
	local identity = session_identity(session.name)
	if not identity or (window_common_dir and window_common_dir ~= identity.common_dir) then
		cx:toast("error", "Select a worktree before opening its " .. name .. " tab")
		return
	end
	if cx.hosts:current().state ~= "connected" then
		cx:toast("error", "Worktree host is disconnected")
		return
	end
	local existed = named_tab(cx, session.id, name) ~= nil
	if not existed then
		-- An explicit Open repairs a manually closed default tab.
		initialized_sessions[session.id] = nil
		ensure_initialized(cx, session, identity.path, nil)
	end
	local tab = named_tab(cx, session.id, name)
	if not tab then return end
	ensure_inventories(cx, session.id, identity.path)
	local layout = cx.session:layout(tab)
	local pane = layout and layout.focus
	if not existed then
		for _, item in cx.session:panes() do
			if item.tab == tab and item.block ~= "worktree.inventory" then
				pane = item.pane
				break
			end
		end
	end
	if pane then cx.layout:focus(pane) end
end

local function new_worktree_shell(cx)
	local session = cx.sessions:current()
	local identity = session_identity(session.name)
	if not identity or (window_common_dir and window_common_dir ~= identity.common_dir) then
		return false
	end
	local focused = cx.session:focused()
	local pane = focused and cx.session:pane(focused)
	if not pane or not pane.cwd or pane.cwd == "" then
		cx:toast("error", "Cannot open worktree shell", "Focused pane has no known working directory")
		return true
	end
	local opened = cx.layout:new_tab({ cwd = pane.cwd })
	if not opened then
		cx:toast("error", "Could not open worktree shell")
		return true
	end
	start_shell(cx, opened, identity.path)
	keep_git_last(cx, session.id)
	ensure_inventories(cx, session.id, identity.path)
	return true
end

local function switch_to(cx, common_dir, path)
	if string.sub(path, 1, 1) ~= "/" then
		cx:toast("error", "Invalid worktree path")
		return
	end
	if window_common_dir and window_common_dir ~= common_dir then
		cx:toast("error", "This window belongs to another repository",
			"Open the other repository in a separate Tern window")
		return
	end
	window_common_dir = common_dir
	local name = session_name(common_dir, path)
	local host = cx.hosts:current()
	for _, session in cx.sessions:list() do
		if session.host == host.id and session.name == name then
			cx.sessions:switch(session.id)
			set_repo(repo_from_session(name))
			ensure_initialized(cx, session, path, nil)
			ensure_inventories(cx, session.id, path)
			return
		end
	end
	local session = cx.sessions:create({ name = name, cwd = path })
	local starter = nil
	for _, tab in cx.session:tabs() do
		if tab.session == session.id then starter = tab.pane; break end
	end
	set_repo(repo_from_session(name))
	ensure_initialized(cx, session, path, starter)
end

tern.command({ id = "discover", title = "Worktree: Discover", icon = "branch", run = open_inventory })
tern.command({ id = "switch", title = "Worktree: Switch", icon = "branch", run = open_inventory })
tern.command({ id = "new", title = "Worktree: New", icon = "plus", run = function(cx)
	open_inventory(cx, "new")
end })
tern.command({ id = "remove", title = "Worktree: Remove", icon = "trash", run = function(cx)
	open_inventory(cx, "remove")
end })
tern.command({ id = "run_setup", title = "Worktree: Run Setup", icon = "play", run = function(cx)
	open_inventory(cx, "setup")
end })
tern.command({ id = "open_editor", title = "Worktree: Open Editor Tab", icon = "file",
	run = function(cx) open_managed_tab(cx, "editor") end })
tern.command({ id = "open_agents", title = "Worktree: Open Agents Tab", icon = "terminal",
	run = function(cx) open_managed_tab(cx, "agents") end })
tern.command({ id = "open_git", title = "Worktree: Open Git Tab", icon = "branch",
	run = function(cx) open_managed_tab(cx, "git") end })
tern.override("new_tab", new_worktree_shell)

local function refresh_repo_inventories(cx, common_dir, source_pane, visible_session)
	local host_id = cx.hosts:current().id
	local sessions = {}
	local paths = {}
	for _, session in cx.sessions:list() do
		local identity = session_identity(session.name)
		if session.host == host_id and identity and identity.common_dir == common_dir then
			table.insert(paths, identity.path)
			if not visible_session or session.id == visible_session then
				sessions[session.id] = true
			end
		end
	end
	local tabs = {}
	for _, tab in cx.session:tabs() do
		if sessions[tab.session] then tabs[tab.id] = true end
	end
	local refreshed = {}
	for _, pane in cx.session:panes() do
		if tabs[pane.tab] and pane.block == "worktree.inventory" then
			cx.session:event(pane.pane, { ev = "action", act = "managed_paths", value = paths })
			cx.session:event(pane.pane, { ev = "action", act = "refresh" })
			refreshed[pane.pane] = true
		end
	end
	if source_pane and not refreshed[source_pane] then
		local source = cx.session:pane(source_pane)
		if source and source.block == "worktree.inventory" then
			cx.session:event(source_pane, { ev = "action", act = "managed_paths", value = paths })
			cx.session:event(source_pane, { ev = "action", act = "refresh" })
		end
	end
	last_refresh_at = tern.now()
	last_visible_session = cx.sessions:current().id
end

tern.command({ id = "refresh", title = "Worktree: Refresh", icon = "refresh", run = function(cx)
	local current = cx.sessions:current()
	local identity = session_identity(current.name)
	if identity and (not window_common_dir or window_common_dir == identity.common_dir) then
		if cx.hosts:current().state ~= "connected" then
			cx:toast("error", "Worktree host is disconnected")
			return
		end
		ensure_inventories(cx, current.id, identity.path)
		refresh_repo_inventories(cx, identity.common_dir)
	else
		open_inventory(cx, "refresh_all")
	end
end })

local function maybe_auto_refresh(cx)
	local current = cx.sessions:current()
	local identity = session_identity(current.name)
	if not identity or (window_common_dir and window_common_dir ~= identity.common_dir) then return end
	local host = cx.hosts:current()
	local reconnected = host.id ~= last_host_id or last_host_state ~= "connected"
	last_host_id = host.id
	last_host_state = host.state
	if host.state ~= "connected" then return end
	local now = tern.now()
	if not reconnected and last_visible_session == current.id
		and now - last_refresh_at < AUTO_REFRESH_MS then return end
	refresh_repo_inventories(cx, identity.common_dir, nil, current.id)
	last_visible_session = current.id
end

tern.route.link(function(link, cx)
	local encoded_refresh = string.match(link.url, "^tern%-worktree://refresh/([0-9a-f]+)$")
	if encoded_refresh then
		local common_dir = unhex(encoded_refresh)
		if not common_dir then return { handled = true } end
		local source = link.pane and cx.session:pane(link.pane)
		if (not source or source.block ~= "worktree.inventory")
			and window_common_dir ~= common_dir then return { handled = true } end
		if window_common_dir and window_common_dir ~= common_dir then return { handled = true } end
		refresh_repo_inventories(cx, common_dir, link.pane)
		return { handled = true }
	end
	local removed_common, removed_path, anchor_path = string.match(link.url,
		"^tern%-worktree://removed/([0-9a-f]+)/([0-9a-f]+)/([0-9a-f]+)$")
	local stale_cleanup = false
	if not removed_common then
		removed_common, removed_path, anchor_path = string.match(link.url,
			"^tern%-worktree://stale%-cleanup/([0-9a-f]+)/([0-9a-f]+)/([0-9a-f]+)$")
		stale_cleanup = removed_common ~= nil
	end
	if removed_common then
		local common_dir, path, anchor = unhex(removed_common), unhex(removed_path), unhex(anchor_path)
		if not common_dir or not path or not anchor then return { handled = true } end
		local source = link.pane and cx.session:pane(link.pane)
		if (not source or source.block ~= "worktree.inventory")
			and window_common_dir ~= common_dir then return { handled = true } end
		if window_common_dir and window_common_dir ~= common_dir then return { handled = true } end
		local current = cx.sessions:current()
		local host_id = cx.hosts:current().id
		for _, session in cx.sessions:list() do
			if session.host == host_id and session.name == session_name(common_dir, path) then
				if session.id == current.id then switch_to(cx, common_dir, anchor) end
				cx.sessions:close(session.id)
				initialized_sessions[session.id] = nil
				break
			end
		end
		refresh_repo_inventories(cx, common_dir)
		if stale_cleanup then cx:toast("success", "Closed unavailable worktree session", path) end
		return { handled = true }
	end
	local action, encoded_common, encoded_path = string.match(link.url,
		"^tern%-worktree://([a-z]+)/([0-9a-f]+)/([0-9a-f]+)$")
	if action ~= "switch" and action ~= "created" then return nil end
	local common_dir, path = unhex(encoded_common), unhex(encoded_path)
	if not common_dir or not path then return { handled = true } end
	local source = link.pane and cx.session:pane(link.pane)
	-- Delayed host effects can arrive after focus has moved away from the
	-- inventory block. Once bound, the repo identity still scopes the link.
	if (not source or source.block ~= "worktree.inventory")
		and window_common_dir ~= common_dir then return { handled = true } end
	switch_to(cx, common_dir, path)
	if action == "created" then refresh_repo_inventories(cx, common_dir) end
	return { handled = true }
end)

tern.chrome.window_title(function()
	if current_repo then return "Tern — " .. current_repo end
	return nil
end)

local function show_current_repo(cx)
	local current = cx.sessions:current()
	local identity = session_identity(current.name)
	if identity then
		if window_common_dir and window_common_dir ~= identity.common_dir then return end
		window_common_dir = identity.common_dir
		set_repo(repo_from_session(current.name))
		ensure_initialized(cx, current, identity.path, nil)
		ensure_inventories(cx, current.id, identity.path)
	end
end

tern.on("window_start", function(cx)
	show_current_repo(cx)
	maybe_auto_refresh(cx)
end)

-- window_start is not replayed when an already-open window reloads the plugin.
tern.timer(100, function(cx)
	if cx then
		show_current_repo(cx)
		maybe_auto_refresh(cx)
	end
end)

tern.on("focus", function(_, cx)
	show_current_repo(cx)
	maybe_auto_refresh(cx)
end)

-- Tern has no OS-window-activation or host-reconnected event. The lightweight
-- poll notices both a reconnect and Git changes while a pane stays focused.
local function auto_poll(cx)
	if cx then
		local current = cx.sessions:current()
		if not initialized_sessions[current.id] then show_current_repo(cx) end
		maybe_auto_refresh(cx)
	end
	tern.timer(AUTO_POLL_MS, auto_poll)
end
tern.timer(AUTO_POLL_MS, auto_poll)

-- A normal Tern pane split also starts a shell. Only the initiating window
-- focuses its new pane, so this avoids sourcing twice in shared sessions.
tern.on("pane_created", function(ev, cx)
	if initialized_shells[ev.pane] or cx.session:focused() ~= ev.pane then return end
	local identity = session_identity(cx.sessions:current().name)
	if not identity then return end
	local pane = cx.session:pane(ev.pane)
	if not pane or pane.block or not pane.cwd or not within(pane.cwd, identity.path) then return end
	local program = string.match(pane.program or "", "([^/]+)$")
	if program == "zsh" or program == "bash" or program == "sh" or program == "ksh"
		or program == "dash" or program == "ash" then
		start_shell(cx, ev.pane, identity.path)
	end
end)

tern.on("pane_closed", function(ev)
	initialized_shells[ev.pane] = nil
end)

tern.on("tab_created", function(ev, cx)
	for _, tab in cx.session:tabs() do
		if tab.id == ev.tab then
			if tab.name ~= "editor" and tab.name ~= "agents" and tab.name ~= "git" then
				show_current_repo(cx)
			end
			return
		end
	end
end)
