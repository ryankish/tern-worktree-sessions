-- Edit these values, then reload the plugin. Commands run in login shells so
-- aliases are available. Split ratios apply when a tab is first created.
local config = {
	editor_command = "nvim",
	agent_command = "codex",
	git_command = "lazygit",
	editor_split_ratio = 0.65,
	agents_split_ratio = 0.50,
	setup_hook = ".tern/worktree-setup",
	shell_hook = ".tern/worktree-shell",
}

for _, key in { "editor_command", "agent_command", "git_command" } do
	local value = config[key]
	assert(type(value) == "string" and value ~= "" and not string.find(value, "[\r\n]"),
		"worktree config: " .. key .. " must be one nonempty command line")
end

for _, key in { "editor_split_ratio", "agents_split_ratio" } do
	local value = config[key]
	assert(type(value) == "number" and value > 0.1 and value < 0.9,
		"worktree config: " .. key .. " must be between 0.1 and 0.9")
end

for _, key in { "setup_hook", "shell_hook" } do
	local hook = config[key]
	assert(type(hook) == "string" and hook ~= "" and not string.find(hook, "[\r\n]")
		and string.sub(hook, 1, 1) ~= "/" and not string.find("/" .. hook .. "/", "/%.%./"),
		"worktree config: " .. key .. " must be a relative path within the repository")
end

return config
