local PREFIX = "tern-wt:"
local current_repo = nil

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

local function inventory_launch(path, host_name)
	return { cwd = path, block = "worktree.inventory", args = { path, host_name } }
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
			if not set_share(cx, content[1].pane, "down", 0.65, editor_share) then return end
		end
	end
	tern.kv.set(key, true)
end

local function ensure_inventories(cx, session_id, path)
	local host_name = cx.hosts:current().name
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
				nav = cx.layout:split(content[1], "left", inventory_launch(path, host_name),
					{ focus = false })
				if not nav then
					cx:toast("error", "Could not show worktrees in " .. (tab.name or "tab"))
				end
			end
			if nav then
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

local function open_inventory(cx)
	local pane = cx.session:focused()
	local info = pane and cx.session:pane(pane)
	local host = cx.hosts:current()
	local tab = pane and cx.session:tab_of(pane)
	for _, existing in cx.session:panes() do
		if existing.block == "worktree.inventory" and existing.tab == tab then
			cx.layout:focus(existing.pane)
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
		args = { info.cwd, host.name },
	})
	if not opened then
		cx:toast("error", "Cannot open worktree panel", "Install the plugin on " .. host.name)
	end
end

local function initialize(cx, session, path)
	local host_name = cx.hosts:current().name
	local starter = nil
	for _, tab in cx.session:tabs() do
		if tab.session == session.id then starter = tab.pane; break end
	end

	local editor, editor_error = cx.layout:tab({
		name = "editor", cwd = path, split = "right", ratio = 0.22,
		[1] = { launch = inventory_launch(path, host_name) },
		[2] = { split = "down", ratio = 0.65,
			[1] = { launch = { cwd = path } },
			[2] = { launch = { cwd = path } },
		},
	})
	if not editor then
		cx:toast("error", "Could not create editor tab", editor_error)
		return
	end
	local agents, agents_error = cx.layout:tab({
		name = "agents", cwd = path, split = "right", ratio = 0.22,
		[1] = { launch = inventory_launch(path, host_name) },
		[2] = { split = "right", ratio = 0.5,
			[1] = { launch = { cwd = path } },
			[2] = { launch = { cwd = path } },
		},
	})
	if not agents then
		cx:toast("error", "Could not create agents tab", agents_error)
		return
	end
	local git_tab, git_error = cx.layout:tab({
		name = "git", cwd = path, split = "right", ratio = 0.22,
		[1] = { launch = inventory_launch(path, host_name) },
		[2] = { launch = { cwd = path } },
	})
	if not git_tab then
		cx:toast("error", "Could not create git tab", git_error)
		return
	end
	-- Tern command launches use a noninteractive shell. Type into the ordinary
	-- interactive shells so aliases work and failures leave a usable prompt.
	local editor_tree = cx.session:layout(editor)
	local git_tree = cx.session:layout(git_tab)
	if editor_tree and editor_tree.root[2] and editor_tree.root[2][1]
		and editor_tree.root[2][1].pane and editor_tree.root[2][2]
		and editor_tree.root[2][2].pane then
		cx:run(editor_tree.root[2][1].pane, "nvim\r")
		cx:run(editor_tree.root[2][2].pane, "codex\r")
	else
		cx:toast("error", "Could not start editor commands", "Editor pane layout is unavailable")
	end
	if git_tree and git_tree.root[2] and git_tree.root[2].pane then
		cx:run(git_tree.root[2].pane, "lazygit\r")
	else
		cx:toast("error", "Could not start lazygit", "Git pane layout is unavailable")
	end
	if starter then cx.layout:close(starter) end
	local layout = cx.session:layout(editor)
	if layout then cx.layout:focus(layout.focus) end
end

local function switch_to(cx, common_dir, path)
	if string.sub(path, 1, 1) ~= "/" then
		cx:toast("error", "Invalid worktree path")
		return
	end
	local name = session_name(common_dir, path)
	local host = cx.hosts:current()
	for _, session in cx.sessions:list() do
		if session.host == host.id and session.name == name then
			cx.sessions:switch(session.id)
			set_repo(repo_from_session(name))
			ensure_inventories(cx, session.id, path)
			return
		end
	end
	local session = cx.sessions:create({ name = name, cwd = path })
	set_repo(repo_from_session(name))
	initialize(cx, session, path)
end

tern.command({ id = "discover", title = "Worktree: Discover", icon = "branch", run = open_inventory })
tern.command({ id = "switch", title = "Worktree: Switch", icon = "branch", run = open_inventory })

tern.route.link(function(link, cx)
	local encoded_common, encoded_path = string.match(link.url,
		"^tern%-worktree://switch/([0-9a-f]+)/([0-9a-f]+)$")
	if not encoded_common then return nil end
	local source = link.pane and cx.session:pane(link.pane)
	if not source or source.block ~= "worktree.inventory" then return { handled = true } end
	local common_dir, path = unhex(encoded_common), unhex(encoded_path)
	if common_dir and path then switch_to(cx, common_dir, path) end
	return { handled = true }
end)

tern.chrome.window_title(function()
	if current_repo then return "Tern — " .. current_repo end
	return nil
end)

local function show_current_repo(cx)
	local current = cx.sessions:current()
	set_repo(repo_from_session(current.name))
	local identity = session_identity(current.name)
	if identity then ensure_inventories(cx, current.id, identity.path) end
end

tern.on("window_start", show_current_repo)

-- window_start is not replayed when an already-open window reloads the plugin.
tern.timer(100, function(cx)
	if cx then show_current_repo(cx) end
end)

tern.on("focus", function(_, cx)
	show_current_repo(cx)
end)
