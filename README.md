# Worktree Workspace

A Tern plugin for Git worktree navigation and persistent workspace sessions.

In a Git pane, run **Worktree: Discover** from the
command palette. It opens a persistent inventory block on that pane's Tern host,
using its current working directory. Press `r` in the block to refresh. The block
runs `git worktree list --porcelain -z` on its host, so a remote host needs the
same plugin installed in its Tern plugin directory. No repository files are
copied locally.

This slice discovers the Git common directory, paths, HEADs, branches, detached
and bare worktrees, and locked or prunable entries. It does not yet create or
switch tab groups. The next slice will attach stable repo and worktree identities
to Tern sessions, then initialize the three-tab layout.