"""FastMCP middleware for the Godot AI server."""

from __future__ import annotations

from godot_ai.middleware._validation_errors import find_pydantic_validation_error
from godot_ai.middleware.client_wrapper_kwargs import (
    CLIENT_WRAPPER_KWARGS,
    StripClientWrapperKwargs,
)
from godot_ai.middleware.fold_flat_manage_params import FoldFlatManageParams
from godot_ai.middleware.godot_command_error import PreserveGodotCommandErrorData
from godot_ai.middleware.op_typo_hint import HintOpTypoOnManage
from godot_ai.middleware.parse_stringified_params import ParseStringifiedParams

__all__ = [
    "CLIENT_WRAPPER_KWARGS",
    "FoldFlatManageParams",
    "HintOpTypoOnManage",
    "ParseStringifiedParams",
    "PreserveGodotCommandErrorData",
    "StripClientWrapperKwargs",
    "find_pydantic_validation_error",
]
