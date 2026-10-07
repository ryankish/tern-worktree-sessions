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

local function repo_from_session(name)
	local encoded = string.match(name, "^tern%-wt:([0-9a-f]+):[0-9a-f]+$")
	if not encoded then return nil end
	local common_dir = unhex(encoded)
	if not common_dir then return nil end
	local root = string.gsub(common_dir, "/%.git$", "")
	return string.match(root, "([^/]+)$") or root
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
	local starter = nil
	for _, tab in cx.session:tabs() do
		if tab.session == session.id then starter = tab.pane; break end
	end

	local editor, editor_error = cx.layout:tab({
		name = "editor", cwd = path, split = "down", ratio = 0.65,
		[1] = { launch = { cwd = path, command = "nvim" } },
		[2] = { launch = { cwd = path, command = "codex" } },
	})
	if not editor then
		cx:toast("error", "Could not create editor tab", editor_error)
		return
	end
	local agents, agents_error = cx.layout:tab({
		name = "agents", cwd = path, split = "right", ratio = 0.5,
		[1] = { launch = { cwd = path } },
		[2] = { launch = { cwd = path } },
	})
	if not agents then
		cx:toast("error", "Could not create agents tab", agents_error)
		return
	end
	local git_tab, git_error = cx.layout:tab({
		name = "git", cwd = path, launch = { cwd = path, command = "lazygit" },
	})
	if not git_tab then
		cx:toast("error", "Could not create git tab", git_error)
		return
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

tern.on("window_start", function(cx)
	set_repo(repo_from_session(cx.sessions:current().name))
end)

tern.on("focus", function(_, cx)
	local repo = repo_from_session(cx.sessions:current().name)
	if repo then set_repo(repo) end
end)
