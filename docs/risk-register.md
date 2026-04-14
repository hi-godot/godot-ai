# Godot AI — Risk Register

*Updated 2026-04-13*

This is the live risk register for the project. It exists to keep the plan honest.

---

## R1: Godot Learning Curve

Risk:

- editor APIs, plugin idioms, and GDScript patterns take time to internalize

Likelihood:

- high

Impact:

- medium

Mitigation:

- keep a real `test_project/`
- use AI assistance to accelerate API learning
- budget learning time explicitly instead of hiding it in estimates

---

## R2: Transport / Lifecycle Fragility

Risk:

- `WebSocketPeer`, plugin reload, reconnect handling, or session lifecycle edge cases consume too much engineering time

Likelihood:

- medium

Impact:

- high

Mitigation:

- keep the vertical-slice and reliability gates explicit
- treat reconnect and reload behavior as core product work, not polish
- simplify the transport if reality demands it

---

## R3: Editor API Gaps

Risk:

- some desired tool families will hit Godot editor API limits or awkward behavior

Likelihood:

- medium

Impact:

- medium

Mitigation:

- spike risky surfaces before promising them
- document gaps honestly
- avoid pretending every desired Unity-like workflow maps cleanly

---

## R4: Performance On Large Projects

Risk:

- scene walks, resource inspection, or log surfaces become too slow on large projects

Likelihood:

- low to medium

Impact:

- medium

Mitigation:

- paginate by default
- keep the queue / frame-budget model strict
- add caching or yielding only where the data proves it is needed

---

## R5: Packaging And Distribution Complexity

Risk:

- PyPI, `uvx`, binary builds, and cross-platform support create ongoing maintenance overhead

Likelihood:

- medium

Impact:

- medium to high

Mitigation:

- prioritize one default install path first
- treat binary distribution as optional unless it remains boring
- keep release-surface smoke tests in CI

---

## R6: Solo-Developer Scope Pressure

Risk:

- the project accumulates more surface area than a solo maintainer can harden and support

Likelihood:

- high

Impact:

- high

Mitigation:

- keep the working plan short and current
- use go/no-go gates honestly
- defer breadth when the core loop is not strong enough

---

## R7: Scope Creep From The Proposal

Risk:

- the proposal’s long tool taxonomy gets read as a commitment instead of an idea bank

Likelihood:

- medium

Impact:

- high

Mitigation:

- keep the proposal separate from the working plan
- drive new tool families from real workflow pressure
- require tests and smoke coverage for each meaningful expansion

