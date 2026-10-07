tern.command({
	id = "discover",
	title = "Worktree: Discover",
	icon = "git-branch",
	run = function(cx)
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
	end,
})
