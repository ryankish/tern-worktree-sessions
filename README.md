# Worktree Sessions

A [Tern](https://stencil.so/tern) plugin that gives every Git
worktree its own persistent session: your editor, agents and Git UI, already
open in that worktree, a click away. New worktrees can run the repository's own
setup, with questions asked in Tern, before anything opens.

<!-- TODO: screenshot or GIF of the panel and a switch between worktrees -->

- **One session per worktree.** Switching hides the other worktrees' tabs
  without stopping their programs. Your nvim buffers and agent runs are where
  you left them.
- **Your layout, not ours.** Tabs, panes and commands come from a small JSON
  file that survives plugin updates. The defaults are nvim + Codex, two spare
  shells, and lazygit.
- **Create and remove worktrees in place.** Type a branch name and get a ready
  session; removal refuses dirty worktrees.
- **Optional per-repo setup.** A repository can ask questions ("share the venv
  or build a new one?"), run a setup script, and prepare every new shell.
- **Pull request status** for each branch, with one click to push and open a
  PR on GitHub.
- **Remote hosts.** Works on worktrees on any machine Tern connects to.

## Install

```sh
tern plugin install github.com/ryankish/tern-worktree-sessions
```

`tern plugin list` should show `worktree-sessions ... ready`. For worktrees on
a remote host, install the plugin on that host too.

To open the panel with a key, add a binding to Tern's `settings.json`:

```json
"keybinds": {
  "cmd+shift+w": "plugin.worktree-sessions.switch"
}
```

## Quick start

No configuration is needed.

1. In any pane inside a Git repository, run **Worktree Sessions: Discover**
   from the command palette. A worktree panel opens on the left.
2. Click a worktree. Its session opens with three tabs:
   - `editor`: nvim above `codex`
   - `agents`: two shells
   - `git`: lazygit, always the rightmost tab
3. Press **+ New Worktree** (or `n` in the panel), type a branch name, and
   press Enter. An existing branch is checked out; a new branch starts at the
   current worktree's HEAD. Worktrees go in a sibling `<repo>-worktrees/`
   directory.

`Cmd+T` in a worktree session opens a shell tab in that worktree, placed before
`git`. Every tab gets the panel on its left.

## Configure your layout

Run **Worktree Sessions: Edit Config**. It creates `config.json` in the
plugin's data directory, filled in with the defaults, and opens it. Save, then
run:

```sh
tern plugin reload worktree-sessions
```

The file lives outside the plugin directory, so `tern plugin install --force`
updates the plugin without touching it. Keys you leave out keep their
defaults. New tabs use the new layout. Tabs that already exist keep theirs.

The defaults:

```json
{
  "panel_ratio": 0.22,
  "tabs": [
    { "name": "editor", "split": "down", "ratio": 0.65,
      "panes": [ { "command": "nvim" }, { "command": "codex" } ] },
    { "name": "agents", "split": "right", "ratio": 0.5,
      "panes": [ {}, {} ] },
    { "name": "git", "pin": "right",
      "panes": [ { "command": "lazygit" } ] }
  ],
  "setup_hook": ".tern/worktree-sessions/setup",
  "shell_hook": ".tern/worktree-sessions/shell"
}
```

| Key | Meaning |
| --- | --- |
| `panel_ratio` | Width of the worktree panel, as a share of the tab (0.1 to 0.9). |
| `tabs` | The tabs each new worktree session gets, in order. |
| `tabs[].name` | Tab name: letters, digits, `-` or `_`. Each gets an **Open \<name\> Tab** command. |
| `tabs[].split` | `"right"` (side by side) or `"down"` (stacked). Default `"right"`. |
| `tabs[].ratio` | The first pane's share. Later panes split the rest evenly. Default: all panes equal. |
| `tabs[].pin` | `"right"` keeps the tab at the right edge, even after `Cmd+T`. |
| `tabs[].panes` | 1 to 6 panes. A pane's `command` runs in an interactive login shell. A pane without one is a plain shell. |
| `setup_hook`, `shell_hook` | Where repositories keep their [setup files](#repository-setup), relative to the repository root. |

Commands run in a login shell, so shell aliases and functions work. If a
command exits or is missing, you are left at a shell prompt in that pane. A
malformed file doesn't break the plugin: it uses the defaults and shows the
error when you open the panel.

### Example: the author's config

The defaults with one change: the agent pane under nvim runs `codex`. Only
`tabs` is set, so the panel width and hook paths keep their defaults.

```json
{
  "tabs": [
    { "name": "editor", "split": "down", "ratio": 0.65,
      "panes": [ { "command": "nvim" }, { "command": "codex" } ] },
    { "name": "agents", "split": "right", "ratio": 0.5,
      "panes": [ {}, {} ] },
    { "name": "git", "pin": "right",
      "panes": [ { "command": "lazygit" } ] }
  ]
}
```

Another shape, for Claude Code users who prefer a wide editor:

```json
{
  "tabs": [
    { "name": "code", "split": "right", "ratio": 0.6,
      "panes": [ { "command": "nvim" }, { "command": "claude" } ] },
    { "name": "shell" },
    { "name": "git", "pin": "right", "panes": [ { "command": "lazygit" } ] }
  ]
}
```

## Repository setup

`git worktree add` gives you the tracked files and nothing else. A new
worktree has no `.env`, no virtual environment, no build cache, and no links to
data that lives outside the repo. Repository setup fixes that each time you
make a worktree, the same way, without you remembering the steps.

All of it is optional, and Tern doesn't interpret any of it. A repository can
provide up to three files under `.tern/worktree-sessions/`:

| File | When it runs | What it's for |
| --- | --- | --- |
| `setup.json` | Before `git worktree add` | Questions to ask in Tern. Answers are passed to `setup`. |
| `setup` | Once, after `git worktree add` and before the tabs open | Preparing the worktree: environments, copied files, links. |
| `shell` | In every new shell in the worktree | Fast per-shell changes, such as activating that worktree's venv. |

Setup happens once per worktree, and the shell hook runs in every shell. Put
slow or one-time work in `setup`, and keep `shell` quick and quiet.

### Use cases

These come from real repositories the plugin was built for.

- **Share a Python environment or build a new one.** A uv project can ask, per
  worktree, whether to run `uv sync` for an independent `.venv` or symlink the
  primary checkout's `.venv`. Sharing is instant but couples the two worktrees.
  An independent venv is safe for a branch that changes dependencies. The shell
  hook then activates whichever `.venv` the worktree has. This is the
  [uv example](examples/uv-venv) below.
- **Bootstrap something expensive once.** Machine-learning stacks (PyTorch and
  friends) can take many minutes to install. Setup can build the environment
  once in the primary checkout and have later worktrees reuse it, along with
  caches such as `.cache/`.
- **Copy untracked files.** `.env`, local credentials and editor settings
  aren't in Git, so a new worktree doesn't get them. Setup can copy them from
  the primary checkout.
- **Link large data instead of copying it.** Datasets and model weights stay
  where they are. Setup links them into the worktree.
- **Keep each branch's outputs apart.** Experiments on two branches shouldn't
  write into the same results directory. The shell hook can export a
  per-worktree output path, so each branch's runs land in their own place.
- **Rules that change as the project does.** Setup files are read from the
  checkout you are working in when you create the worktree, even if you haven't
  committed your edits. Change the setup on your current branch, and the next
  worktree you make uses it.

A minimal setup hook covering the copy and link cases:

```sh
#!/bin/sh
# .tern/worktree-sessions/setup — runs in the new worktree
set -eu
primary=$1
[ -f "$primary/.env" ] && cp "$primary/.env" .env
ln -s /data/shared-datasets data
```

And a shell hook that keeps each branch's results apart:

```sh
# .tern/worktree-sessions/shell
export RESULTS_DIR="$HOME/results/$(basename "$WORKTREE_SESSION_PATH")"
mkdir -p "$RESULTS_DIR"
```

### Example: uv, with a shared or independent venv

[`examples/uv-venv`](examples/uv-venv) has all three files. Copy them into
your repository and commit them:

```sh
mkdir -p .tern/worktree-sessions
cp path/to/tern-worktree-sessions/examples/uv-venv/* .tern/worktree-sessions/
```

**+ New Worktree** now asks how to set up the environment, runs `uv sync` or
links the venv, and opens the tabs with the venv active in every shell.

### `setup.json`: questions

```json
{
  "version": 1,
  "questions": [
    {
      "id": "environment",
      "label": "How should this worktree use the uv environment?",
      "default": "independent",
      "choices": [
        { "id": "independent", "label": "Independent venv",
          "description": "Run uv sync and create this worktree's own .venv." },
        { "id": "shared", "label": "Share the primary checkout's venv" }
      ]
    }
  ]
}
```

Tern asks the questions after the branch name, before it creates anything.
Questions and choices may have a `description`. IDs are yours: Tern only
passes the chosen IDs to `setup` as a JSON object, such as
`{"environment":"shared"}`, and remembers them for that worktree.

### `setup`: the setup hook

It must be executable and can be written in any language. It runs in the new
worktree on the worktree's host. It has up to 15 minutes.

Arguments: `primary-checkout new-worktree-path branch`.

Environment:

| Variable | Value |
| --- | --- |
| `WORKTREE_SESSION_REPO_ROOT` | The primary checkout |
| `WORKTREE_SESSION_PATH` | The new worktree |
| `WORKTREE_SESSION_BRANCH` | Its branch |
| `WORKTREE_SESSION_SETUP_SOURCE` | The checkout the setup files were read from |
| `WORKTREE_SESSION_SETUP_CHOICES_JSON` | Answers to `setup.json`, or `{}` |
| `WORKTREE_SESSION_HOST`, `WORKTREE_SESSION_HOST_KIND` | The Tern host it runs on |

Exit 0 to open the session. On failure, Tern shows the output and offers
**Retry setup** or **Open workspace anyway**. The worktree is kept either way.

Hooks inherit the Tern daemon's `PATH`, which can be shorter than your login
shell's. If a tool isn't found, look it up through `$SHELL -lic`; the uv
example shows how.

**Run Setup** (in the panel or the palette) reruns an existing worktree's own
setup in place, asking the questions again. Setup never reruns on its own, and
it doesn't change shells that are already open.

### `shell`: the shell hook

Sourced, not executed, in every new shell in the worktree, before the pane's
command. That includes the configured panes, `Cmd+T` tabs and ordinary
splits. `WORKTREE_SESSION_PATH` is set to the worktree root. It must use POSIX
shell syntax (zsh, bash, sh, ksh, dash and ash work). If it fails, the error
stays visible and that pane's command doesn't start.

It is read from each worktree, not from the checkout you created it from. Commit
it so new branches have it, or have `setup` write it. Shells already open keep
the environment they started with.

### Working with a team

Nothing here affects people who don't use the plugin. A plain `git worktree
add` runs no hooks, and a repository without these files works fine in Tern.

If the setup is only for you, keep the files out of Git. List `.tern/` in
`.git/info/exclude`, which is never committed. The setup files are read from
your current checkout, so untracked ones still work. The shell hook needs to
exist in each new worktree, so have `setup` copy it:

```sh
mkdir -p .tern/worktree-sessions
cp "$WORKTREE_SESSION_SETUP_SOURCE/.tern/worktree-sessions/shell" .tern/worktree-sessions/
```

## The panel

| Action | Button | Key |
| --- | --- | --- |
| Switch to a worktree | click its row | |
| New worktree | **+ New Worktree** | `n` |
| Remove a worktree | **− Remove Worktree** | `d`, then `1`–`9` to pick |
| Rerun setup | **Run Setup** | |
| Refresh | **↻ Refresh** | `r` |
| Push and open a PR, or open the existing one | the PR button on a row | |

Removal runs `git worktree remove` without force, so a dirty or locked worktree
stays put and Git's error is shown. After a removal, its session and programs
are closed. The branch is kept. The primary worktree can't be removed here.

PR status uses the `gh` CLI, if it's installed and signed in.

Palette commands: **Discover**, **Switch**, **New Worktree**, **Remove
Worktree**, **Run Setup**, **Refresh**, **Edit Config**, and **Open \<name\>
Tab** for each configured tab, all prefixed with **Worktree Sessions:**.

## Details

- A Tern window belongs to one repository once you pick a worktree in it, and
  its title becomes the repository name.
- Sessions are named from the Git common directory and the worktree path, so
  renaming a branch keeps its session.
- If a configured tab is closed, **Open \<name\> Tab** recreates it. Opening a
  one-pane tab whose program exited, such as `git`, starts the command again.
- **Remote hosts:** the panel runs Git on the host of the pane you opened it
  from. The plugin must be installed there. The layout comes from the machine
  running the Tern window. `setup_hook` is read on the worktree's host, so if
  you change it, set it in `config.json` on both machines.

## Troubleshooting

- **No panel, or no palette commands:** check `tern plugin list`. If it shows
  an error, run `tern plugin reload worktree-sessions` after fixing it.
- **My config change did nothing:** reload the plugin. Existing tabs keep their
  layout; the change applies to new worktree sessions and recreated tabs.
- **A command isn't found in a pane, or in setup:** panes use your login shell,
  but setup hooks use the daemon's `PATH`. See [the setup hook](#setup-the-setup-hook).
- **fish, nushell or PowerShell:** the shell hook needs a POSIX shell. Panes
  still run their commands, without the hook.

Tested with Tern 0.9.10.

## License

[MIT](LICENSE)
