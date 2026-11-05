-- Pure helpers for names, paths and shell text. No Tern calls, so they are
-- tested directly in tests/run.luau.

local M = {}

M.SESSION_PREFIX = "worktree-sessions:"
local PREFIX_PATTERN = "^" .. string.gsub(M.SESSION_PREFIX, "%p", "%%%0")

function M.hex(bytes)
	return (string.gsub(bytes, ".", function(byte)
		return string.format("%02x", string.byte(byte))
	end))
end

-- nil for anything that isn't nonempty lowercase hex of whole bytes.
function M.unhex(value)
	if #value == 0 or #value % 2 ~= 0 or not string.match(value, "^[0-9a-f]+$") then
		return nil
	end
	return (string.gsub(value, "..", function(byte)
		return string.char(tonumber(byte, 16))
	end))
end

-- Exact paths keep identity independent of the branch and avoid hash collisions.
function M.session_name(common_dir, path)
	return M.SESSION_PREFIX .. M.hex(common_dir) .. ":" .. M.hex(path)
end

function M.session_identity(name)
	local encoded_common, encoded_path = string.match(name,
		PREFIX_PATTERN .. "([0-9a-f]+):([0-9a-f]+)$")
	if not encoded_common then return nil end
	local common_dir, path = M.unhex(encoded_common), M.unhex(encoded_path)
	if not common_dir or not path then return nil end
	return { common_dir = common_dir, path = path }
end

-- The repository's directory name, from a worktree session name.
function M.repo_from_session(name)
	local identity = M.session_identity(name)
	if not identity then return nil end
	local root = string.gsub(identity.common_dir, "/%.git$", "")
	return string.match(root, "([^/]+)$") or root
end

-- Whether `path` is `root` or inside it.
function M.within(path, root)
	return path == root or root == "/" or string.sub(path, 1, #root + 1) == root .. "/"
end

-- One POSIX shell word, whatever the value contains.
function M.shell_quote(value)
	return "'" .. string.gsub(value, "'", "'\"'\"'") .. "'"
end

-- The line typed into a new worktree shell: export the root, source the shell
-- hook if the worktree has one, clear the screen so this line doesn't linger,
-- then run `command`. Everything after the hook runs only if it succeeded, so
-- a failing hook keeps its error on screen and the command doesn't start.
function M.shell_startup(path, shell_hook, command)
	local root = M.shell_quote(path)
	local hook = M.shell_quote(path .. "/" .. shell_hook)
	local init = "export WORKTREE_SESSION_PATH=" .. root
		.. "; if [ -f " .. hook .. " ]; then . " .. hook .. "; fi"
		.. " && printf '\\033[H\\033[2J\\033[3J'"
	return init .. (command and " && " .. command or "") .. "\r"
end

-- Where a branch's worktree goes: <parent>/<repo>-worktrees/<slug>, beside
-- the main checkout `main`. Returns nil and a reason when there is no usable path.
function M.worktree_base(main, branch)
	local parent, name = string.match(main, "^(.*)/([^/]+)$")
	if not parent or not name then return nil, "Cannot determine the repository parent directory" end
	name = string.gsub(name, "%.git$", "")
	local slug = string.gsub(branch, "[^%w._-]", "-")
	slug = string.gsub(slug, "%-+", "-")
	if slug == "" or slug == "." or slug == ".." then
		return nil, "Branch name has no usable path characters"
	end
	return parent .. "/" .. name .. "-worktrees/" .. slug
end

-- `base`, or `base-2`, `base-3`, ... : the first one `exists` says is free.
function M.free_path(base, exists)
	local path = base
	local suffix = 2
	while exists(path) do
		path = base .. "-" .. tostring(suffix)
		suffix += 1
		if suffix > 1000 then return nil, "Could not choose an unused worktree path" end
	end
	return path
end

return M
