---
name: worktree-sessions-setup
description: Write or fix a repository's Worktree Sessions setup for the Tern terminal — the files under .tern/worktree-sessions/ (setup.json questions, the setup hook, the per-shell hook) that prepare each new git worktree. Use when the user wants new worktrees to get a venv or node_modules, copied .env files, linked data, per-branch output directories, or setup questions, or when a Worktree Sessions setup or shell hook fails.
---

# Worktree Sessions repository setup

[Worktree Sessions](https://github.com/ryankish/tern-worktree-sessions) is a
Tern plugin that opens each git worktree as its own terminal session. When it
creates a worktree, it can run the repository's own setup. You write that
setup: up to three files in `.tern/worktree-sessions/` at the repository root.
The plugin assigns no meaning to their contents.

| File | Runs | Purpose |
| --- | --- | --- |
| `setup.json` | Read before `git worktree add` | Questions the user answers in Tern |
| `setup` | Once, after `git worktree add`, before tabs open; again on **Run Setup** | Prepare the worktree |
| `shell` | Sourced by every new shell in the worktree | Fast per-shell environment |

The paths are the defaults. A user may change them with `setup_hook` and
`shell_hook` in the plugin's `config.json`; `setup.json` is always the
`setup_hook` path plus `.json`.

## Workflow

1. **Learn what a fresh worktree is missing.** `git worktree add` gives tracked
   files only. Look for:
   - an environment to build: `pyproject.toml`/`uv.lock`, `requirements*.txt`,
     `package.json` and its lockfile, `Cargo.toml`, `go.mod`, a `Makefile`
     bootstrap target;
   - untracked files the project needs: `.env*` and local config, by reading
     `.gitignore` and the README's setup steps;
   - data or caches that live outside the repository, or are too large to
     copy;
   - outputs that two branches would overwrite (results, experiment runs,
     build artifacts in a fixed absolute location).
2. **Ask the user** about anything with a real tradeoff before encoding it.
   That is what `setup.json` questions are for. The usual one is sharing an
   environment (instant, but both worktrees see each other's package changes)
   versus building a separate one (slow, isolated). Don't ask about things
   with one right answer.
3. **Decide what goes where.** One-time or slow work goes in `setup`. Anything
   each shell needs (activating an environment, exporting a per-worktree path)
   goes in `shell`. Never install or download in `shell`.
4. **Write the files**, then **test them** (see Testing).
5. **Ask whether to commit them.** Committed files apply to every teammate who
   uses the plugin. For a personal setup, list `.tern/` in `.git/info/exclude`
   and have `setup` copy the shell hook into each new worktree (see Personal
   setups).

## `setup.json`

Optional. Omit it if there is nothing to choose.

```json
{
  "version": 1,
  "questions": [
    {
      "id": "environment",
      "label": "How should this worktree get its Python environment?",
      "description": "Optional longer help.",
      "default": "independent",
      "choices": [
        { "id": "independent", "label": "Independent venv",
          "description": "Run uv sync for this worktree's own .venv." },
        { "id": "shared", "label": "Share the primary checkout's venv" }
      ]
    }
  ]
}
```

Rules the plugin enforces:

- `version` is `1`, and there is at least one question.
- Question and choice `id`s match `^[A-Za-z_][A-Za-z0-9_-]*$` and are unique.
- `label` is a nonempty string; `description` is optional.
- Each question has at least one choice. `default` must be one of its choice
  ids, and defaults to the first.

The answers reach `setup` as one JSON object, for example
`{"environment":"shared"}`. Without `setup.json` the object is `{}`.

## `setup` (the setup hook)

- **Executable** (`chmod +x`), with a shebang. Any language available on the
  host.
- Runs with the **new worktree as its working directory**, on the worktree's
  host, which may be a remote machine. Time limit: 15 minutes.
- Arguments: `$1` primary checkout, `$2` worktree path, `$3` branch (`HEAD`
  when detached).
- Environment:
  - `WORKTREE_SESSION_REPO_ROOT`: the primary checkout
  - `WORKTREE_SESSION_PATH`: the worktree being set up
  - `WORKTREE_SESSION_BRANCH`: its branch
  - `WORKTREE_SESSION_SETUP_SOURCE`: the checkout the setup files were read
    from. When creating, that's the checkout the user was in, so uncommitted
    edits there take effect. On Run Setup, it's the worktree itself.
  - `WORKTREE_SESSION_SETUP_CHOICES_JSON`: the answers
  - `WORKTREE_SESSION_HOST`, `WORKTREE_SESSION_HOST_KIND`: the Tern host
- Exit 0 to open the session. On a nonzero exit, the user sees the output and
  can retry or open the session anyway. The worktree is kept either way, so
  write clear error messages.

Requirements that are easy to miss:

- **Rerunnable.** Run Setup reruns the hook on an existing worktree,
  including the primary checkout, where `$1` and `$2` are the same path.
  Check before creating, linking or copying. Never link something to itself,
  and never overwrite the user's edited files, such as an existing `.env`.
- **`PATH` is the Tern daemon's, not the login shell's.** Tools like `uv`,
  `node` or `cargo` may be missing. Look them up through
  `"$SHELL" -lic 'command -v uv'` when they're not found directly.
- **Shared resources.** When linking the primary checkout's environment,
  check that it exists and matches the branch (for example, compare
  `uv.lock`). Refuse with a message that says which choice to make instead,
  rather than linking something broken.
- **Everything setup creates must be git-ignored.** The plugin removes
  worktrees without `--force`, so any untracked file left by setup (a copied
  `.env`, a link, a copied shell hook) blocks removal. Check with
  `git status --short` in the test worktree; it should print nothing. Note that
  `.venv/` ignores a directory but not a symlink named `.venv`; use `.venv`.
  `.git/info/exclude` applies to every worktree of the repository.
- **Leave the primary checkout alone**, apart from reading it.
- End by checking that the result works (run the venv's python, the tool's
  `--version`), so failures surface here and not in the first shell.

Minimal shell example:

```sh
#!/bin/sh
set -eu
primary=$1 worktree=$2
if [ "$primary" != "$worktree" ] && [ -f "$primary/.env" ] && [ ! -e .env ]; then
  cp "$primary/.env" .env
fi
[ -e data ] || ln -s /srv/datasets data
```

## `shell` (the per-shell hook)

- **Sourced, not executed**, so use `return 1` on failure, never `exit`. `exit`
  closes the user's shell.
- POSIX `sh` syntax only. It runs under zsh, bash, sh, ksh, dash or ash. No
  `[[ ]]`, arrays or `local` outside functions; `source` is fine only as `.`.
- `WORKTREE_SESSION_PATH` is the worktree root. The shell's directory may be a
  subdirectory, so build paths from the variable, never from `.`.
- If it fails, the pane's command (nvim, an agent) doesn't start, and the
  error stays visible. Print one line saying what's wrong and what to do,
  usually "run Worktree Sessions: Run Setup".
- Fast and quiet: it runs in every new pane and tab. No network, no
  installs, no output when things are fine.
- The plugin reads it from **each worktree**, not from the checkout the user
  was in. It must be committed (so new branches have it) or written by
  `setup`.

```sh
if [ ! -f "$WORKTREE_SESSION_PATH/.venv/bin/activate" ]; then
  printf 'no .venv in %s; run Worktree Sessions: Run Setup\n' "$WORKTREE_SESSION_PATH" >&2
  return 1
fi
. "$WORKTREE_SESSION_PATH/.venv/bin/activate"
export RESULTS_DIR="$HOME/results/$(basename "$WORKTREE_SESSION_PATH")"
```

## Personal setups

If teammates don't use the plugin, or the user doesn't want the files in Git:

1. Add `.tern/` to `.git/info/exclude`, which is never committed.
2. In `setup`, copy the shell hook into the new worktree:

```sh
if [ "$WORKTREE_SESSION_SETUP_SOURCE" != "$WORKTREE_SESSION_PATH" ]; then
  mkdir -p .tern/worktree-sessions
  cp "$WORKTREE_SESSION_SETUP_SOURCE/.tern/worktree-sessions/shell" .tern/worktree-sessions/
fi
```

A plain `git worktree add` never runs these hooks, so teammates who don't use
the plugin are unaffected either way.

## Testing

Test without Tern, in a throwaway worktree:

```sh
git worktree add ../wt-test -b wt-test
cd ../wt-test
WORKTREE_SESSION_SETUP_CHOICES_JSON='{"environment":"shared"}' \
WORKTREE_SESSION_REPO_ROOT="$OLDPWD" WORKTREE_SESSION_PATH="$PWD" \
WORKTREE_SESSION_BRANCH=wt-test WORKTREE_SESSION_SETUP_SOURCE="$OLDPWD" \
  "$OLDPWD/.tern/worktree-sessions/setup" "$OLDPWD" "$PWD" wt-test
```

- Run the hook a second time to check it's rerunnable.
- Run it once with `$1` and `$2` both set to the primary checkout.
- Test each choice.
- Test the daemon's short `PATH`:
  `env -i HOME="$HOME" USER="$USER" SHELL="$SHELL" PATH=/usr/bin:/bin ...`
- Source the shell hook in `sh`, `bash` and `zsh`:
  `WORKTREE_SESSION_PATH="$PWD" sh -c '. .tern/worktree-sessions/shell && env | grep VIRTUAL_ENV'`
- `python3 -m json.tool .tern/worktree-sessions/setup.json` catches JSON
  errors. The plugin also reports invalid questions when the user creates a
  worktree.
- Check `git status --short` prints nothing in the test worktree.
- Clean up: `cd - && git worktree remove ../wt-test && git branch -D wt-test`.
  If removal fails because of files setup created, fix the ignore rules
  rather than forcing it.

Then tell the user to try **+ New Worktree** in Tern. Setup output and errors
appear in the worktree panel.

A complete example (uv, shared or independent venv) is in the plugin's
`examples/uv-venv/`.
