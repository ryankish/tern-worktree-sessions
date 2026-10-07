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
The command tabs start as interactive shells, source an optional worktree shell
hook, then run `nvim`, `codex`, or `lazygit`. This loads shell aliases such as
`codex` from `.zshrc` and leaves a usable shell if a command is missing or
exits. New Agents panes, `Cmd+T` shells, and ordinary shell splits source the
same hook. Restored panes are adopted without sourcing it again.

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

The setup questions and hook are read from the **active checkout** when creation
starts. Edits there can affect the next worktree without changing the primary
checkout. If `<active-checkout>/.tern/worktree-setup` exists, the plugin runs it
on that host after `git worktree add` and before opening the default tabs. The
hook must be executable. It runs in the new worktree with these arguments:
`primary-checkout`, `new-worktree-path`, `branch`. It also receives
`TERN_WORKTREE_REPO_ROOT`, `TERN_WORKTREE_PATH`, `TERN_WORKTREE_BRANCH`,
`TERN_WORKTREE_SETUP_SOURCE`, `TERN_WORKTREE_HOST`, and `TERN_WORKTREE_HOST_KIND`.
`TERN_WORKTREE_SETUP_SOURCE` is the checkout supplying the hook. A failed hook
leaves the worktree in place and offers **Retry setup** or **Open workspace
anyway**.

For setup choices, add `.tern/worktree-setup.json` beside the hook in the
active checkout. The JSON contains only questions and opaque
choice IDs; Tern does not interpret their meanings. For example:

```json
{
  "version": 1,
  "questions": [
    {
      "id": "environment",
      "label": "How should this worktree use its environment?",
      "default": "independent",
      "choices": [
        { "id": "independent", "label": "Independent environment" },
        { "id": "shared", "label": "Share the primary environment" }
      ]
    }
  ]
}
```

Tern asks these questions after the branch name and before `git worktree add`.
Each question and choice may also have a `description`. It passes the answers
to the hook as a JSON object in `TERN_WORKTREE_SETUP_CHOICES_JSON`, and saves
them with the worktree identity after setup succeeds. The hook stays in charge
of all project-specific actions. The policy and hook run on the Tern host; the
new worktree does not need its own copy of either file for creation-time setup.

**Worktree: Run Setup** (or **Run Setup** in the worktree pane) selects an
existing worktree, including the primary checkout, and asks its current setup
questions again. It runs that worktree's own hook in place. This is explicit:
changing setup files does not rerun them automatically, and running setup does
not restart or change the environment of existing panes.

To initialize each *new* interactive shell, a repository may provide
`<worktree>/.tern/worktree-shell`. Tern sources it in that worktree's shell,
including shells that go on to launch `nvim`, `codex`, and `lazygit`. The hook
does not need to be executable; it must use POSIX-compatible shell syntax.
This version supports zsh, bash, sh, ksh, dash, and ash. Other shells keep
their normal command startup and show an unsupported-hook error. Tern exports
`TERN_WORKTREE_PATH` before sourcing it. The pane keeps its initial cwd, so a
shell opened from a nested directory stays there. A hook failure remains
visible in the pane and prevents that pane's default command from starting.

The setup hook owns environment creation; the shell hook owns per-shell
environment changes. Other repositories can export paths or source their own
language tools without Tern interpreting a `.venv` or a package manager.
The shell hook is read from the worktree that owns the new pane. Commit it so
new branches contain it, or have the setup hook create it in the new worktree.
Uncommitted files in the source checkout are not copied by `git worktree add`.

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
`lazygit` command, either content split ratio, or either relative hook path.
Run `tern plugin reload` afterward. These values apply when new default tabs
are created; existing tabs keep their processes and layout. On a remote
host, install the same plugin configuration there for matching defaults.