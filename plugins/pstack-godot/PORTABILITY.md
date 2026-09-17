# Pstack for Codex and Claude Code

Read this adapter before any bundled upstream skill or playbook. It defines how
to interpret Cursor-specific instructions on these clients. Follow the current
user request, host instructions, and the target repository's `AGENTS.md` first.
The snapshot under `upstream/pstack/` is reference material, not host configuration.

## Activation and scope

Enter poteto-mode only when the user requests it. Normally it applies to that
task and its follow-ups. An explicitly selected dedicated poteto session
(`docs/poteto-session.md`, a poteto launcher, or `GODOT_AI_POTETO_SESSION=1`)
applies it to each task in that session until the user turns it off. Do not
enable the mode in ordinary sessions through a startup hook or default agent.
Supporting skills may be read when an explicitly requested pstack workflow
routes to them. A standalone helper request does not activate the full mode.

Upstream autonomy and shipping instructions do not authorize unrelated work,
messages, publication, merges, deployments, or changes to permissions. Apply
the task's existing authorization. Opening a PR is a conditional delivery step,
not a required consequence of invoking a skill.

## Loading the bundle

Paths here are relative to this plugin directory. Locate it from the invoked
skill file, including when a client has copied the plugin into its cache.

- Skills and principles live at `upstream/pstack/skills/<name>/SKILL.md`.
- Playbooks live at `upstream/pstack/skills/poteto-mode/playbooks/`.
- Agent prompts live at `upstream/pstack/agents/`.
- Read the actual referenced leaf before applying or citing a principle.

Resolve upstream slash commands through these files. In Claude Code, public
entry points are namespaced `/pstack-godot:<skill>`. In Codex, use the installed
skill picker or `$<skill>`; choose the pstack-godot plugin if names collide.
Do not search Cursor installation directories when this bundle has the file.
When passing work to an agent, include the resolved adapter and leaf paths.

## Models and delegation

The shared configuration is `models.md`. Read optional `.pstack.local.md` in
the target repository only for local overrides. That file must remain ignored.
References to `~/.cursor/rules/pstack-models.mdc` mean these two files instead.
Every default role inherits the parent model. Ignore upstream hardcoded model
slugs, including slugs embedded in reviewer tables and playbook prose.

- Codex uses its available delegation tools. Omit model and reasoning overrides
  for inheritance. A Cursor `subagent_type` is a role prompt, not a Codex API
  parameter. Give the delegate this adapter and the matching upstream agent
  prompt when a named role is required.
- Claude Code uses its native Agent tool and installed custom agents. Resolve
  `poteto-agent` to `pstack-godot:poteto-agent`, `Comment Sicko` to
  `pstack-godot:comment-sicko`, and `generalPurpose` to the native general-purpose
  agent. Omit the model override to inherit. Use background execution only when
  supported by the actual tool.
- Panel lists create one independent reviewer per entry. The default panel has
  two entries, both inheriting the parent. Describe it as a same-model review;
  do not claim model-family diversity or fabricate a cross-family judge.
- Respect the host's concurrency limit. Queue additional roles rather than
  assuming all upstream workers can run at once. If delegation is unavailable,
  report that limitation and use sequential work only where it can meet the
  workflow's purpose. Do not claim an independent review from a self-review.
- Read-only review describes the assigned scope. Choose permissions from the
  host's actual controls; upstream claims that read-only disables MCP do not
  establish this client's behavior.

`AskQuestion`, `TodoWrite`, and other Cursor tool names mean the equivalent
available host facility. Ordinary text suffices for questions and checklists
when no dedicated facility exists. Cursor cloud-agent, transcript, simulator,
and loop APIs are not implied by this installation. Inspect capabilities before
using them. Do not install services or launch an unbounded loop to imitate one.

## External dependencies and verification

The upstream `cursor-team-kit` dependency is not bundled. For `deslop`, perform
the scoped diff cleanup with available review tools and state that substitution.
For `create-skill`, use the host's skill-authoring guidance. For `control-cli`
and `control-ui`, use available terminal, browser, or application tools to prove
the relevant behavior. If the needed surface is unavailable, report the missing
verification rather than claiming the Cursor skill ran.

Godot verification follows the target checkout's `AGENTS.md` and
`docs/verification.md`. Use its existing harness and connected Godot MCP tools.
Pin the intended editor session and obey worktree and smoke-artifact rules.
Keep required comments, license notices, and Godot documentation conventions
even when an upstream prose or comment-removal preference differs.

Bundled scripts are upstream source, not installed runtimes. Before executing
one, inspect its dependencies, platform assumptions, and side effects. Nothing
in this package configures Godot MCP, installs Bun, starts monitors, or registers
hooks. Claude Desktop support means local Code-tab sessions. Regular chat,
Cowork, and cloud sessions need separately verified capabilities and setup.

## Personal information

Keep credentials, account identifiers, machine paths, private transcripts,
personal model preferences, and generated decision trails out of tracked files.
Use `.pstack.local.md` and `.pstack-local/` for local settings and artifacts;
both are ignored by the repository. In particular, `recall`, `automate-me`, and
`reflect` do not grant permission to publish personal context or mine unrelated
conversations. Only collect the context needed for the requested task. Inspect
the actual diff before staging; `.gitignore` is not a secrets scanner.
