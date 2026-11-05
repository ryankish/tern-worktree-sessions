-- Worktree Sessions settings.
--
-- Defaults live here. To change them, write config.json in the plugin's data
-- directory (the "Worktree Sessions: Edit Config" command creates it) with only
-- the keys you want to replace, then run `tern plugin reload worktree-sessions`.
-- The data directory survives `tern plugin install --force`, so updates keep it.
--
-- Each tab lists its panes in order along `split` ("right" or "down"). `ratio`
-- is the first pane's share; any later panes divide the rest evenly. A pane's
-- `command` runs in an interactive login shell, so shell aliases work; a pane
-- without one is a plain shell. `pin = "right"` keeps a tab at the right edge.
-- The worktree panel is always added on the left of every tab.

local M = {}

M.DEFAULTS = {
	panel_ratio = 0.22,
	tabs = {
		{ name = "editor", split = "down", ratio = 0.65,
			panes = { { command = "nvim" }, { command = "codex" } } },
		{ name = "agents", split = "right", ratio = 0.5, panes = { {}, {} } },
		{ name = "git", pin = "right", panes = { { command = "lazygit" } } },
	},
	setup_hook = ".tern/worktree-sessions/setup",
	shell_hook = ".tern/worktree-sessions/shell",
}

M.path = tern.plugin.data .. "/config.json"

local function fail(message)
	error("worktree-sessions config: " .. message, 0)
end

local function check_command(value, where)
	if value == nil then return nil end
	if type(value) ~= "string" or value == "" or string.find(value, "[\r\n]") then
		fail(where .. ".command must be one nonempty command line")
	end
	return value
end

local function check_ratio(value, where)
	if value == nil then return nil end
	if type(value) ~= "number" or value <= 0.1 or value >= 0.9 then
		fail(where .. " must be between 0.1 and 0.9")
	end
	return value
end

local function check_hook(value, key)
	if type(value) ~= "string" or value == "" or string.find(value, "[\r\n]")
		or string.sub(value, 1, 1) == "/" or string.find("/" .. value .. "/", "/%.%./") then
		fail(key .. " must be a relative path within the repository")
	end
	return value
end

local function check_tabs(tabs)
	if type(tabs) ~= "table" or #tabs == 0 then fail("tabs must be a nonempty list") end
	local out, seen = {}, {}
	for i, tab in tabs do
		local where = "tabs[" .. i .. "]"
		if type(tab) ~= "table" then fail(where .. " must be an object") end
		for key in tab do
			if key ~= "name" and key ~= "split" and key ~= "ratio" and key ~= "panes" and key ~= "pin" then
				fail(where .. ": unknown key " .. tostring(key))
			end
		end
		local name = tab.name
		if type(name) ~= "string" or not string.match(name, "^[%w_-]+$") or #name > 32 then
			fail(where .. ".name must be 1-32 letters, digits, '-' or '_'")
		end
		if seen[name] then fail("tab name " .. name .. " is used twice") end
		seen[name] = true
		where = "tab " .. name
		local split = tab.split or "right"
		if split ~= "right" and split ~= "down" then fail(where .. ": split must be \"right\" or \"down\"") end
		if tab.pin ~= nil and tab.pin ~= "right" then fail(where .. ": pin must be \"right\"") end
		local panes = tab.panes or { {} }
		if type(panes) ~= "table" or #panes == 0 or #panes > 6 then
			fail(where .. ": panes must be a list of 1 to 6 panes")
		end
		local clean = {}
		for p, pane in panes do
			local pwhere = where .. " pane " .. p
			if type(pane) ~= "table" then fail(pwhere .. " must be an object") end
			for key in pane do
				if key ~= "command" then fail(pwhere .. ": unknown key " .. tostring(key)) end
			end
			table.insert(clean, { command = check_command(pane.command, pwhere) })
		end
		table.insert(out, {
			name = name,
			split = split,
			ratio = check_ratio(tab.ratio, where .. " ratio") or 1 / #clean,
			pin = tab.pin,
			panes = clean,
		})
	end
	return out
end

-- Returns validated settings: the defaults with the user's keys replacing them.
-- Raises a readable error for a malformed user file.
function M.build(user)
	if type(user) ~= "table" then fail("config.json must contain a JSON object") end
	for key in user do
		if M.DEFAULTS[key] == nil then fail("unknown key " .. tostring(key)) end
	end
	local function pick(key)
		if user[key] ~= nil then return user[key] end
		return M.DEFAULTS[key]
	end
	return {
		panel_ratio = check_ratio(pick("panel_ratio"), "panel_ratio"),
		tabs = check_tabs(pick("tabs")),
		setup_hook = check_hook(pick("setup_hook"), "setup_hook"),
		shell_hook = check_hook(pick("shell_hook"), "shell_hook"),
	}
end

local function load()
	if not tern.fs.exists(M.path) then return M.build({}), nil end
	local ok, result = pcall(function()
		local text = tern.fs.read(M.path, 1024 * 1024)
		local decoded_ok, decoded = pcall(tern.json.decode, text)
		if not decoded_ok then fail("config.json is not valid JSON") end
		return M.build(decoded)
	end)
	if ok then return result, nil end
	-- Keep the plugin usable; the window reports the problem.
	return M.build({}), tostring(result) .. " (using defaults)"
end

local settings, problem = load()
for key, value in settings do M[key] = value end
M.error = problem

function M.tab(name)
	for _, tab in M.tabs do
		if tab.name == name then return tab end
	end
	return nil
end

-- The user-editable starting file: the defaults written out in full.
M.TEMPLATE = [[
{
  "panel_ratio": 0.22,
  "tabs": [
    { "name": "editor", "split": "down", "ratio": 0.65,
      "panes": [ { "command": "nvim" }, { "command": "codex" } ] },
    { "name": "agents", "split": "right", "ratio": 0.5,
      "panes": [ {}, {} ] },
    { "name": "git", "pin": "right",
      "panes": [ { "command": "lazygit" } ] }
  ],
  "setup_hook": ".tern/worktree-sessions/setup",
  "shell_hook": ".tern/worktree-sessions/shell"
}
]]

return M
