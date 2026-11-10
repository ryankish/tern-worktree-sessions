local config = require("./config")
local paths = require("./paths")
local hex, unhex = paths.hex, paths.unhex
local session_name, session_identity = paths.session_name, paths.session_identity
local repo_from_session, within = paths.repo_from_session, paths.within
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

local function inventory_launch(path, host_name, host_kind)
	return { cwd = path, block = "worktree-sessions.inventory", args = { path, host_name, "", host_kind } }
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
	cx:run(pane, paths.shell_startup(path, config.shell_hook, command))
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

local INVENTORY = "worktree-sessions.inventory"

local function tab_panes(cx, tab_id)
	local panes = {}
	for _, pane in cx.session:panes() do
		if pane.tab == tab_id then panes[pane.pane] = pane end
	end
	return panes
end

-- The panes of the worktree column, as a set, or nil when the panel isn't at the
-- left edge. The column is the left side of the tab's root split. Besides the
-- panel it may hold other plugins' blocks stacked above or below it; they stay
-- in the column and aren't tab content. Anything else there needs repairing.
local function worktree_column(layout, nav, panes)
	local root = layout and layout.root
	if not root or root.split ~= "right" or not root[1] then return nil end
	local ordered = {}
	leaves(root[1], ordered)
	local column, found = {}, false
	for _, pane in ordered do
		local info = panes[pane]
		if pane == nav then
			found = true
		elseif not (info and info.block) then
			return nil
		end
		column[pane] = true
	end
	return found and column or nil
end

-- The worktree column's share of the tab's width, or nil when it isn't at the left edge.
local function column_share(cx, tab_id, nav)
	local layout = cx.session:layout(tab_id)
	if not worktree_column(layout, nav, tab_panes(cx, tab_id)) then return nil end
	return layout.root.ratio or 0.5
end

local function normalize_ratios(cx, tab, nav)
	local key = "layout-v2:" .. tostring(tab.id)
	if tern.kv.get(key) then return end
	local function root_share() return column_share(cx, tab.id, nav) end
	if not set_share(cx, nav, "right", config.panel_ratio, root_share) then return end
	local tab_config = config.tab(tab.name)
	if tab_config and #tab_config.panes > 1 then
		local layout = cx.session:layout(tab.id)
		local content = layout and layout.root[2]
		if content and content.split == tab_config.split and content[1] and content[1].pane then
			local function first_share()
				local current = cx.session:layout(tab.id)
				local right = current and current.root[2]
				return right and right.ratio or nil
			end
			if not set_share(cx, content[1].pane, tab_config.split, tab_config.ratio, first_share) then return end
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
			local panes = tab_panes(cx, tab.id)
			local nav = nil
			for _, pane in ordered do
				local info = panes[pane]
				if info and info.block == INVENTORY then nav = nav or pane end
			end
			local column = nav and worktree_column(layout, nav, panes)
			local content = {}
			for _, pane in ordered do
				local info = panes[pane]
				if not (info and info.block == INVENTORY) and not (column and column[pane]) then
					table.insert(content, pane)
				end
			end
			if not nav and content[1] then
				nav = cx.layout:split(content[1], "left", inventory_launch(path, host_name, host.kind),
					{ focus = false })
				if nav then
					column = worktree_column(cx.session:layout(tab.id), nav, tab_panes(cx, tab.id))
				else
					cx:toast("error", "Could not show worktrees in " .. (tab.name or "tab"))
				end
			end
			if nav then
				if not host_kind_sent[nav] then
					cx.session:event(nav, { ev = "action", act = "host_kind", value = host.kind })
					host_kind_sent[nav] = true
				end
				if not column and content[1] then
					cx.layout:move(nav, content[1], "left", { focus = false })
					local tab_config = config.tab(tab.name)
					if tab_config and #tab_config.panes == #content then
						for i = 2, #content do
							cx.layout:move(content[i], content[i - 1], tab_config.split, { focus = false })
						end
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

local config_error_shown = false

local function open_inventory(cx, intent)
	if config.error and not config_error_shown then
		config_error_shown = true
		cx:toast("error", "Worktree Sessions config.json has a problem", config.error)
	end
	local pane = cx.session:focused()
	local info = pane and cx.session:pane(pane)
	local host = cx.hosts:current()
	if intent == "discover" and session_identity(cx.sessions:current().name) then intent = nil end
	local tab = pane and cx.session:tab_of(pane)
	for _, existing in cx.session:panes() do
		if existing.block == "worktree-sessions.inventory" and existing.tab == tab then
			cx.layout:focus(existing.pane)
			if intent then
				cx.session:event(existing.pane, { ev = "action", act = intent,
					cwd = info and info.cwd or nil })
			end
			return
		end
	end
	if not info or not info.cwd or info.cwd == "" then
		cx:toast("error", "Cannot discover worktrees", "Focused pane has no known working directory")
		return
	end
	local opened = cx.layout:split(pane, "left", {
		cwd = info.cwd,
		block = "worktree-sessions.inventory",
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

-- Tabs with pin = "right" stay at the right edge, in config order.
local function keep_pinned_last(cx, session_id)
	local by_name, count = {}, 0
	for _, tab in cx.session:tabs() do
		if tab.session == session_id then
			count += 1
			by_name[tab.name or ""] = tab
		end
	end
	local pinned = {}
	for _, tab_config in config.tabs do
		local tab = tab_config.pin == "right" and by_name[tab_config.name]
		if tab then table.insert(pinned, tab) end
	end
	local in_place = true
	for i, tab in pinned do
		if tab.position ~= count - #pinned + i then in_place = false end
	end
	if in_place then return end
	for _, tab in pinned do cx.layout:order_tab(tab.id, count) end
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

-- Builds the configured panes along one split, the first taking `ratio`.
local function pane_spec(path, count, split, ratio, i)
	if i == count then return { launch = { cwd = path } } end
	return {
		split = split,
		ratio = i == 1 and ratio or 1 / (count - i + 1),
		[1] = { launch = { cwd = path } },
		[2] = pane_spec(path, count, split, ratio, i + 1),
	}
end

local function initialize(cx, session, path, starter)
	local host = cx.hosts:current()
	if host.state ~= "connected" then return end
	-- After the starter pane closes, focus the first tab that isn't pinned.
	local focus_tab, pinned_tab = nil, nil
	for _, tab_config in config.tabs do
		local tab, created = create_tab(cx, session.id, tab_config.name, {
			name = tab_config.name, cwd = path, split = "right", ratio = config.panel_ratio,
			[1] = { launch = inventory_launch(path, host.name, host.kind) },
			[2] = pane_spec(path, #tab_config.panes, tab_config.split, tab_config.ratio, 1),
		})
		if not tab then return end
		if tab_config.pin then pinned_tab = pinned_tab or tab else focus_tab = focus_tab or tab end
		if created then
			-- Type into login shells so aliases work and failed commands leave a prompt.
			local tree = cx.session:layout(tab)
			local content = {}
			if tree and tree.root[2] then leaves(tree.root[2], content) end
			if #content == #tab_config.panes then
				for i, pane in content do start_shell(cx, pane, path, tab_config.panes[i].command) end
			else
				cx:toast("error", "Could not start " .. tab_config.name .. " commands", "Pane layout is unavailable")
			end
		end
	end
	if starter then
		cx.layout:close(starter)
		local focus = focus_tab or pinned_tab
		local layout = focus and cx.session:layout(focus)
		if layout then cx.layout:focus(layout.focus) end
	end
	keep_pinned_last(cx, session.id)
end

local function ensure_initialized(cx, session, path, starter)
	if initialized_sessions[session.id] then return end
	initialize(cx, session, path, starter)
	for _, tab_config in config.tabs do
		if not named_tab(cx, session.id, tab_config.name) then return end
	end
	initialized_sessions[session.id] = true
end

local function find_inventory(cx, tab)
	for _, item in cx.session:panes() do
		if item.tab == tab and item.block == INVENTORY then return item.pane end
	end
	return nil
end

-- Reopens the command of a one-pane tab whose program exited.
local function restore_command_pane(cx, session, tab, path, command)
	local nav = find_inventory(cx, tab)
	local layout = cx.session:layout(tab)
	local column = nav and worktree_column(layout, nav, tab_panes(cx, tab)) or {}
	local exited = {}
	for _, item in cx.session:panes() do
		if item.tab == tab and item.block ~= INVENTORY and not column[item.pane] then
			-- A live shell may be running something else; preserve it.
			if not item.exited then return item.pane end
			table.insert(exited, item.pane)
		end
	end
	-- Other plugins' blocks in the column, top to bottom, to put back under the panel.
	local stacked = {}
	if column[nav] then
		local ordered = {}
		leaves(layout.root[1], ordered)
		for _, pane in ordered do
			if pane ~= nav then table.insert(stacked, pane) end
		end
	end
	if not nav then
		ensure_inventories(cx, session.id, path)
		nav = find_inventory(cx, tab)
	end
	if not nav then
		cx:toast("error", "Cannot restore pane", "Worktree inventory pane is unavailable")
		return nil
	end
	for _, pane in exited do cx.layout:close(pane) end
	local pane = cx.layout:split(nav, "right", { cwd = path }, { focus = false })
	if not pane then
		cx:toast("error", "Cannot restore pane")
		return nil
	end
	-- Splitting the panel put the new pane inside the column, above the stacked
	-- blocks; moving them back under the panel leaves it to the column's right.
	local above = nav
	for _, block in stacked do
		cx.layout:move(block, above, "down", { focus = false })
		above = block
	end
	start_shell(cx, pane, path, command)
	set_share(cx, nav, "right", config.panel_ratio, function() return column_share(cx, tab, nav) end)
	keep_pinned_last(cx, session.id)
	return pane
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
	local tab_config = config.tab(name)
	if tab_config and #tab_config.panes == 1 and tab_config.panes[1].command then
		pane = restore_command_pane(cx, session, tab, identity.path, tab_config.panes[1].command) or pane
	elseif not existed then
		for _, item in cx.session:panes() do
			if item.tab == tab and not item.block then
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
	keep_pinned_last(cx, session.id)
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

tern.command({ id = "discover", title = "Worktree Sessions: Discover", icon = "branch", run = function(cx)
	open_inventory(cx, "discover")
end })
tern.command({ id = "switch", title = "Worktree Sessions: Switch", icon = "branch", run = open_inventory })
tern.command({ id = "new", title = "Worktree Sessions: New Worktree", icon = "plus", run = function(cx)
	open_inventory(cx, "new")
end })
tern.command({ id = "remove", title = "Worktree Sessions: Remove Worktree", icon = "trash", run = function(cx)
	open_inventory(cx, "remove")
end })
tern.command({ id = "run_setup", title = "Worktree Sessions: Run Setup", icon = "play", run = function(cx)
	open_inventory(cx, "setup")
end })

-- One "Open <name> Tab" command per configured tab.
for _, tab_config in config.tabs do
	local name = tab_config.name
	tern.command({ id = tab_config.command_id, title = "Worktree Sessions: Open " .. name .. " Tab",
		icon = "terminal", run = function(cx) open_managed_tab(cx, name) end })
end

tern.command({ id = "edit_config", title = "Worktree Sessions: Edit Config", icon = "file",
	run = function(cx)
		if not tern.fs.exists(config.path) then
			tern.fs.mkdir(tern.plugin.data)
			tern.fs.write(config.path, config.TEMPLATE)
		end
		cx:open(config.path, "tab")
		cx:toast("success", "Editing Worktree Sessions config",
			"Save, then run: tern plugin reload worktree-sessions")
	end })
tern.override("new_tab", new_worktree_shell)

local function refresh_repo_inventories(cx, common_dir, source_pane, visible_session, force_pr)
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
	local force_pending = force_pr
	for _, pane in cx.session:panes() do
		if tabs[pane.tab] and pane.block == "worktree-sessions.inventory" then
			cx.session:event(pane.pane, { ev = "action", act = "managed_paths", value = paths })
			cx.session:event(pane.pane, { ev = "action", act = "refresh", force_pr = force_pending })
			force_pending = false
			refreshed[pane.pane] = true
		end
	end
	if source_pane and not refreshed[source_pane] then
		local source = cx.session:pane(source_pane)
		if source and source.block == "worktree-sessions.inventory" then
			cx.session:event(source_pane, { ev = "action", act = "managed_paths", value = paths })
			cx.session:event(source_pane, { ev = "action", act = "refresh", force_pr = force_pending })
		end
	end
	last_refresh_at = tern.now()
	last_visible_session = cx.sessions:current().id
end

tern.command({ id = "refresh", title = "Worktree Sessions: Refresh", icon = "refresh", run = function(cx)
	local current = cx.sessions:current()
	local identity = session_identity(current.name)
	if identity and (not window_common_dir or window_common_dir == identity.common_dir) then
		if cx.hosts:current().state ~= "connected" then
			cx:toast("error", "Worktree host is disconnected")
			return
		end
		ensure_inventories(cx, current.id, identity.path)
		refresh_repo_inventories(cx, identity.common_dir, nil, nil, true)
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
	local encoded_github = string.match(link.url, "^worktree%-sessions://github/([0-9a-f]+)$")
	if encoded_github then
		local url = unhex(encoded_github)
		if not url or #url > 4096 or not string.match(url, "^https://[^/%s]+/") then
			return { handled = true }
		end
		local argv = nil
		if tern.runtime.os == "macos" then
			argv = { "/usr/bin/open", url }
		elseif tern.runtime.os == "linux" then
			argv = { "xdg-open", url }
		elseif tern.runtime.os == "windows" then
			argv = { "rundll32.exe", "url.dll,FileProtocolHandler", url }
		end
		if not argv then
			cx:copy(url)
			cx:toast("error", "Could not open GitHub externally", "Link copied to clipboard")
			return { handled = true }
		end
		local ok, err = pcall(function()
			tern.process.run(argv, { timeout_ms = 10000 }, function(result, result_cx)
				if result.status ~= 0 and result_cx then
					result_cx:copy(url)
					result_cx:toast("error", "Could not open GitHub externally",
						"Link copied to clipboard")
				end
			end)
		end)
		if not ok then
			cx:copy(url)
			cx:toast("error", "Could not open GitHub externally", tostring(err))
		end
		return { handled = true }
	end
	local encoded_refresh = string.match(link.url, "^worktree%-sessions://refresh/([0-9a-f]+)$")
	local force_pr = false
	if not encoded_refresh then
		encoded_refresh = string.match(link.url, "^worktree%-sessions://refresh%-pr/([0-9a-f]+)$")
		force_pr = encoded_refresh ~= nil
	end
	if encoded_refresh then
		local common_dir = unhex(encoded_refresh)
		if not common_dir then return { handled = true } end
		local source = link.pane and cx.session:pane(link.pane)
		if (not source or source.block ~= "worktree-sessions.inventory")
			and window_common_dir ~= common_dir then return { handled = true } end
		if window_common_dir and window_common_dir ~= common_dir then return { handled = true } end
		refresh_repo_inventories(cx, common_dir, link.pane, nil, force_pr)
		return { handled = true }
	end
	local removed_common, removed_path, anchor_path = string.match(link.url,
		"^worktree%-sessions://removed/([0-9a-f]+)/([0-9a-f]+)/([0-9a-f]+)$")
	local stale_cleanup = false
	if not removed_common then
		removed_common, removed_path, anchor_path = string.match(link.url,
			"^worktree%-sessions://stale%-cleanup/([0-9a-f]+)/([0-9a-f]+)/([0-9a-f]+)$")
		stale_cleanup = removed_common ~= nil
	end
	if removed_common then
		local common_dir, path, anchor = unhex(removed_common), unhex(removed_path), unhex(anchor_path)
		if not common_dir or not path or not anchor then return { handled = true } end
		local source = link.pane and cx.session:pane(link.pane)
		if (not source or source.block ~= "worktree-sessions.inventory")
			and window_common_dir ~= common_dir then return { handled = true } end
		if window_common_dir and window_common_dir ~= common_dir then return { handled = true } end
		local current = cx.sessions:current()
		local source_host = nil
		local source_tab = link.pane and cx.session:tab_of(link.pane)
		if source_tab then
			for _, tab in cx.session:tabs() do
				if tab.id == source_tab then
					for _, session in cx.sessions:list() do
						if session.id == tab.session then source_host = session.host; break end
					end
					break
				end
			end
		end
		local matches = {}
		for _, session in cx.sessions:list() do
			if session.name == session_name(common_dir, path)
				and (not source_host or session.host == source_host) then
				table.insert(matches, session)
			end
		end
		if #matches == 1 then
			local session = matches[1]
			if session.id == current.id then switch_to(cx, common_dir, anchor) end
			cx.sessions:close(session.id)
			initialized_sessions[session.id] = nil
		elseif #matches > 1 then
			cx:toast("error", "Worktree removed but sessions remain",
				"More than one host has a matching session; close the unavailable sessions explicitly")
		elseif not stale_cleanup then
			cx:toast("error", "Worktree removed but session remains",
				"Tern could not find its session in this window")
		end
		refresh_repo_inventories(cx, common_dir)
		if stale_cleanup then cx:toast("success", "Closed unavailable worktree session", path) end
		return { handled = true }
	end
	local action, encoded_common, encoded_path = string.match(link.url,
		"^worktree%-sessions://([a-z]+)/([0-9a-f]+)/([0-9a-f]+)$")
	if action ~= "switch" and action ~= "created" then return nil end
	local common_dir, path = unhex(encoded_common), unhex(encoded_path)
	if not common_dir or not path then return { handled = true } end
	local source = link.pane and cx.session:pane(link.pane)
	-- Delayed host effects can arrive after focus has moved away from the
	-- inventory block. Once bound, the repo identity still scopes the link.
	if (not source or source.block ~= "worktree-sessions.inventory")
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
			if not config.tab(tab.name) then
				show_current_repo(cx)
			end
			return
		end
	end
end)
