# Pstack for Codex and Claude Code

This repository packages [pstack](https://github.com/cursor/plugins/tree/main/pstack)
0.15.0 for explicit use in Codex and Claude Code. Claude Desktop's local Code
tab uses the Claude Code installation. Dedicated local sessions and hosted
workers can also use the repository entry point described below. Regular chat
and Cowork are not configured by these steps.

Every role inherits the model selected in its client. Poteto-mode starts only
when requested and applies to that task and its follow-ups, or to a whole
session when explicitly selected through a launcher or cloud environment. Default review
panels use two independent agents on the same model.

## Start a dedicated session

From this checkout on Windows:

```powershell
.\script\poteto.ps1 codex
.\script\poteto.ps1 claude
.\script\poteto.ps1 claude -Remote -Task 'Investigate the issue I describe next.'
```

On macOS or Linux:

```bash
bash script/poteto codex
bash script/poteto claude --remote 'Investigate the issue I describe next.'
```

The launchers explicitly select poteto-mode for every task in that session and
open the checkout containing the launcher. Without a task they ask the agent
to confirm the mode and wait. They read the bundled source by path, so no plugin
installation is needed for this entry point. They do not change ordinary
sessions, model selection, login, or permissions. The full entry point is
[poteto-session.md](poteto-session.md).

For a session started through a graphical app, send:

> Use docs/poteto-session.md for every task in this session until I turn it off.

## Control this machine from another device

Claude's `-Remote` launcher uses native `claude --remote-control`. Sign in through
`claude` and `/login` first. Follow the client's connection prompt and session
link from your browser or phone. The terminal session and this machine must
remain running. Desktop login does not establish that the CLI is signed in.
See [Claude Remote Control](https://code.claude.com/docs/en/remote-control).

The installed Codex CLI exposes an experimental, daemon-level remote-control
interface. The daemon requires the standalone installation managed by the official Codex
installer. An npm-only installation can expose these commands but cannot start
the daemon; follow the installation instructions printed by the CLI if needed.
Inspect its help on the machine you will use before starting it:

```text
codex remote-control --help
codex remote-control start
codex remote-control pair
```

Use the native pairing flow, then select or start a session for this checkout
and send the session prompt above. Starting or pairing the daemon alone does
not activate poteto-mode. Do not store pairing codes or connection credentials
in repository files. Account eligibility and a successful connection must be
checked in the client; these commands are not a claim that remote access is on.

These routes keep work on your computer, including access to its local Godot
editor and MCP configuration. Do not forward Godot's loopback ports directly.

## Hosted workers that run while this machine is off

First commit and push the reusable package, launchers, and documentation to a
branch the hosted worker can check out. Uncommitted worktree files and local
plugin caches are not available to cloud workers.

Create a dedicated poteto environment or use the explicit startup prompt above.
For an environment that supports agent-visible variables, set
`GODOT_AI_POTETO_SESSION=1`. The repository's `AGENTS.md` recognizes this opt-in
and loads `docs/poteto-session.md`. This is a workflow preference, not a secret.
Do not set it on an ordinary environment unless all its sessions should use
the mode. A setup-shell-only `export` is insufficient if it does not persist
into the agent session.

- **Codex cloud:** select the pushed branch and set the variable in the cloud
  environment settings. Use the existing project setup for dependencies, and
  verify at task start that the environment variable and bundled entry point
  are present. [Cloud environments](https://learn.chatgpt.com/docs/environments/cloud-environment)
  describes checkout, setup scripts, variables, and cached environments.
- **Claude Code cloud:** select the pushed branch and put the session prompt
  at the start of the task, or set the same agent-visible variable in a dedicated
  environment. `.claude/CLAUDE.md` already routes project guidance to `AGENTS.md`.
  This path reads the bundle directly and does not depend on syncing local
  plugins or installing from the generated local marketplace. See
  [Claude Code cloud](https://code.claude.com/docs/en/claude-code-on-the-web).

The first cloud smoke should report the checked-out commit, read the adapter,
confirm inherited models and session activation, then perform a bounded
read-only task. Inspect which tests and editor tools are actually available.
This setup does not provision a hosted Godot editor or prove a full live-editor
gate. Cloud workers cannot reach the desktop editor through this package.

## Install from a local checkout

Run the following from the checkout you intend to keep. The source and build
instructions are reusable; installation state lives in your user profile.
These commands register local sources and do not publish a marketplace.

Codex, in PowerShell:

```powershell
codex plugin marketplace add (Get-Location).Path
codex plugin add pstack-godot@godot-ai-local
```

Claude Code, in PowerShell with the repository's Python environment:

```powershell
.\.venv\Scripts\python.exe script/build-pstack-claude.py
claude plugin marketplace add (Resolve-Path .pstack-local/claude).Path --scope user
claude plugin install pstack-godot@godot-ai-local --scope user
```

Any Python 3.11+ interpreter can run the builder; it needs no third-party
dependencies. On macOS or Linux, use `python3`, `"$PWD"` for the Codex marketplace,
and `"$PWD/.pstack-local/claude"` for Claude's marketplace. If this marketplace
name is already registered from another checkout, inspect the existing
registration before replacing it.

Start a new Codex thread or Claude Code/Desktop Code session after installation.
Invoke `$poteto-mode` in Codex, or `/pstack-godot:poteto-mode` in Claude Code.
For example, ask it to investigate a specific Godot AI issue. Other bundled
skills are available explicitly through the skill picker or Claude's namespace.

The installation is user-scoped, so the plugin is available in other local
projects too. Its workflows remain opt-in and use the target project's guidance.
It does not change MCP connections, hooks, permissions, or selected models.

## Shared source and client metadata

- `plugins/pstack-godot/upstream/pstack/` preserves the original source and MIT
  license, pinned by commit and per-file SHA-256 in `upstream-lock.json`.
- `plugins/pstack-godot/PORTABILITY.md` maps Cursor's tools, model configuration,
  agent roles, and missing dependencies onto the host client.
- `plugins/pstack-godot/skills/` contains 47 small entry points. Codex's
  `agents/openai.yaml` files disable implicit invocation.
- `script/build-pstack-claude.py` builds a local package whose entry points add
  Claude's `disable-model-invocation: true`. Its marketplace is generated under
  `.pstack-local/claude/`. The original upstream files remain unchanged.

The upstream pin is
`df3fb154fb982fb83f649de8646d4af6a0cb16b3`. The adapter is maintained here;
this is not an upstream-supported Codex or Claude release. Cursor's cloud-agent
APIs and `cursor-team-kit` dependencies are not installed. The adapter describes
the available substitutions and requires reporting missing verification.

## Personal information

Shared defaults are in `plugins/pstack-godot/models.md`. Optional personal
overrides belong in `.pstack.local.md`; private artifacts belong in
`.pstack-local/`. Both paths are ignored. Before creating personal settings,
confirm the ignore rules with:

```text
git check-ignore .pstack.local.md .pstack-local/example.txt
```

Do not copy user-profile configuration, credentials, machine paths, account
identifiers, private transcripts, or generated decision trails into the plugin.
Check the actual diff before staging. The package retains the upstream author's
public attribution as required by its license.

## Verify and update

```text
codex plugin list --marketplace godot-ai-local --available --json
claude plugin details pstack-godot@godot-ai-local
pytest tests/unit/test_pstack_package.py -q
```

The tests verify the upstream snapshot, client-specific activation metadata,
repeatable builds, isolation from personal files, and preservation of older
generated packages. They do not prove every upstream workflow or external API.
Test a real scoped task in each client before relying on long-running workflows.

For an upstream update, review the selected upstream commit, replace the
snapshot, update its file hashes, and review the adapter against changed tool
and model assumptions. Increment the package version when publishing a new
adaptation. Reinstall Codex after changing its version; rebuild Claude's package
and run `claude plugin update pstack-godot@godot-ai-local`. New builds get
content-addressed paths so an existing session's package is not removed.

Keep the source checkout until its changes are committed or transferred. A
cached installation is not a backup of this repository's uncommitted work.
After moving to another checkout, register the new local marketplace paths in
each client and reinstall. Do not commit those absolute local registrations.
