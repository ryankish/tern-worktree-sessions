# Worktree Workspace

A Tern plugin for Git worktree navigation and persistent workspace sessions.

In a Git pane, run **Worktree: Discover** from the
command palette. It opens a persistent worktree panel to the left of the
focused pane, on that pane's Tern host and in its current working directory.
Running the command again focuses the existing panel. Press `r` in the panel to
refresh. The block runs `git worktree list --porcelain -z` on its host. A
remote host needs the same plugin installed in its Tern plugin directory. No
repository files are copied locally.

This slice discovers the Git common directory, paths, HEADs, branches, detached
and bare worktrees, and locked or prunable entries. Tern 0.5.3 has no plugin
API for custom sidebar chrome, so this is an ordinary left pane: it appears
only in the tab where opened. It does not yet create or switch tab groups.
The pane uses Tern's native surface components for the project heading,
worktree rows, active marker, and clickable Refresh control.
The next slice will attach stable repo and worktree identities to Tern
sessions, then initialize the three-tab layout.