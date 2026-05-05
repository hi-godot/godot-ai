"""Structured error codes for the Godot AI protocol."""

from enum import StrEnum


class ErrorCode(StrEnum):
    SESSION_NOT_FOUND = "SESSION_NOT_FOUND"
    COMMAND_TIMEOUT = "COMMAND_TIMEOUT"
    EDITED_SCENE_MISMATCH = "EDITED_SCENE_MISMATCH"
    EDITOR_NOT_READY = "EDITOR_NOT_READY"
    INVALID_PARAMS = "INVALID_PARAMS"
    PLUGIN_DISCONNECTED = "PLUGIN_DISCONNECTED"
    UNKNOWN_COMMAND = "UNKNOWN_COMMAND"
    INTERNAL_ERROR = "INTERNAL_ERROR"
    DEFERRED_TIMEOUT = "DEFERRED_TIMEOUT"
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
