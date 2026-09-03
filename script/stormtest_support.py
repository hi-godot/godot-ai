"""Pure deterministic schedule and acceptance contracts for ``stormtest``."""

from __future__ import annotations

import hashlib
import json
import math
import os
import random
import stat
from pathlib import Path
from typing import Any

APPROVED_SEEDS = (41001, 41002, 41003)
LOCKED_PROFILES = frozenset({"steady", "reload-churn", "multi-editor"})
LOCKED_TARGET_IDS = {
    "steady": ("editor-a",),
    "reload-churn": ("editor-a",),
    "multi-editor": ("editor-a", "editor-b"),
}
TOLERATED_RELOAD_ERRORS = frozenset({"CONNECTION", "EDITOR_NOT_READY"})
DISPOSABLE_MARKER = ".godot-ai-stormtest-disposable"
DISPOSABLE_MARKER_TOKEN = "godot-ai-stormtest-disposable-v1"
SCRATCH_DIRECTORY = "_stormtest"


class StormConfigError(ValueError):
    """A profile, target, trace, or threshold file is not executable."""


def canonical_project_path(path: str | Path) -> str:
    """Return the local, case-normalized identity used for editor projects."""

    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        raise StormConfigError(f"project identity path must be absolute: {path}")
    return os.path.normcase(str(candidate.resolve(strict=True)))


def validate_disposable_project(path: str | Path) -> Path:
    """Prove that ``path`` is an explicitly marked, clean qualification project.

    The marker is deliberate destructive-test authorization, not a prompt. The
    scratch namespace must be absent so cleanup can only remove a tree created
    by this run.
    """

    root = Path(path).expanduser()
    if not root.is_absolute():
        raise StormConfigError(f"qualification project path must be absolute: {path}")
    try:
        root = root.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise StormConfigError(f"qualification project does not exist: {path}: {error}") from error
    if not root.is_dir():
        raise StormConfigError(f"qualification project is not a directory: {root}")

    project_file = root / "project.godot"
    if project_file.is_symlink() or not project_file.is_file():
        raise StormConfigError(f"qualification project needs a regular project.godot: {root}")

    marker = root / DISPOSABLE_MARKER
    if marker.is_symlink() or not marker.is_file():
        raise StormConfigError(
            f"qualification project needs regular marker {marker} containing "
            f"{DISPOSABLE_MARKER_TOKEN!r}"
        )
    try:
        if marker.stat().st_size > 128:
            raise StormConfigError(f"qualification marker {marker} exceeds the 128-byte limit")
        marker_value = marker.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise StormConfigError(f"cannot read qualification marker {marker}: {error}") from error
    if len(marker_value.encode("utf-8")) > 128 or marker_value.strip() != DISPOSABLE_MARKER_TOKEN:
        raise StormConfigError(
            f"qualification marker {marker} must contain exactly "
            f"{DISPOSABLE_MARKER_TOKEN!r} (plus surrounding whitespace only)"
        )

    scratch = root / SCRATCH_DIRECTORY
    if os.path.lexists(scratch):
        raise StormConfigError(
            f"qualification scratch path must be absent before the run: {scratch}"
        )
    cache = root / ".godot"
    if os.path.lexists(cache):
        expected_cache = os.path.normcase(os.path.abspath(cache))
        try:
            resolved_cache = os.path.normcase(str(cache.resolve(strict=True)))
        except (OSError, RuntimeError) as error:
            raise StormConfigError(
                f"cannot resolve qualification cache directory {cache}: {error}"
            ) from error
        if cache.is_symlink() or not cache.is_dir() or resolved_cache != expected_cache:
            raise StormConfigError(
                f"qualification project root .godot must be a plain directory: {cache}"
            )
    return root


def parse_qualification_project_specs(specs: list[str]) -> dict[str, Path]:
    """Parse repeatable ``NAME=/absolute/disposable/project`` bindings."""

    projects: dict[str, Path] = {}
    for spec in specs:
        name, separator, raw_path = spec.partition("=")
        name = name.strip()
        raw_path = raw_path.strip()
        if not separator or not name or not raw_path:
            raise StormConfigError(
                f"qualification project {spec!r} must be NAME=/absolute/project/path"
            )
        if name in projects:
            raise StormConfigError(f"duplicate qualification project id {name!r}")
        projects[name] = validate_disposable_project(raw_path)
    canonical_roots = {canonical_project_path(root) for root in projects.values()}
    if len(canonical_roots) != len(projects):
        raise StormConfigError("qualification projects must use distinct canonical roots")
    return projects


def project_tree_inventory(root: Path) -> dict[str, str]:
    """Hash the durable project tree, excluding Godot's generated ``.godot`` cache."""

    root = root.resolve(strict=True)
    inventory: dict[str, str] = {}
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        if current_path == root:
            directories[:] = [name for name in directories if name != ".godot"]
        for name in sorted([*directories, *files]):
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            try:
                mode = path.lstat().st_mode
            except OSError as error:
                raise StormConfigError(
                    f"cannot inspect qualification path {path}: {error}"
                ) from error
            if stat.S_ISLNK(mode):
                inventory[relative] = f"link:{os.readlink(path)}"
                if name in directories:
                    directories.remove(name)
            elif stat.S_ISDIR(mode):
                inventory[relative] = "directory"
            elif stat.S_ISREG(mode):
                try:
                    digest = hashlib.sha256()
                    size = 0
                    with path.open("rb") as stream:
                        while chunk := stream.read(1024 * 1024):
                            size += len(chunk)
                            digest.update(chunk)
                except OSError as error:
                    raise StormConfigError(
                        f"cannot read qualification file {path}: {error}"
                    ) from error
                inventory[relative] = f"file:{size}:{digest.hexdigest()}"
            else:
                raise StormConfigError(f"unsupported qualification project entry: {path}")
    return dict(sorted(inventory.items()))


def project_tree_drift(before: dict[str, str], after: dict[str, str]) -> list[str]:
    """Return compact path-level differences between two project inventories."""

    drift: list[str] = []
    for path in sorted(set(before) | set(after)):
        if path not in before:
            drift.append(f"added {path}")
        elif path not in after:
            drift.append(f"removed {path}")
        elif before[path] != after[path]:
            drift.append(f"changed {path}")
    return drift


def transport_exception_code(error: Exception) -> str | None:
    """Recognize SDK timeout/rotated-auth envelopes, not arbitrary tool errors.

    CONNECTION remains a failure outside a measured reload window. MCP's
    Python SDK wraps its receive timeout in ErrorData(code=408), rather than
    raising asyncio.TimeoutError. A restarted managed server rotates its HTTP
    capability, so an old client's in-flight request may receive HTTP 401.
    """
    # Keep schedule/threshold validation stdlib-only. The live MCP path already
    # depends on AnyIO, whose closed stream is another transport disconnect.
    from anyio import BrokenResourceError, ClosedResourceError, EndOfStream
    from httpx import ReadError

    # A backend shutdown can sever HTTP reads without an error message. Match
    # the concrete transport type, not text or all HTTP/protocol exceptions.
    if isinstance(error, (BrokenResourceError, ClosedResourceError, EndOfStream, ReadError)):
        return "CONNECTION"
    if getattr(getattr(error, "response", None), "status_code", None) == 401:
        return "CONNECTION"
    if getattr(getattr(error, "error", None), "code", None) == 408:
        return "CONNECTION"
    return None


def pinned_session_identity(sessions: Any, session_id: str) -> dict[str, Any]:
    """Bind an exploratory explicit pin before the first mutation or reload."""
    if not isinstance(sessions, list) or not all(isinstance(row, dict) for row in sessions):
        raise StormConfigError("session_manage returned a malformed session list")
    matches = [row for row in sessions if row.get("session_id") == session_id]
    if not session_id or len(matches) != 1:
        raise StormConfigError("explicit pin must name exactly one live session")
    selected = select_initial_session(
        sessions,
        expected_project_path=matches[0].get("project_path", ""),
        requested_session_id=session_id,
        require_only_session=False,
    )
    return {
        "editor_pid": selected["editor_pid"],
        "project_path": canonical_project_path(selected["project_path"]),
    }


def select_initial_session(
    sessions: Any,
    *,
    expected_project_path: str | Path,
    requested_session_id: str = "",
    require_only_session: bool,
) -> dict[str, Any]:
    """Select and validate the exact editor a locked target is allowed to touch."""

    if not isinstance(sessions, list) or not all(isinstance(row, dict) for row in sessions):
        raise StormConfigError("session_manage returned a malformed session list")
    if require_only_session and len(sessions) != 1:
        raise StormConfigError(
            f"locked single-editor target requires exactly one session, got {len(sessions)}"
        )
    if requested_session_id:
        matches = [row for row in sessions if row.get("session_id") == requested_session_id]
        if len(matches) != 1:
            raise StormConfigError(
                f"requested session {requested_session_id!r} is not exactly one live session"
            )
        selected = matches[0]
    elif len(sessions) == 1:
        selected = sessions[0]
    else:
        raise StormConfigError("locked target needs an explicit session id")

    session_id = selected.get("session_id")
    editor_pid = selected.get("editor_pid")
    project_path = selected.get("project_path")
    if not isinstance(session_id, str) or not session_id:
        raise StormConfigError("selected session has no valid session_id")
    if not isinstance(editor_pid, int) or isinstance(editor_pid, bool) or editor_pid <= 0:
        raise StormConfigError(f"selected session {session_id!r} has no valid editor_pid")
    if not isinstance(project_path, str) or not project_path:
        raise StormConfigError(f"selected session {session_id!r} has no valid project_path")
    try:
        actual_path = canonical_project_path(project_path)
        expected_path = canonical_project_path(expected_project_path)
    except (OSError, RuntimeError) as error:
        raise StormConfigError(f"cannot resolve selected session project path: {error}") from error
    if actual_path != expected_path:
        raise StormConfigError(
            f"selected session {session_id!r} project {actual_path!r} does not match "
            f"qualification project {expected_path!r}"
        )
    return dict(selected)


def select_replacement_session(
    sessions: Any,
    *,
    expected_project_path: str | Path,
    editor_pid: int,
    previous_session_id: str,
) -> dict[str, Any] | None:
    """Find exactly one new session for the immutable editor identity.

    No match is transient while a plugin reload is in flight. More than one is
    ambiguous and fails closed.
    """

    if not isinstance(sessions, list) or not all(isinstance(row, dict) for row in sessions):
        raise StormConfigError("session_manage returned a malformed session list")
    expected_path = canonical_project_path(expected_project_path)
    matches: list[dict[str, Any]] = []
    for row in sessions:
        session_id = row.get("session_id")
        project_path = row.get("project_path")
        if session_id == previous_session_id or row.get("editor_pid") != editor_pid:
            continue
        if not isinstance(session_id, str) or not session_id or not isinstance(project_path, str):
            continue
        try:
            actual_path = canonical_project_path(project_path)
        except (OSError, RuntimeError):
            continue
        if actual_path == expected_path:
            matches.append(row)
    if len(matches) > 1:
        raise StormConfigError(
            f"editor {editor_pid} published {len(matches)} replacement sessions for "
            f"{expected_path}; expected exactly one"
        )
    return dict(matches[0]) if matches else None


def select_identity_session(
    sessions: Any,
    *,
    expected_project_path: str | Path,
    editor_pid: int,
) -> dict[str, Any]:
    """Select exactly one session for an already-proven editor identity."""

    replacement = select_replacement_session(
        sessions,
        expected_project_path=expected_project_path,
        editor_pid=editor_pid,
        previous_session_id="",
    )
    if replacement is None:
        raise StormConfigError(
            f"editor {editor_pid} has no live session for "
            f"{canonical_project_path(expected_project_path)}"
        )
    return replacement


def _canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def canonical_sha256(value: Any) -> str:
    return hashlib.sha256(_canonical(value).encode()).hexdigest()


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise StormConfigError(f"cannot load {path}: {error}") from error


def worker_rng(seed: int, target_id: str, worker: int, stream: str) -> random.Random:
    """Return an independent RNG whose seed is stable across Python processes."""
    material = f"stormtest-v1\0{seed}\0{target_id}\0{worker}\0{stream}"
    digest = hashlib.sha256(material.encode()).digest()
    return random.Random(int.from_bytes(digest[:16], "big"))


def percentile(values: list[float], percent: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = round(percent / 100 * (len(ordered) - 1))
    return ordered[max(0, min(len(ordered) - 1, index))]


def latency_stats(values: list[float]) -> dict[str, float | int]:
    if not values:
        return {"n": 0}
    return {
        "n": len(values),
        "min": round(min(values), 1),
        "p50": round(percentile(values, 50), 1),
        "p95": round(percentile(values, 95), 1),
        "p99": round(percentile(values, 99), 1),
        "max": round(max(values), 1),
        "avg": round(sum(values) / len(values), 1),
    }


def tool_domain(tool: str) -> str:
    if tool.endswith("_manage"):
        return tool.removesuffix("_manage")
    return tool.split("_", 1)[0]


def coverage_report(calls: dict[str, int], required: list[str]) -> dict[str, Any]:
    domains = sorted(set(calls) | set(required))
    return {
        "required_domains": sorted(required),
        "covered_domain_count": sum(bool(calls.get(domain)) for domain in required),
        "required_domain_count": len(required),
        "calls": {domain: int(calls.get(domain, 0)) for domain in domains},
    }


def error_disposition(code: str, *, reload_window_open: bool) -> str:
    """Classify a tool error for the locked acceptance contract.

    Reload churn may transiently sever transport or reject editor work, but
    only for the affected target while its explicit reload window is open.
    Everything else is unexpected, including state-drift errors such as
    ``NODE_NOT_FOUND``.
    """

    if reload_window_open and code in TOLERATED_RELOAD_ERRORS:
        return "tolerated_reload_transient"
    return "unexpected"


def profile_call_count(profile: dict[str, Any]) -> int:
    count = math.prod(
        int(profile[field])
        for field in ("editors", "workers_per_editor", "waves", "calls_per_worker_wave")
    )
    if profile["reload_enabled"] and profile["reload_replaces_wave"]:
        reloads = (int(profile["waves"]) - 1) // int(profile["reload_every"])
        count -= int(profile["editors"]) * reloads * int(profile["calls_per_worker_wave"])
    return count


def normalize_profile(profile_id: str, raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise StormConfigError(f"profile {profile_id!r} must be an object")
    result: dict[str, Any] = {"id": profile_id}
    for field in ("editors", "workers_per_editor", "waves", "calls_per_worker_wave"):
        value = raw.get(field)
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
            raise StormConfigError(f"profile {profile_id!r} {field} must be a positive integer")
        result[field] = value
    for field, default in (("reload_enabled", False), ("reload_replaces_wave", False)):
        value = raw.get(field, default)
        if not isinstance(value, bool):
            raise StormConfigError(f"profile {profile_id!r} {field} must be boolean")
        result[field] = value
    every = raw.get("reload_every", 0)
    if not isinstance(every, int) or every < 0 or (result["reload_enabled"] and every == 0):
        raise StormConfigError(f"profile {profile_id!r} has invalid reload_every")
    result["reload_every"] = every
    fraction = raw.get("session_pin_fraction", 0.0)
    if (
        not isinstance(fraction, (int, float))
        or isinstance(fraction, bool)
        or not 0 <= fraction <= 1
    ):
        raise StormConfigError(f"profile {profile_id!r} session_pin_fraction must be 0..1")
    reload_mode = str(raw.get("reload_mode", "concurrent"))
    if reload_mode not in {"concurrent", "isolated"}:
        raise StormConfigError(f"profile {profile_id!r} has invalid reload_mode")
    result.update(reload_mode=reload_mode, session_pin_fraction=float(fraction))
    expected = profile_call_count(result)
    if raw.get("calls_per_seed", expected) != expected:
        raise StormConfigError(f"profile {profile_id!r} calls_per_seed must be {expected}")
    result["calls_per_seed"] = expected
    return result


def load_profile_config(path: Path) -> dict[str, Any]:
    config = _read_json(path)
    if not isinstance(config, dict) or config.get("schema_version") != 1:
        raise StormConfigError(f"{path} must use profile schema_version 1")
    if tuple(config.get("seeds", ())) != APPROVED_SEEDS:
        raise StormConfigError(f"{path} must declare seeds {APPROVED_SEEDS}")
    profiles = config.get("profiles")
    if not isinstance(profiles, dict) or set(profiles) != LOCKED_PROFILES:
        raise StormConfigError(f"{path} must define exactly {sorted(LOCKED_PROFILES)}")
    for profile_id, profile in profiles.items():
        normalize_profile(profile_id, profile)
    if not isinstance(config.get("thresholds"), dict) or not isinstance(
        config.get("profile_thresholds", {}), dict
    ):
        raise StormConfigError(f"{path} thresholds must be an object")
    return config


def validate_locked_qualification_thresholds(config: dict[str, Any], profile_id: str) -> None:
    """Refuse a qualification profile until every declared baseline gate is resolved."""

    if profile_id not in LOCKED_PROFILES:
        raise StormConfigError(f"{profile_id!r} is not a locked profile")
    unresolved = config.get("unresolved_baseline_fields")
    if not isinstance(unresolved, list) or any(
        not isinstance(field, str) or not field.strip() for field in unresolved
    ):
        raise StormConfigError(
            "locked qualification requires unresolved_baseline_fields to be an explicit array"
        )
    if unresolved:
        raise StormConfigError(
            "locked qualification baseline gates remain unresolved: "
            + "; ".join(field.strip() for field in unresolved)
        )

    thresholds = dict(config.get("thresholds", {}))
    profile_thresholds = config.get("profile_thresholds", {}).get(profile_id, {})
    if not isinstance(profile_thresholds, dict):
        raise StormConfigError(f"locked profile {profile_id!r} thresholds must be an object")
    thresholds.update(profile_thresholds)

    def validate_caps(label: str, caps: Any) -> None:
        if not isinstance(caps, dict):
            raise StormConfigError(f"locked qualification requires {label} p95/p99 ceilings")
        values: dict[str, float] = {}
        for metric in ("p95", "p99"):
            value = caps.get(metric)
            if (
                not isinstance(value, (int, float))
                or isinstance(value, bool)
                or not math.isfinite(value)
                or value <= 0
            ):
                raise StormConfigError(
                    f"locked qualification requires a positive finite {label} {metric} ceiling"
                )
            values[metric] = float(value)
        if values["p99"] < values["p95"]:
            raise StormConfigError(f"locked qualification {label} p99 ceiling must be at least p95")

    validate_caps("overall latency", thresholds.get("overall_latency_ms"))
    per_operation = thresholds.get("per_operation_latency_ms")
    if not isinstance(per_operation, dict) or not per_operation:
        raise StormConfigError(
            "locked qualification requires non-empty per-operation latency ceilings"
        )
    required_operations = thresholds.get("required_operation_labels")
    if (
        not isinstance(required_operations, list)
        or not required_operations
        or any(not isinstance(operation, str) or not operation for operation in required_operations)
        or len(set(required_operations)) != len(required_operations)
    ):
        raise StormConfigError(
            "locked qualification requires distinct non-empty required operation labels"
        )
    for operation, caps in per_operation.items():
        if not isinstance(operation, str) or not operation:
            raise StormConfigError(
                "locked qualification per-operation latency names must be non-empty strings"
            )
        validate_caps(f"operation {operation!r} latency", caps)
    missing = sorted(set(required_operations) - set(per_operation))
    extra = sorted(set(per_operation) - set(required_operations))
    if missing or extra:
        raise StormConfigError(
            "locked qualification per-operation ceilings differ from the required labels: "
            f"missing={missing}, extra={extra}"
        )


def load_thresholds(path: Path) -> dict[str, Any]:
    value = _read_json(path)
    if not isinstance(value, dict):
        raise StormConfigError(f"{path} thresholds must be an object")
    return value


def parse_target_specs(specs: list[str]) -> list[dict[str, str]]:
    """Parse repeatable ``NAME=URL[,SESSION_ID]`` routes."""
    targets: list[dict[str, str]] = []
    for spec in specs:
        name, separator, route = spec.partition("=")
        url, has_session, session = route.partition(",")
        target = {
            "id": name.strip(),
            "url": url.strip(),
            "session_id": session.strip() if has_session else "",
        }
        if not separator or not target["id"] or not target["url"]:
            raise StormConfigError(f"target {spec!r} must be NAME=URL[,SESSION_ID]")
        if target["id"] in {item["id"] for item in targets}:
            raise StormConfigError(f"duplicate target id {target['id']!r}")
        targets.append(target)
    return targets


def validate_locked_target_ids(profile_id: str, target_ids: list[str]) -> None:
    """Reject CLI naming that would change a locked profile's RNG schedule."""

    expected = LOCKED_TARGET_IDS.get(profile_id)
    if expected is None:
        raise StormConfigError(f"{profile_id!r} is not a locked profile")
    if tuple(target_ids) != expected:
        raise StormConfigError(
            f"locked profile {profile_id!r} requires canonical target ids {list(expected)!r}"
        )


def generate_trace(
    *,
    profile: dict[str, Any],
    seed: int,
    weighted_operations: list[str],
    target_ids: list[str],
) -> dict[str, Any]:
    """Build the compact ``[worker,wave,call,operation,pinned]`` schedule."""
    profile = normalize_profile(str(profile.get("id", "custom")), profile)
    if len(target_ids) != profile["editors"] or len(set(target_ids)) != len(target_ids):
        raise StormConfigError(f"profile {profile['id']!r} needs unique target ids")
    if not weighted_operations:
        raise StormConfigError("weighted operation catalog must not be empty")
    operations = sorted(set(weighted_operations))
    operation_index = {name: index for index, name in enumerate(operations)}
    workers: list[dict[str, Any]] = []
    entries: list[list[int]] = []
    for target_id in target_ids:
        for local_worker in range(profile["workers_per_editor"]):
            worker = len(workers)
            workers.append({"worker": worker, "target_id": target_id, "local_worker": local_worker})
            slots = [
                (wave, call)
                for wave in range(profile["waves"])
                if not (
                    local_worker == 0
                    and profile["reload_enabled"]
                    and profile["reload_replaces_wave"]
                    and wave > 0
                    and wave % profile["reload_every"] == 0
                )
                for call in range(profile["calls_per_worker_wave"])
            ]
            pin_rng = worker_rng(seed, target_id, local_worker, "session-pin")
            pin_count = math.ceil(len(slots) * profile["session_pin_fraction"])
            pinned = set(pin_rng.sample(range(len(slots)), pin_count))
            operation_rng = worker_rng(seed, target_id, local_worker, "operation")
            entries.extend(
                [
                    worker,
                    wave,
                    call,
                    operation_index[operation_rng.choice(weighted_operations)],
                    int(slot in pinned),
                ]
                for slot, (wave, call) in enumerate(slots)
            )
    core = {
        "schema_version": 1,
        "seed": seed,
        "profile": profile,
        "operations": operations,
        "workers": workers,
        "entries": entries,
    }
    return {
        **core,
        "trace_sha256": hashlib.sha256(_canonical(core).encode()).hexdigest(),
    }


def validate_canonical_trace(
    trace: dict[str, Any],
    *,
    profile: dict[str, Any],
    seed: int,
    weighted_operations: list[str],
    target_ids: list[str],
) -> None:
    """Reject a validly re-signed replay that changes the locked schedule."""

    canonical = generate_trace(
        profile=profile,
        seed=seed,
        weighted_operations=weighted_operations,
        target_ids=target_ids,
    )
    if trace != canonical:
        raise StormConfigError("locked replay trace differs from the canonical generated schedule")


def _validate_trace(trace: Any) -> dict[str, Any]:
    if not isinstance(trace, dict) or trace.get("schema_version") != 1:
        raise StormConfigError("trace must use schema_version 1")
    core = {key: value for key, value in trace.items() if key != "trace_sha256"}
    if trace.get("trace_sha256") != hashlib.sha256(_canonical(core).encode()).hexdigest():
        raise StormConfigError("trace digest mismatch")
    try:
        profile = normalize_profile(trace["profile"]["id"], trace["profile"])
        worker_ids = [worker["worker"] for worker in trace["workers"]]
        valid = (
            len(set(worker_ids)) == len(worker_ids)
            and len(worker_ids) == profile["editors"] * profile["workers_per_editor"]
            and len(trace["entries"]) == profile_call_count(profile)
            and all(
                isinstance(entry, list)
                and len(entry) == 5
                and entry[0] in worker_ids
                and all(isinstance(value, int) for value in entry)
                and 0 <= entry[3] < len(trace["operations"])
                and entry[4] in (0, 1)
                for entry in trace["entries"]
            )
        )
    except (KeyError, TypeError):
        valid = False
    if not valid:
        raise StormConfigError("trace structure does not match its profile")
    return trace


def save_trace(path: Path, trace: dict[str, Any]) -> None:
    _validate_trace(trace)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(_canonical(trace) + "\n", encoding="utf-8")


def load_trace(path: Path) -> dict[str, Any]:
    return _validate_trace(_read_json(path))


def trace_entries_by_worker(trace: dict[str, Any]) -> dict[int, list[list[int]]]:
    grouped = {worker["worker"]: [] for worker in trace["workers"]}
    for entry in trace["entries"]:
        grouped[entry[0]].append(entry)
    return grouped


def evaluate_contract(report: dict[str, Any], thresholds: dict[str, Any]) -> list[str]:
    """Return every acceptance failure; an empty list passes."""
    failures: list[str] = []
    if report.get("baseline_measurement"):
        failures.append("baseline measurement is not qualification")
    maximum_errors = thresholds.get("unexpected_errors")
    errors = int(report.get("unexpected_errors", report.get("err", 0)))
    if maximum_errors is not None and errors > int(maximum_errors):
        failures.append(f"unexpected_errors {errors} > {maximum_errors}")

    if thresholds.get("require_not_aborted") and bool(report.get("aborted", False)):
        failures.append("run aborted")
    if thresholds.get("require_live_at_end") and bool(report.get("stopped", True)):
        failures.append("target not live at end")
    if thresholds.get("require_cleanup_complete") and not bool(
        report.get("cleanup_complete", False)
    ):
        failures.append("qualification cleanup incomplete")
    expected_scheduled = thresholds.get("expected_scheduled_operations")
    if expected_scheduled is not None:
        actual_scheduled = int(report.get("scheduled_operations", 0))
        if actual_scheduled != int(expected_scheduled):
            failures.append(f"scheduled_operations {actual_scheduled} != {int(expected_scheduled)}")
    expected_reloads = thresholds.get("expected_reload_attempts")
    attempted = int(report.get("reloads_attempted", 0))
    if expected_reloads is not None and attempted != int(expected_reloads):
        failures.append(f"reloads_attempted {attempted} != {int(expected_reloads)}")

    minimum_calls = thresholds.get("minimum_calls_per_supported_domain")
    minimum_by_domain = thresholds.get("minimum_calls_by_domain", {})
    domain_calls = report.get("per_domain", {}).get("calls", {})
    for domain in thresholds.get("required_domains", []):
        minimum = minimum_by_domain.get(domain, minimum_calls)
        if minimum is None:
            continue
        actual = int(domain_calls.get(domain, 0))
        if actual < int(minimum):
            failures.append(f"domain {domain} calls {actual} < {minimum}")

    def check_caps(label: str, stats: dict[str, Any], caps: dict[str, Any]) -> None:
        for metric in ("p95", "p99"):
            if metric in caps and metric in stats and float(stats[metric]) > float(caps[metric]):
                failures.append(f"{label} {metric} {stats[metric]} > {caps[metric]}")

    check_caps(
        "overall latency",
        report.get("overall_latency_ms", {}),
        thresholds.get("overall_latency_ms", {}),
    )
    measured_operations = set(report.get("per_op", {}))
    required_operations = set(thresholds.get("required_operation_labels", []))
    if required_operations:
        missing = sorted(required_operations - measured_operations)
        extra = sorted(measured_operations - required_operations)
        if missing or extra:
            failures.append(
                "measured operation labels differ from the required labels: "
                f"missing={missing}, extra={extra}"
            )
    for operation, caps in thresholds.get("per_operation_latency_ms", {}).items():
        if operation not in report.get("per_op", {}):
            failures.append(f"operation {operation} has no measurements")
        else:
            check_caps(
                f"operation {operation}",
                report["per_op"][operation].get("latency_ms", {}),
                caps,
            )

    survival = thresholds.get("required_reload_survival_percent")
    if attempted and survival is not None:
        actual = 100 * int(report.get("reloads_survived", 0)) / attempted
        if actual < float(survival):
            failures.append(f"reload survival {actual:.1f}% < {float(survival):.1f}%")
    recovery = [float(value) for value in report.get("reload_recovery_s", [])]
    for metric, actual in (("p95", percentile(recovery, 95)), ("max", max(recovery, default=0))):
        cap = thresholds.get(f"recovery_{metric}_seconds")
        if recovery and cap is not None and actual > float(cap):
            failures.append(f"reload recovery {metric} {actual:.1f}s > {cap}s")
    minimum_pin = thresholds.get("minimum_session_pinned_fraction")
    actual_pin = float(report.get("routing", {}).get("session_pinned_fraction", 0))
    if minimum_pin is not None and actual_pin < float(minimum_pin):
        failures.append(f"session-pinned fraction {actual_pin:.3f} < {float(minimum_pin):.3f}")
    return failures


def threshold_exit_code(failures: list[str]) -> int:
    return int(bool(failures))
