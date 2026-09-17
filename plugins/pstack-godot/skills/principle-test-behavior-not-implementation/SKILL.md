---
name: principle-test-behavior-not-implementation
description: Apply when you write, change, or keep a test. Call the code the way its users do and assert the result they observe against a literal expected value. If the test would still pass when every imported function returns undefined, rewrite the assertion or delete the test.
---

Read [the host adapter](../../PORTABILITY.md) first. Then read and apply
[the upstream principle-test-behavior-not-implementation skill](../../upstream/pstack/skills/principle-test-behavior-not-implementation/SKILL.md)
under that adapter. Resolve all routed skills through this same bundle.
