"""Structured error codes for the Godot AI protocol."""

from enum import StrEnum


class ErrorCode(StrEnum):
    # Kept for Python API compatibility; missing pinned sessions now emit
    # PLUGIN_DISCONNECTED with data.reason == "session_not_found".
    SESSION_NOT_FOUND = "SESSION_NOT_FOUND"
    COMMAND_TIMEOUT = "COMMAND_TIMEOUT"
    EDITED_SCENE_MISMATCH = "EDITED_SCENE_MISMATCH"
    EDITOR_NOT_READY = "EDITOR_NOT_READY"
    INVALID_PARAMS = "INVALID_PARAMS"
    PLUGIN_DISCONNECTED = "PLUGIN_DISCONNECTED"
    UNKNOWN_COMMAND = "UNKNOWN_COMMAND"
    INTERNAL_ERROR = "INTERNAL_ERROR"
    DEFERRED_TIMEOUT = "DEFERRED_TIMEOUT"
    # game_eval failure codes (#490): distinguish a compile/parse failure
    # or a runtime error from the generic 10s timeout so agents get a fast,
    # actionable reply. Keep in sync with utils/error_codes.gd.
    EVAL_COMPILE_ERROR = "EVAL_COMPILE_ERROR"
    EVAL_RUNTIME_ERROR = "EVAL_RUNTIME_ERROR"
    # #518: the play session is up but the game-side autoload never registered
    # its debugger capture within the readiness wait (boot-window race, worst on
    # Windows, or a missing/disabled autoload). Carved out of INTERNAL_ERROR so
    # this fast (~3s), caller-actionable failure stops being counted as the
    # opaque "eval hung" 10s timeout. Keep in sync with utils/error_codes.gd.
    EVAL_GAME_NOT_READY = "EVAL_GAME_NOT_READY"
    ## audit-v2 #21 (issue #365): finer-grained codes carved out of the
    ## 471 INVALID_PARAMS sites so agents can distinguish recoverable
    ## input errors from structural ones. INVALID_PARAMS stays for
    ## genuinely catch-all input errors that don't fit any of the
    ## buckets below. See plugin/.../error_codes.gd for the full
    ## taxonomy comment.
    NODE_NOT_FOUND = "NODE_NOT_FOUND"
    RESOURCE_NOT_FOUND = "RESOURCE_NOT_FOUND"
    PROPERTY_NOT_ON_CLASS = "PROPERTY_NOT_ON_CLASS"
    VALUE_OUT_OF_RANGE = "VALUE_OUT_OF_RANGE"
    WRONG_TYPE = "WRONG_TYPE"
    MISSING_REQUIRED_PARAM = "MISSING_REQUIRED_PARAM"


class EditorNotReadySubCode(StrEnum):
    """#651 stage 1: sub-codes carried in ``error.data.sub_code`` on
    EDITOR_NOT_READY errors.

    Never emitted as a top-level ``error.code`` — existing callers and
    dashboards key on EDITOR_NOT_READY, so the top-level code is frozen.
    Each value names the concrete editor state at rejection time, limited
    to what EditorInterface/EditorFileSystem report deterministically.
    Undetectable busy states (script compilation, resource reload, modal
    dialogs) intentionally have no sub-code — a bare EDITOR_NOT_READY with
    no ``data.sub_code`` is the honest fallback, not a guessed label.
    Keep in sync with utils/error_codes.gd ``SUB_*`` constants — enforced
    by tests/unit/test_editor_not_ready_hint_contract.py.
    """

    EDITOR_IMPORTING = "EDITOR_IMPORTING"
    EDITOR_PLAYING = "EDITOR_PLAYING"
    EDITOR_NO_SCENE = "EDITOR_NO_SCENE"
    EDITOR_GAME_NOT_RUNNING = "EDITOR_GAME_NOT_RUNNING"
    EDITOR_VIEWPORT_UNAVAILABLE = "EDITOR_VIEWPORT_UNAVAILABLE"
    EDITOR_VIEWPORT_NOT_3D = "EDITOR_VIEWPORT_NOT_3D"
    EDITOR_VIEWPORT_EMPTY = "EDITOR_VIEWPORT_EMPTY"
    EDITOR_UNAVAILABLE = "EDITOR_UNAVAILABLE"
