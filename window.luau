tern.command({
	id = "discover",
	title = "Worktree: Discover",
	icon = "git-branch",
	run = function(cx)
		local pane = cx.session:focused()
		local info = pane and cx.session:pane(pane)
		local host = cx.hosts:current()
		if not info or not info.cwd or info.cwd == "" then
			cx:toast("error", "Cannot discover worktrees", "Focused pane has no known working directory")
			return
		end
		local opened = cx:new_block("worktree.inventory", { info.cwd, host.name }, "tab")
		if not opened then
			cx:toast("error", "Cannot open worktree inventory", "Install the plugin on " .. host.name)
		end
	end,
})
