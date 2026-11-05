-- Tests for the parts of the plugin that don't need a running Tern.
-- Run from the plugin directory with Lune (https://lune-org.github.io/docs):
--
--   lune run tests/run
--
-- Modules are loaded with a stand-in `tern` global that covers what they
-- use: JSON, files and the plugin data directory.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

local ROOT = process.cwd
if not fs.isFile(ROOT .. "/plugin.toml") then
	ROOT = ROOT .. "/.."
end
assert(fs.isFile(ROOT .. "/plugin.toml"), "run from the plugin directory: lune run tests/run")

local TMP = ROOT .. "/tests/.tmp"

local function fake_tern(data_dir)
	return {
		json = {
			decode = function(text) return serde.decode("json", text) end,
			encode = function(value) return serde.encode("json", value) end,
		},
		fs = {
			exists = function(path) return fs.isFile(path) or fs.isDir(path) end,
			read = function(path) return fs.readFile(path) end,
			write = function(path, text) fs.writeFile(path, text) end,
			mkdir = function(path) fs.writeDir(path) end,
		},
		plugin = { id = "worktree-sessions", dir = ROOT, data = data_dir or TMP },
	}
end

local function load_module(name, tern)
	local source = fs.readFile(ROOT .. "/" .. name .. ".luau")
	return luau.load(source, { debugName = name, environment = { tern = tern or fake_tern() } })()
end

-- Harness

local passed, failed = 0, {}
local current = ""

local function test(name, fn)
	current = name
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		table.insert(failed, name .. "\n    " .. tostring(err))
	end
end

local function show(value)
	if type(value) == "string" then return string.format("%q", value) end
	return tostring(value)
end

local function eq(actual, expected, what)
	if actual ~= expected then
		error((what or "value") .. ": expected " .. show(expected) .. ", got " .. show(actual), 2)
	end
end

local function deep_eq(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then return a == b end
	for k, v in a do
		if not deep_eq(v, b[k]) then return false end
	end
	for k in b do
		if a[k] == nil then return false end
	end
	return true
end

local function fails_with(fn, needle)
	local ok, err = pcall(fn)
	if ok then error("expected an error containing " .. show(needle), 2) end
	if not string.find(tostring(err), needle, 1, true) then
		error("expected an error containing " .. show(needle) .. ", got " .. show(tostring(err)), 2)
	end
end

-- parse.luau: `git worktree list --porcelain -z`

local parse = load_module("parse")

local function porcelain(records)
	local out = {}
	for _, record in records do
		for _, field in record do
			table.insert(out, field .. "\0")
		end
		table.insert(out, "\0")
	end
	return table.concat(out)
end

test("porcelain: primary and linked worktrees", function()
	local entries = assert(parse.parse_porcelain(porcelain({
		{ "worktree /src/app", "HEAD " .. string.rep("a", 40), "branch refs/heads/main" },
		{ "worktree /src/app-worktrees/feat", "HEAD " .. string.rep("b", 40), "branch refs/heads/feat" },
	})))
	eq(#entries, 2, "entries")
	eq(entries[1].path, "/src/app", "path")
	eq(entries[1].branch, "refs/heads/main", "branch")
	eq(entries[2].head, string.rep("b", 40), "head")
end)

test("porcelain: detached, bare, locked and prunable", function()
	local entries = assert(parse.parse_porcelain(porcelain({
		{ "worktree /src/bare", "HEAD " .. string.rep("0", 40), "bare" },
		{ "worktree /src/a", "HEAD " .. string.rep("1", 40), "detached", "locked" },
		{ "worktree /src/b", "HEAD " .. string.rep("2", 40), "branch refs/heads/b",
			"locked on a USB drive", "prunable gitdir file points to non-existent location" },
	})))
	eq(entries[1].bare, true, "bare")
	eq(entries[2].detached, true, "detached")
	eq(entries[2].locked, true, "locked without reason")
	eq(entries[3].locked, "on a USB drive", "locked reason")
	eq(entries[3].prunable, "gitdir file points to non-existent location", "prunable reason")
end)

test("porcelain: paths with spaces, quotes and newlines are kept exactly", function()
	local odd = "/src/my repo/it's\nhere"
	local entries = assert(parse.parse_porcelain(porcelain({
		{ "worktree " .. odd, "HEAD " .. string.rep("c", 40), "branch refs/heads/x" },
	})))
	eq(entries[1].path, odd, "path")
end)

test("porcelain: empty output is an empty list", function()
	eq(#assert(parse.parse_porcelain("")), 0, "entries")
end)

test("porcelain: malformed output is rejected", function()
	local head = "HEAD " .. string.rep("d", 40)
	local cases = {
		{ "worktree /a\0" .. head, "incomplete" },
		{ head .. "\0\0", "field before worktree" },
		{ "worktree /a\0\0", "missing worktree path or HEAD" },
		{ "worktree /a\0" .. head .. "\0", "unterminated" },
		{ "worktree /a\0worktree /b\0" .. head .. "\0\0", "missing worktree separator" },
	}
	for _, case in cases do
		local entries, err = parse.parse_porcelain(case[1])
		eq(entries, nil, "entries for " .. case[2])
		assert(err and string.find(err, case[2], 1, true), "expected " .. case[2] .. ", got " .. tostring(err))
	end
end)

-- setup_policy.luau: .tern/worktree-sessions/setup.json

local policy = load_module("setup_policy")

local function question(fields)
	local q = { id = "environment", label = "Environment?",
		choices = { { id = "independent", label = "Independent" }, { id = "shared", label = "Shared" } } }
	for k, v in fields or {} do q[k] = v end
	return q
end

local function policy_json(questions, version)
	return serde.encode("json", { version = version or 1, questions = questions })
end

test("setup.json: default is the first choice unless given", function()
	local questions = assert(policy.parse(policy_json({
		question(),
		question({ id = "data", default = "shared", description = "Where data lives" }),
	})))
	eq(#questions, 2, "questions")
	eq(questions[1].default, "independent", "implicit default")
	eq(questions[2].default, "shared", "explicit default")
	eq(questions[2].description, "Where data lives", "description")
	eq(questions[1].choices[2].id, "shared", "choice order")
end)

test("setup.json: invalid policies are rejected with a reason", function()
	local cases = {
		{ "{ not json", "Invalid setup JSON" },
		{ policy_json({ question() }, 2), "version 1" },
		{ policy_json({}), "at least one question" },
		{ policy_json({ question({ id = "has space" }) }), "Invalid setup question 1" },
		{ policy_json({ question({ id = "9lives" }) }), "Invalid setup question 1" },
		{ policy_json({ question(), question() }), "Invalid setup question 2" },
		{ policy_json({ question({ label = "" }) }), "Invalid setup question 1" },
		{ policy_json({ question({ choices = {} }) }), "Invalid setup question 1" },
		{ policy_json({ question({ choices = { { id = "a", label = "A" }, { id = "a", label = "B" } } }) }),
			"Invalid choice in setup question environment" },
		{ policy_json({ question({ choices = { { id = "a", label = "A", description = 5 } } }) }),
			"Invalid choice in setup question environment" },
		{ policy_json({ question({ default = "missing" }) }), "Unknown default" },
		{ policy_json({ question({ description = true }) }), "Invalid description" },
	}
	for _, case in cases do
		local questions, err = policy.parse(case[1])
		eq(questions, nil, "result for " .. case[2])
		assert(err and string.find(err, case[2], 1, true), "expected " .. case[2] .. ", got " .. tostring(err))
	end
end)

-- config.luau: config.json in the plugin data directory

local function with_config(text)
	if fs.isDir(TMP) then fs.removeDir(TMP) end
	fs.writeDir(TMP)
	if text then fs.writeFile(TMP .. "/config.json", text) end
	return load_module("config", fake_tern(TMP))
end

local config = with_config(nil)

test("config: no file gives the defaults", function()
	eq(config.error, nil, "error")
	eq(#config.tabs, 3, "tabs")
	eq(config.tabs[1].name, "editor", "first tab")
	eq(config.tabs[1].split, "down", "editor split")
	eq(config.tabs[1].ratio, 0.65, "editor ratio")
	eq(config.tabs[1].panes[2].command, "codex", "agent command")
	eq(config.tabs[2].panes[1].command, nil, "agents pane is a plain shell")
	eq(config.tabs[3].pin, "right", "git pinned")
	eq(config.panel_ratio, 0.22, "panel ratio")
	eq(config.setup_hook, ".tern/worktree-sessions/setup", "setup hook")
	eq(config.tab("git").panes[1].command, "lazygit", "tab lookup")
	eq(config.tab("missing"), nil, "unknown tab")
end)

test("config: the Edit Config template equals the defaults", function()
	assert(deep_eq(config.build(serde.decode("json", config.TEMPLATE)), config.build({})),
		"TEMPLATE and DEFAULTS differ")
end)

test("config: user keys replace defaults, others are kept", function()
	local built = config.build({ tabs = { { name = "code", panes = { { command = "nvim" }, {}, {} } } } })
	eq(#built.tabs, 1, "tabs replaced")
	eq(built.tabs[1].split, "right", "default split")
	eq(built.tabs[1].ratio, 1 / 3, "default ratio is an even share")
	eq(built.shell_hook, ".tern/worktree-sessions/shell", "hook kept")
	eq(built.panel_ratio, 0.22, "panel ratio kept")
	eq(#config.build({ tabs = { { name = "shell" } } }).tabs[1].panes, 1, "panes default to one shell")
end)

test("config: invalid settings are rejected with a reason", function()
	local function tabs(tab) return { tabs = { tab } } end
	local cases = {
		{ { tabz = {} }, "unknown key tabz" },
		{ { tabs = {} }, "tabs must be a nonempty list" },
		{ tabs({ name = "has space" }), "name must be" },
		{ { tabs = { { name = "a" }, { name = "a" } } }, "used twice" },
		{ tabs({ name = "a", split = "left" }), "split must be" },
		{ tabs({ name = "a", pin = "left" }), "pin must be" },
		{ tabs({ name = "a", panes = {} }), "1 to 6 panes" },
		{ tabs({ name = "a", panes = { {}, {}, {}, {}, {}, {}, {} } }), "1 to 6 panes" },
		{ tabs({ name = "a", panes = { { cmd = "nvim" } } }), "unknown key cmd" },
		{ tabs({ name = "a", panes = { { command = "nvim\nrm -rf /" } } }), "one nonempty command line" },
		{ tabs({ name = "a", panes = { { command = "" } } }), "one nonempty command line" },
		{ tabs({ name = "a", ratio = 0.95 }), "between 0.1 and 0.9" },
		{ tabs({ name = "a", colour = "red" }), "unknown key colour" },
		{ { panel_ratio = 0 }, "between 0.1 and 0.9" },
		{ { setup_hook = "/etc/setup" }, "relative path" },
		{ { shell_hook = "../outside/shell" }, "relative path" },
		{ { shell_hook = "a/../../b" }, "relative path" },
	}
	for _, case in cases do
		fails_with(function() config.build(case[1]) end, case[2])
	end
end)

test("config: a broken file falls back to the defaults with an error", function()
	local broken = with_config("{ \"tabs\": [")
	assert(broken.error and string.find(broken.error, "not valid JSON", 1, true), tostring(broken.error))
	eq(#broken.tabs, 3, "default tabs")

	local wrong = with_config("{ \"tabs\": [ { \"name\": \"a\", \"split\": \"left\" } ] }")
	assert(wrong.error and string.find(wrong.error, "split must be", 1, true), tostring(wrong.error))
	assert(string.find(wrong.error, "using defaults", 1, true), "error says defaults are used")
end)

test("config: a valid file is applied", function()
	local custom = with_config("{ \"panel_ratio\": 0.3, \"tabs\": [ { \"name\": \"code\" } ] }")
	eq(custom.error, nil, "error")
	eq(custom.panel_ratio, 0.3, "panel ratio")
	eq(custom.tabs[1].name, "code", "tab")
end)

-- paths.luau: session names, paths and shell text

local paths = load_module("paths")

local function sh(script, cwd)
	local result = process.exec("sh", { "-c", script }, { cwd = cwd })
	return result.stdout, result.ok
end

local ODD = {
	"/src/app", "/src/my repo", "/src/it's", "/src/a:b", "/src/$(touch pwned)",
	"/src/`id`", "/src/tab\there", "/src/new\nline", "/src/ünïcødé", "/src/\"dq\"",
}

test("paths: hex round-trips any bytes; unhex rejects non-hex", function()
	for _, value in ODD do eq(paths.unhex(paths.hex(value)), value, "round trip") end
	eq(paths.unhex(paths.hex("\0\255")), "\0\255", "binary")
	for _, bad in { "", "a", "0G", "AB", "zz" } do eq(paths.unhex(bad), nil, "unhex " .. bad) end
end)

test("paths: session names round-trip and reject other names", function()
	for _, path in ODD do
		local identity = paths.session_identity(paths.session_name(path .. "/.git", path))
		assert(identity, "no identity for " .. path)
		eq(identity.common_dir, path .. "/.git", "common dir")
		eq(identity.path, path, "path")
	end
	local good = paths.session_name("/r/.git", "/r")
	for _, name in {
		"Default",
		"tern-wt:" .. paths.hex("/r/.git") .. ":" .. paths.hex("/r"),
		"worktree_sessions:" .. paths.hex("/r/.git") .. ":" .. paths.hex("/r"),
		good .. "0",
		good .. ":ab",
		"x" .. good,
	} do
		eq(paths.session_identity(name), nil, "identity of " .. name)
	end
end)

test("paths: repository name from a session", function()
	eq(paths.repo_from_session(paths.session_name("/src/app/.git", "/src/app-worktrees/x")), "app", "repo")
	eq(paths.repo_from_session(paths.session_name("/srv/app.git", "/srv/app")), "app.git", "bare repo")
	eq(paths.repo_from_session("Default"), nil, "unmanaged session")
end)

test("paths: within", function()
	assert(paths.within("/a/b", "/a"), "child")
	assert(paths.within("/a", "/a"), "same")
	assert(paths.within("/anything", "/"), "root")
	assert(not paths.within("/ab", "/a"), "sibling with shared prefix")
	assert(not paths.within("/a", "/a/b"), "parent")
end)

test("paths: shell_quote survives a real shell", function()
	for _, value in ODD do
		local out = sh("printf %s " .. paths.shell_quote(value))
		eq(out, value, "quoted " .. value)
	end
end)

test("paths: shell_startup sources the hook, then runs the command", function()
	local dir = TMP .. "/it's a $(dir)"
	fs.writeDir(dir .. "/.tern/worktree-sessions")
	local hook = ".tern/worktree-sessions/shell"
	local function run(command)
		local line = paths.shell_startup(dir, hook, command)
		eq(string.sub(line, -1), "\r", "ends with Enter")
		return sh(string.sub(line, 1, -2), dir)
	end

	eq(run("echo ran"), "ran\n", "no hook: command still runs")
	eq(run(nil), "", "no hook, no command")

	fs.writeFile(dir .. "/" .. hook, "export FROM_HOOK=yes\n")
	eq(run("echo \"$FROM_HOOK|$WORKTREE_SESSION_PATH\""), "yes|" .. dir .. "\n", "hook and path")

	fs.writeFile(dir .. "/" .. hook, "echo hook failed; return 1\n")
	local out = run("echo should-not-run")
	eq(out, "hook failed\n", "failing hook stops the command")
	fs.removeDir(TMP)
end)

test("paths: worktree_base puts worktrees beside the repository", function()
	eq(paths.worktree_base("/src/app", "feat/login"), "/src/app-worktrees/feat-login", "slashes")
	eq(paths.worktree_base("/src/app.git", "fix"), "/src/app-worktrees/fix", "bare repo")
	eq(paths.worktree_base("/src/app", "a  b//c"), "/src/app-worktrees/a-b-c", "runs collapse")
	eq(paths.worktree_base("/src/app", "v1.2_rc"), "/src/app-worktrees/v1.2_rc", "kept characters")
	for _, branch in { "", ".", ".." } do
		local base, err = paths.worktree_base("/src/app", branch)
		eq(base, nil, "base for " .. show(branch))
		assert(err, "reason for " .. show(branch))
	end
	eq(paths.worktree_base("app", "x"), nil, "no parent directory")
end)

test("paths: free_path adds the first unused suffix", function()
	local taken = { ["/w/x"] = true, ["/w/x-2"] = true }
	eq(paths.free_path("/w/x", function(p) return taken[p] == true end), "/w/x-3", "suffix")
	eq(paths.free_path("/w/y", function() return false end), "/w/y", "free")
	local path, err = paths.free_path("/w/z", function() return true end)
	eq(path, nil, "gives up")
	assert(err, "reason")
end)

-- Documentation: every example config and question file must be valid.

test("docs: README and example JSON pass the real validators", function()
	local readme = fs.readFile(ROOT .. "/README.md")
	local configs, policies = 0, 0
	for block in string.gmatch(readme, "```json\n(.-)```") do
		local ok, value = pcall(serde.decode, "json", block)
		if ok and type(value) == "table" and value.tabs then
			config.build(value)
			configs += 1
		elseif ok and type(value) == "table" and value.questions then
			assert(policy.parse(block))
			policies += 1
		end
	end
	assert(configs >= 3, "expected at least 3 config examples in README, found " .. configs)
	assert(policies >= 1, "expected a setup.json example in README")
	assert(policy.parse(fs.readFile(ROOT .. "/examples/uv-venv/setup.json")))
end)

if fs.isDir(TMP) then fs.removeDir(TMP) end

for _, failure in failed do
	print("FAIL " .. failure)
end
print(string.format("%d passed, %d failed", passed, #failed))
process.exit(#failed == 0 and 0 or 1)
