# Worktrees — health, repair, and coexistence

Part of the Godot AI agent guide — see [AGENTS.md](../AGENTS.md) for the always-loaded rules.


Mechanics of the `test_project/addons/godot_ai` link and how to work safely in a
worktree another session owns. The data-loss rules themselves stay in AGENTS.md.

### Worktree health: `script/verify-worktree` + `post-checkout` hook

`test_project/addons/godot_ai` is **not tracked in git** (see `.gitignore` and #185). Every working copy builds the link locally — as a symlink on Unix, as a directory junction on Windows. This avoids the Windows-without-Dev-Mode text-file-fallback trap and stops `git rebase` / `cherry-pick` from fighting the link on every checkout.

Before editing *anything* in `plugin/` in a worktree, the worktree must pass two invariants:

1. `plugin/addons/godot_ai/plugin.gd` exists (the worktree's `plugin/` is populated, not empty or sparse).
2. `test_project/addons/godot_ai` is a real symlink (or Windows directory junction) into **this worktree's** `plugin/addons/godot_ai`.

`script/verify-worktree` (bash, works in git-bash on Windows) checks both. If the link is missing or broken it creates/repairs it via `ln -s` or `mklink /J` — no admin rights, no Windows Developer Mode required. It runs automatically via a `post-checkout` hook on every `git worktree add` and `git checkout <branch>`, so a freshly-created worktree is healthy by the time you start editing.

Wiring: `script/setup-dev` and `script/setup-dev.ps1` copy `script/githooks/post-checkout` into `.git/hooks/post-checkout` (the default path git always looks at). `.git/hooks/` is shared across all worktrees of a clone, so one install covers every future worktree forever. A fresh clone on a new machine needs setup-dev run once before the hook is active — after that, it's automatic. (We don't use `core.hooksPath=script/githooks` because git resolves that relative path against main's working tree, which may be on a branch without `script/githooks/` — a trap that wasted a whole debugging cycle.)

**If you find a broken worktree** (empty `plugin/`, or the link missing/stale): do NOT `git add` anything. Run `script/verify-worktree` to heal, or re-create the worktree. Committing plugin/ edits from a broken worktree stages phantom deletions that overwrite the canonical plugin code in main on push.

**Parallel plugin development IS supported** — each worktree has its own `plugin/` (standard git worktree semantics) and its own locally-built `test_project/addons/godot_ai` link. Multiple Godot editors, one per worktree, all connect to the same MCP server on :8000; use `session_activate` (or `session_id` per call) to route. The ban is only on editing in *broken* worktrees.

### Working in another session's worktree

Sometimes you're directed at another session's PR worktree (e.g. to fix a bug their friction log surfaced) and that session still has in-flight uncommitted work in adjacent files. Coexist safely:

1. **Inspect before you touch**: run `git status` and `git diff --stat` in the target worktree first so you know which files are already dirty — that's the other session's work, not your canvas.
2. **Stage by explicit path**: `git add plugin/foo.gd test_project/tests/test_foo.gd`, never `git add .` or `git add -A`. Even if their uncommitted work looks related to yours, it isn't yours to commit.
3. **Multi-editor is fine when you need the PR's live plugin code**: launch a second Godot editor pointed at the PR worktree's `test_project/` alongside any existing editor — both connect to the same MCP server on port 8000 and show up in `session_list`. Use `session_activate` to pin your commands to the right session. This beats killing the other session's editor or rsync'ing PR code over an unrelated project.
4. **Accept the auto-clean risk**: a worktree owned by another session can be removed when that session exits. Commit (and ideally push) as soon as your fix and tests are green — don't leave uncommitted work in a worktree you don't own.
5. **Revert your own autosave pollution** before committing (see "Live-smoke scene hygiene"). Running the scene during smoke will dirty the scene file with any in-memory mutations you staged.
6. **Push only what's yours**: don't push the branch if it still contains another session's uncommitted experimental work — they may not be ready. When in doubt, commit locally and ask.
