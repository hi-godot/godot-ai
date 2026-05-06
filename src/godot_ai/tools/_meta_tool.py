"""Helper for registering rolled-up `<domain>_manage` MCP tools.

A `<domain>_manage` tool collapses many per-verb tools into a single
dispatched tool that takes `op` (the action name) plus a `params` dict.
The shape mirrors `batch_execute`'s `(command, params)` ergonomic and
keeps the tool count small for clients with hard tool-count caps that
ignore Anthropic's `defer_loading` hint.

Each registered tool exposes `Literal["op_a", "op_b", ...]` for `op`,
so MCP clients with schema-driven autocomplete still see every valid
verb. Unknown ops surface as a structured error with fuzzy
`data.suggestions`.

Op handlers are registered as bare callables: each entry in ``ops`` is a
shared handler function (sync or async) accepting ``runtime`` plus the
handler's own keyword args. The dispatcher unpacks ``params`` itself, so
domain registrations stay free of identity-lambda boilerplate.
"""

from __future__ import annotations

import difflib
import functools
import inspect
import json
from collections.abc import Awaitable, Callable, Mapping, MutableMapping, MutableSequence, Sequence
from types import UnionType
from typing import Annotated, Any, Literal, Union, get_args, get_origin, get_type_hints

from fastmcp import Context, FastMCP

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.protocol.errors import ErrorCode
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META

## Op handlers may be async (the common case) or sync (e.g. session_*).
## ``dispatch_manage_op`` awaits the result if it's awaitable. The first
## positional arg is always the runtime; remaining kwargs come from the
## caller's ``params`` dict, unpacked by the dispatcher.
OpHandler = Callable[..., Awaitable[dict] | dict]


## Registry of registered ``<domain>_manage`` tools and their op names.
## Populated by ``register_manage_tool`` so middleware (e.g.
## ``HintOpTypoOnManage``) can reach the candidate list without
## reverse-engineering Pydantic's human-readable error string.
MANAGE_TOOL_OPS: dict[str, tuple[str, ...]] = {}

## (tool_name -> op_name -> handler) so the resource-form lint at test time
## can introspect each handler's source to classify it as read vs write.
MANAGE_TOOL_HANDLERS: dict[str, dict[str, OpHandler]] = {}

## (tool_name -> op_name -> URI string | None). Per-op resource declaration
## for read ops: a URI string declares the matching ``godot://...`` resource
## form, ``None`` is an explicit waiver acknowledging there is no resource
## counterpart. Write ops (handlers that call ``require_writable``) are
## exempt from this declaration; the lint enforces only read-op coverage.
MANAGE_TOOL_RESOURCE_FORMS: dict[str, dict[str, str | None]] = {}


@functools.cache
def _op_literal_for(op_names: frozenset[str]) -> Any:
    ## Sort because the cache key is a frozenset (orderless); a stable arg
    ## order keeps Pydantic's "Input should be …" error message consistent.
    return Literal[tuple(sorted(op_names))]  # type: ignore[valid-type]


def register_manage_tool(
    mcp: FastMCP,
    *,
    tool_name: str,
    description: str,
    ops: dict[str, OpHandler],
    read_resource_forms: Mapping[str, str | None] | None = None,
) -> None:
    """Register a `<domain>_manage` tool that dispatches by op name.

    Args:
        mcp: FastMCP instance to register on.
        tool_name: Tool name (e.g. ``"theme_manage"``).
        description: Tool docstring; should list every op with its
            required params so agents can compose calls without leaving
            tool-search.
        ops: Mapping of op name to a handler function. Each handler takes
            ``runtime`` as its first arg and accepts the same keyword args
            as the underlying shared handler in ``handlers/<domain>.py``.
            The dispatcher unpacks ``params`` via ``**`` before calling.
        read_resource_forms: Per-op declaration of the matching
            ``godot://...`` resource URI for read ops, or ``None`` as an
            explicit waiver when no resource counterpart exists. Keys must
            be a subset of ``ops``. Read-vs-write classification is done
            by ``tests/unit/test_resource_form_lint.py`` at test time
            (handlers calling ``require_writable`` are write ops and are
            exempt from declaration). The lint fails if a read op has
            no entry here, or if the declared URI isn't actually
            registered — catching both new-op drift and phantom-URI typos.

    Unknown ops raise ``GodotCommandError`` with ``INVALID_PARAMS`` and
    ``data.suggestions`` populated by ``difflib.get_close_matches``.
    """
    if not ops:
        raise ValueError(f"register_manage_tool: ops cannot be empty (tool {tool_name!r})")

    if read_resource_forms is not None:
        unknown = set(read_resource_forms) - set(ops)
        if unknown:
            raise ValueError(
                f"register_manage_tool: read_resource_forms keys "
                f"{sorted(unknown)!r} are not in ops for {tool_name!r}"
            )
        for op_name, form in read_resource_forms.items():
            if form is not None and not isinstance(form, str):
                raise ValueError(
                    f"register_manage_tool: read_resource_forms[{op_name!r}] "
                    f"must be a 'godot://' URI string or None waiver "
                    f"(got {type(form).__name__})"
                )
            if isinstance(form, str) and not form.startswith("godot://"):
                raise ValueError(
                    f"register_manage_tool: read_resource_forms[{op_name!r}] "
                    f"URI must start with 'godot://' (got {form!r})"
                )

    MANAGE_TOOL_OPS[tool_name] = tuple(ops.keys())
    MANAGE_TOOL_HANDLERS[tool_name] = dict(ops)
    MANAGE_TOOL_RESOURCE_FORMS[tool_name] = (
        dict(read_resource_forms) if read_resource_forms is not None else {}
    )
    op_literal = _op_literal_for(frozenset(ops.keys()))

    async def manage(ctx: Context, op, params=None, session_id="") -> dict:
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await dispatch_manage_op(
            ops=ops,
            tool_name=tool_name,
            runtime=runtime,
            op=op,
            params=params,
        )

    ## ``from __future__ import annotations`` would stringify ``op_literal``
    ## and pydantic resolves forward refs against module globals — where the
    ## local Literal does not exist. Setting ``__annotations__`` post-hoc
    ## with real type objects bypasses that resolution path.
    manage.__annotations__ = {
        "ctx": Context,
        "op": op_literal,
        "params": dict[str, Any] | None,
        "session_id": str,
        "return": dict,
    }
    manage.__name__ = tool_name
    manage.__qualname__ = tool_name
    manage.__doc__ = description
    mcp.tool(meta=DEFER_META)(manage)


def _is_json_shaped(value: str) -> bool:
    return value.lstrip()[:1] in ("[", "{")


def _json_container_kinds(annotation: Any) -> set[str]:
    """Return container kinds accepted by a handler annotation.

    An empty set means "do not coerce" — including unannotated, ``Any``, and
    ``object`` params. This is intentional: pre-PR behavior eagerly decoded
    every JSON-shaped string, which mangled legitimate values; post-PR we
    only decode when the handler explicitly declares list/dict shape.
    """
    if annotation in (inspect.Parameter.empty, Any, object):
        return set()

    origin = get_origin(annotation)
    args = get_args(annotation)
    if origin is Annotated:
        return _json_container_kinds(args[0]) if args else set()
    if origin in (Union, UnionType):
        kinds: set[str] = set()
        for arg in args:
            if arg is type(None):
                continue
            kinds.update(_json_container_kinds(arg))
        return kinds

    target = origin or annotation
    if target in (dict, Mapping, MutableMapping):
        return {"dict"}
    if target in (list, Sequence, MutableSequence):
        return {"list"}
    return set()


@functools.cache
def _handler_meta(handler: OpHandler) -> tuple[inspect.Signature | None, dict[str, Any]]:
    """Resolve and cache ``(signature, type_hints)`` for a registered handler.

    Handlers are registered once at startup and live for the lifetime of the
    process, so an unbounded cache is safe. ``get_type_hints`` walks module
    globals to resolve forward references — not free — and ``inspect.signature``
    introspects defaults; both ran on every dispatch before this cache.
    """
    try:
        signature = inspect.signature(handler)
    except (TypeError, ValueError):
        signature = None
    try:
        type_hints = get_type_hints(handler)
    except (NameError, TypeError, ValueError):
        type_hints = {}
    return (signature, type_hints)


def _expected_json_label(kinds: set[str]) -> str:
    if kinds == {"list"}:
        return "JSON array"
    if kinds == {"dict"}:
        return "JSON object"
    return "JSON array or object"


def _json_kind(value: Any) -> str:
    if isinstance(value, list):
        return "list"
    if isinstance(value, dict):
        return "dict"
    return type(value).__name__


def _coerce_stringified_json_values(
    params: dict[str, Any],
    *,
    handler: OpHandler,
    tool_name: str,
    op: str,
) -> dict[str, Any]:
    """JSON-decode nested params only when the handler annotation expects it.

    Some MCP clients stringify complex nested arguments before sending them
    inside a manage tool's ``params`` object. Decode those compatibility
    strings for list/dict-like handler params, but keep JSON-shaped strings
    intact for string-typed params and leave missing/extra-argument errors to
    the handler call below.

    Returns ``params`` unchanged when nothing needs coercion (the common case).
    """
    signature, type_hints = _handler_meta(handler)
    if signature is None:
        return params

    coerced: dict[str, Any] | None = None

    for key, val in params.items():
        if not isinstance(val, str) or not _is_json_shaped(val):
            continue

        parameter = signature.parameters.get(key)
        if parameter is None:
            continue

        annotation = type_hints.get(key, parameter.annotation)
        expected_kinds = _json_container_kinds(annotation)
        if not expected_kinds:
            continue

        try:
            decoded = json.loads(val)
        except json.JSONDecodeError as exc:
            expected = _expected_json_label(expected_kinds)
            raise GodotCommandError(
                code=ErrorCode.INVALID_PARAMS,
                message=(
                    f"{tool_name}.{op}: param {key!r} expects {expected}; "
                    "received malformed JSON string"
                ),
                data={
                    "tool": tool_name,
                    "op": op,
                    "param": key,
                    "expected": expected,
                    "json_error": exc.msg,
                },
            ) from exc

        actual_kind = _json_kind(decoded)
        if actual_kind not in expected_kinds:
            expected = _expected_json_label(expected_kinds)
            raise GodotCommandError(
                code=ErrorCode.INVALID_PARAMS,
                message=(
                    f"{tool_name}.{op}: param {key!r} expects {expected}; "
                    f"received JSON {actual_kind}"
                ),
                data={
                    "tool": tool_name,
                    "op": op,
                    "param": key,
                    "expected": expected,
                    "actual": actual_kind,
                },
            )

        if coerced is None:
            coerced = dict(params)
        coerced[key] = decoded

    return params if coerced is None else coerced


async def dispatch_manage_op(
    *,
    ops: dict[str, OpHandler],
    tool_name: str,
    runtime: DirectRuntime,
    op: str,
    params: dict[str, Any] | None,
) -> dict:
    """Run one op against ``runtime`` with ``params``.

    Note: when called via FastMCP, op-name validation has already happened
    at the Pydantic schema boundary (the wrapper's ``op`` parameter is a
    ``Literal`` of registered op names). The ``difflib`` suggestion path
    below only fires for direct dispatcher calls — e.g. unit tests, or
    a hypothetical future caller that bypasses the schema. Pydantic's
    own ``literal_error`` message already enumerates valid alternatives.

    Extracted from the closure so unit tests can drive it without spinning
    up a full FastMCP context. Handlers are called as
    ``handler(runtime, **params)`` — the ``ops`` map holds bare handler
    references rather than identity-lambda adapters.
    """
    handler = ops.get(op)
    if handler is None:
        suggestions = difflib.get_close_matches(op, ops, n=3, cutoff=0.5)
        message = f"{tool_name}: unknown op {op!r}"
        if suggestions:
            message += f" — did you mean: {', '.join(suggestions)}?"
        raise GodotCommandError(
            code=ErrorCode.INVALID_PARAMS,
            message=message,
            data={"tool": tool_name, "op": op, "suggestions": suggestions},
        )

    call_params = params if params is not None else {}
    if not isinstance(call_params, dict):
        raise GodotCommandError(
            code=ErrorCode.INVALID_PARAMS,
            message=f"{tool_name}: 'params' must be an object/dict",
            data={"tool": tool_name, "op": op, "type": type(call_params).__name__},
        )

    call_params = _coerce_stringified_json_values(
        call_params,
        handler=handler,
        tool_name=tool_name,
        op=op,
    )

    try:
        result = handler(runtime, **call_params)
        if inspect.isawaitable(result):
            result = await result
        return result
    except TypeError as exc:
        raise GodotCommandError(
            code=ErrorCode.INVALID_PARAMS,
            message=f"{tool_name}.{op}: {exc}",
            data={"tool": tool_name, "op": op, "received": list(call_params.keys())},
        ) from exc
