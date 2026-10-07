# Worktree Workspace

A Tern plugin for Git worktree navigation and persistent workspace sessions.

In a Git pane, run **Worktree: Discover** from the
command palette. It opens a persistent worktree panel to the left of the
focused pane, on that pane's Tern host and in its current working directory.
Running the command again focuses the existing panel. Press `r` in the panel to
refresh. The block runs `git worktree list --porcelain -z` on its host. A
remote host needs the same plugin installed in its Tern plugin directory. No
repository files are copied locally.

The plugin discovers the Git common directory, paths, HEADs, branches, detached
and bare worktrees, and locked or prunable entries. Click an available worktree
row to switch to its persistent Tern session. The first click creates its
`editor`, `agents`, and `git` tabs with the default commands and split ratios;
later clicks adopt the same session without restarting its programs. The
`Worktree: Switch` command opens the inventory from another tab or session.

Sessions use an exact encoding of the Git common directory and worktree path,
so branch renames do not change their identity. Tern 0.5.3 has no plugin API for
custom sidebar chrome: the worktree UI is an ordinary left pane in every
managed tab, including tabs restored from the previous plugin version. New
sessions place it in a full-height column; existing tabs gain a left split
without restarting their panes. The repo name becomes the window title after
a managed worktree session is selected. The next slice will intercept new shell
tabs and keep `git` rightmost.