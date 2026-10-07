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
An incomplete default tab is retried on a later switch or window open; tabs
that already exist are adopted. A managed window stays bound to its repository.
The command tabs start as interactive shells, then Tern types `nvim`, `codex`,
or `lazygit` into them. This loads shell aliases such as `codex` from `.zshrc`
and leaves a usable shell if a command is missing or exits.

Sessions use an exact encoding of the Git common directory and worktree path,
so branch renames do not change their identity. Tern 0.5.3 has no plugin API for
custom sidebar chrome: the worktree UI is an ordinary left pane in every
managed tab, including tabs restored from the previous plugin version. New
sessions place it in a full-height column; existing tabs are rearranged into
the same layout without restarting their panes. The repo name becomes the
window title after a managed worktree session is selected. In a managed
session, `Cmd+T` opens an ordinary shell in the focused pane's current directory
on the session's Tern host. New shell tabs go immediately before `git`; the
plugin also moves `git` back to the right edge when a managed tab is focused.
If Tern does not know the focused pane's directory, it shows an error instead
of guessing a different directory.

Click **+ New Worktree**, press `n` while the worktree pane is focused, or run
**Worktree: New** from the command palette. Enter a branch name and press Enter.
An existing local branch is checked out; a new branch starts at the current
worktree's HEAD. The path is chosen under a sibling `<repo>-worktrees`
directory, with a numeric suffix when needed. Git runs on the pane's host.

If `<repo-root>/.tern/worktree-setup` exists, the plugin runs it on that host
after `git worktree add` and before opening the default tabs. The hook must be
executable. It runs in the new worktree with these positional arguments:
`repo-root`, `new-worktree-path`, `branch`. It also receives
`TERN_WORKTREE_REPO_ROOT`, `TERN_WORKTREE_PATH`, `TERN_WORKTREE_BRANCH`,
`TERN_WORKTREE_HOST`, and `TERN_WORKTREE_HOST_KIND`. A failed hook leaves the
worktree in place and offers **Retry setup** or **Open workspace anyway**.

To remove a secondary worktree, click **− Remove Worktree**, press `d` in the
worktree pane, or run **Worktree: Remove**. Select its path (keys `1`–`9` also
select the numbered entries), then confirm with the button or Enter.
The plugin rechecks its Git identity before calling `git worktree remove`
without force. Git errors, including dirty or locked worktrees, leave its
Tern session intact. After a successful removal, Tern closes that worktree's
session and its processes. If it was active, the window switches to the main
worktree. The main worktree is not offered for removal. Git branches remain in
place after their worktrees are removed.

Edit `config.luau` to override the `nvim`, `codex`, or
`lazygit` command, either content split ratio, or the relative setup-hook
path. Run `tern plugin reload` afterward. These values apply when new default
tabs are created; existing tabs keep their processes and layout. On a remote
host, install the same plugin configuration there for matching defaults.