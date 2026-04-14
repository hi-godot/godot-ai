# Godot AI — Product Positioning

*Updated 2026-04-14*

This document captures the product identity, differentiation, and naming strategy for Godot AI.

Use the related docs for adjacent concerns:

- [proposal.md](proposal.md) for the product case and scope
- [implementation-plan.md](implementation-plan.md) for the active roadmap
- [packaging-distribution.md](packaging-distribution.md) for package identity and release paths

---

## Positioning

Godot AI should be positioned as:

- a mature, open-source Godot MCP server

The credible differentiators are:

- persistent editor integration
- multi-session awareness
- strong read resources and safe write workflows
- runtime feedback loops
- tests, CI, docs, and release discipline
- a Godot-native tool surface instead of a thin generic bridge

That is enough to matter if the product is reliable.

---

## Competitive Framing

The project does not need to win by attacking other Godot MCP efforts. It wins by clearly occupying a different quality tier.

The framing should be:

- not a proof-of-concept bridge
- not a one-shot command relay
- not a generic engine abstraction
- a production-minded Godot editor tool

The existence of lighter projects is useful because it validates demand. Godot AI should answer a different question: what does a serious Godot MCP look like when it is built for sustained use?

---

## Target Users

The best initial audience is:

- Godot developers already using AI coding tools
- plugin and tools developers who need editor automation
- advanced hobbyists and indies who want real project assistance, not just file generation

This is not primarily a mass-market "AI game maker" story. It is a serious tooling story first.

---

## Naming Strategy

The current choice is:

- repo: `godot-ai`
- display name: `Godot AI`

Why this works:

- short and memorable
- distinct from existing `godot-mcp` branding
- still leaves room to use "Godot MCP server" aggressively in subtitles, package metadata, and documentation for search relevance

The project should use `Godot MCP` as an important keyword, not as its only identity.

---

## Community Strategy

The long-term strategy should stay grounded in the Godot community:

- prioritize workflows users actually request
- harden core editing loops before chasing novelty
- keep contributor paths clear
- publish compatibility guidance and keep it current
- let user feedback shape defaults, docs, and ergonomics

Good developer tools grow by becoming more useful, more reliable, and easier to contribute to. That should be the standard here too.
