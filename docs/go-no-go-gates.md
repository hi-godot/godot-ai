# Godot AI — Go/No-Go Gates

*Updated 2026-04-13*

These gates are the “be honest with yourself” checkpoints for the project. They are not release marketing. They are where scope should be reduced or the approach should pivot if reality disagrees with the plan.

---

## Gate 1: Vertical Slice

Must prove:

- a real MCP tool call can go from client to server to plugin to editor API and back

Go if:

- the full vertical works, even if rough

No-go if:

- `WebSocketPeer` or plugin integration is fundamentally not viable for the product shape

Potential pivot:

- TCP or HTTP polling instead of WebSocket

---

## Gate 2: Connection Reliability

Must prove:

- the connection model is stable enough that new tool work is not dominated by reconnect bugs

Go if:

- you can open Godot, start the server, and interact without things falling apart in a few minutes

No-go if:

- connection stability is consuming most of the time budget

Potential pivot:

- simplify the transport or narrow the session model before building more tools

---

## Gate 3: Read-Surface Usefulness

Must prove:

- the read tools are genuinely useful for understanding a Godot project

Go if:

- the project is already helpful for inspection and navigation work

No-go if:

- responses are too noisy, too slow, or not structured enough to help the AI

Potential pivot:

- improve response quality and tool design before adding more write surface

---

## Gate 4: Write-Surface Trust

Must prove:

- write operations are safe and reliable enough to use on a project that matters

Go if:

- undo works
- readiness gating works
- you would trust the tool on a non-throwaway project

No-go if:

- writes are flaky, unsafe, or too easy to misuse

Potential pivot:

- reduce write scope and invest more in safety instead of adding breadth

---

## Gate 5: Real User Installability

Must prove:

- someone who is not already in the repo can install and use the product successfully

Go if:

- a new user can follow the docs and succeed without live support

No-go if:

- install requires too much manual debugging or platform-specific rescue work

Potential pivot:

- narrow the supported install surface and harden the easiest path first

