# Physics shape deferred-worker follow-up

The `resource_manage(op="physics_shape_generate")` capability shipped in v4.0.4 through PR #1028, superseding PR #892 and resolving the core request from issue #868. This follow-up does not change that API, its transform and validation rules, or its single-action undo/redo behavior.

The remaining defect was in the deferred driver. It was not registered with the process-wide `ScriptWork` ledger, so plugin script replacement could begin while its coroutine still owned old handler code. A lost connection could also end the frame loop without rolling back bodies created before the disconnect.

The driver now registers before its first frame yield and releases the registration on every normal or early exit. If the request is abandoned or its connection disappears before the undo action is committed, it removes and frees every partially created body. Once the action is committed, connection loss only drops the unavailable reply; the completed scene change and its undo history remain intact.

Regression coverage exercises the real driver through partial creation and synchronous connection exit, dispatcher abandonment, script-quiescence refusal and release, successful single-action undo/redo, and invalid or detached reply targets after a completed commit.
