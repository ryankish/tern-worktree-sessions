# Changelog

## 0.9.0

### Changed

- Blocks from other plugins stacked above or below the panel stay in its
  column. They aren't counted as the tab's content, and **Open \<name\> Tab**
  puts them back under the panel after restoring a command. Before, the panel
  moved itself out of any column it shared.

## 0.8.0

First public release.

### Changed

- The default session is one plain shell tab. Tabs, panes, commands and the
  panel width come from `config.json` in the plugin's data directory
  (**Worktree Sessions: Edit Config**).
- Repository setup files live in `.tern/worktree-sessions/` (`setup`,
  `setup.json`, `shell`), and hooks see `WORKTREE_SESSION_*` environment
  variables.
- Tabs with `pin = "right"` stay at the right edge. Any one-pane tab with a
  `command` is restarted by **Open \<name\> Tab** when its program has exited.
- Ratios are applied to every tab with more than one pane, not only a tab
  named `editor`.
- A tab's panes are rearranged under the panel only when the tab still has
  the number of panes its config lists, so panes you split by hand are left
  where they are.
- A branch that becomes `.` or `..` as a directory name is rejected when
  creating a worktree.
- A malformed `config.json` shows its error when the panel opens, and the
  defaults are used.
- Tab names that would give two tabs the same **Open \<name\> Tab** command
  (`a-b` and `a_b`, or `Git` and `git`) are rejected.
- New shells clear the line the plugin types to run the shell hook once the
  hook succeeds. A failing hook leaves its error on screen.

### Upgrading from the pre-release `worktree` plugin

The plugin id, session names, link scheme, commands, hook paths and
environment variables were all renamed, so nothing from `worktree` carries
over:

| Before | Now |
| --- | --- |
| plugin id `worktree`, commands `plugin.worktree.*` | `worktree-sessions`, `plugin.worktree-sessions.*` |
| `Worktree: Open Editor/Agents/Git Tab` | `Worktree Sessions: Open <name> Tab` for each configured tab |
| `.tern/worktree-setup`, `.tern/worktree-setup.json`, `.tern/worktree-shell` | `.tern/worktree-sessions/setup`, `setup.json`, `shell` |
| `TERN_WORKTREE_*` | `WORKTREE_SESSION_*` |
| `editor_command`, `agent_command`, `git_command` and the split ratios in `config.luau` | `tabs` in `config.json` |

Remove the old plugin with `tern plugin remove worktree`, and close its
`tern-wt:` sessions.
