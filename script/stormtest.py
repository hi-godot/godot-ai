#!/usr/bin/env python3
"""stormtest — godot-ai concurrency / reload stress harness.

Many concurrent MCP clients fire rapid, randomized tool calls across every
domain against a live Godot editor, with periodic `editor_reload_plugin`
churn thrown in mid-run. The point is not that every call succeeds — it is to
see whether the editor + plugin + WebSocket dispatcher survive sustained
concurrent abuse (and reload cycles) without crashing, and to surface latency
and error hot-spots per tool.

Each worker is its own MCP connection. Legacy runs follow the active session;
locked runs prove an explicit endpoint/project/editor identity, and the
multi-editor profile session-pins every scheduled operation. Writes are
namespaced per-worker (`<root>/wN/...`). Disk artifacts land under
res://_stormtest/ in each target project.

Reads dominate the op mix (like real traffic); writes exercise most domains.
Locked input-map coverage is read-only so project.godot remains unchanged.
A full JSON snapshot is flushed to stormtest_report.json every few seconds so
a crash or kill still leaves analyzable data (latency p50/p95/p99/max + per-op
error codes).

Run against a running editor whose MCP server is on :8000 (use `python` with
the venv active, or the venv interpreter directly — same on every OS):

    python script/stormtest.py

Knobs (all env-overridable):
    SS_WORKERS   parallel client connections           (default 8)
    SS_WAVES     waves per worker                       (default 5)
    SS_CALLS     calls per worker per wave              (default 25)
    SS_RELOAD    1=include reload churn, 0=skip         (default 1)
    SS_RELOAD_EVERY       chaos worker reloads every N waves  (default 2)
    SS_RELOAD_MODE        concurrent | isolated          (default concurrent)
    SS_ISOLATED_ITERS     reloads in isolated mode       (default 10)
    SS_RECONNECT_TIMEOUT  seconds to wait for the server to return (default 30)
    SS_URL       target MCP endpoint  (default http://127.0.0.1:8000/mcp)

Locked runs use --profile, --seed, --target, --qualification-project, and
optionally --trace-out or --replay-trace. See
docs/verification/storm-profiles-v1.json.

    Default ≈ 1000 calls.  Brutal: SS_WORKERS=12 SS_WAVES=30 (≈ 9000 calls).
    Reads-only smoke: SS_RELOAD=0.
    Windows-friendly reload survival check: SS_RELOAD_MODE=isolated.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

# Re-exec into the project's .venv so a bare `python script/stormtest.py` works
# on every OS without first activating the venv — the third-party imports below
# resolve there. No-op when already in the venv, when there's no venv, or when
# SS_NO_REEXEC is set. See #509.
PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _dev_env import reexec_into_venv  # noqa: E402

reexec_into_venv(guard_env="GODOT_AI_STORMTEST_REEXEC", opt_out_env="SS_NO_REEXEC")
sys.path.insert(0, str(PROJECT_ROOT / "src"))

import asyncio  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
import random  # noqa: E402
import shutil  # noqa: E402
import signal  # noqa: E402
import tempfile  # noqa: E402
import time  # noqa: E402
from collections import Counter, defaultdict  # noqa: E402
from contextlib import asynccontextmanager  # noqa: E402

from _transport_auth import authorization_header  # noqa: E402
from fastmcp import Client  # noqa: E402
from fastmcp.client.transports import StreamableHttpTransport  # noqa: E402
from stormtest_support import (  # noqa: E402
    DISPOSABLE_MARKER,
    DISPOSABLE_MARKER_TOKEN,
    LOCKED_PROFILES,
    SCRATCH_DIRECTORY,
    TOLERATED_RELOAD_ERRORS,
    StormConfigError,
    canonical_project_path,
    canonical_sha256,
    coverage_report,
    error_disposition,
    evaluate_contract,
    generate_trace,
    latency_stats,
    load_profile_config,
    load_thresholds,
    load_trace,
    normalize_profile,
    parse_qualification_project_specs,
    parse_target_specs,
    pinned_session_identity,
    project_tree_drift,
    project_tree_inventory,
    save_trace,
    select_identity_session,
    select_initial_session,
    select_replacement_session,
    threshold_exit_code,
    tool_domain,
    trace_entries_by_worker,
    transport_exception_code,
    validate_canonical_trace,
    validate_locked_qualification_thresholds,
    validate_locked_target_ids,
    worker_rng,
)

DEFAULT_PROFILE_CONFIG = PROJECT_ROOT / "docs" / "verification" / "storm-profiles-v1.json"


def _mcp_client(url: str) -> Client:
    """Build one authenticated client from the current private record."""

    transport = StreamableHttpTransport(
        url,
        headers={"Authorization": authorization_header(url)},
    )
    return Client(transport, timeout=CALL_TIMEOUT, init_timeout=CALL_TIMEOUT)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, help="deterministic run seed (locked: 41001-41003)")
    parser.add_argument("--profile", help="steady, reload-churn, or multi-editor")
    parser.add_argument(
        "--config",
        type=Path,
        default=Path(os.environ.get("SS_CONFIG", DEFAULT_PROFILE_CONFIG)),
        help="profile/threshold JSON",
    )
    parser.add_argument(
        "--thresholds",
        type=Path,
        help="additional threshold JSON (exploratory/non-locked runs only)",
    )
    parser.add_argument("--trace-out", type=Path, help="retain the generated operation trace")
    parser.add_argument("--replay-trace", type=Path, help="replay an existing operation trace")
    parser.add_argument(
        "--target",
        action="append",
        default=[],
        metavar="NAME=URL[,SESSION_ID]",
        help="repeat for each real editor endpoint/session route",
    )
    parser.add_argument(
        "--qualification-project",
        action="append",
        default=[],
        metavar="NAME=/ABSOLUTE/PROJECT",
        help=(
            "locked profiles only: bind each target to a disposable project carrying "
            f"the {DISPOSABLE_MARKER} marker"
        ),
    )
    return parser.parse_args()


ARGS = _parse_args()
CONFIG_ERROR: str | None = None
PROFILE_CONFIG: dict = {}
REPLAY_TRACE: dict | None = None
try:
    if ARGS.replay_trace:
        REPLAY_TRACE = load_trace(ARGS.replay_trace)
    requested_profile = ARGS.profile or os.environ.get("SS_PROFILE", "").strip()
    replay_profile = str(REPLAY_TRACE["profile"]["id"]) if REPLAY_TRACE else ""
    if requested_profile and requested_profile not in LOCKED_PROFILES:
        raise StormConfigError(
            f"unknown profile {requested_profile!r}; choose from "
            f"{', '.join(sorted(LOCKED_PROFILES))}"
        )
    if requested_profile and replay_profile and requested_profile != replay_profile:
        raise StormConfigError(
            f"--profile {requested_profile!r} conflicts with replay trace profile "
            f"{replay_profile!r}"
        )
    if (requested_profile or replay_profile) in LOCKED_PROFILES:
        if ARGS.config.resolve() != DEFAULT_PROFILE_CONFIG.resolve():
            raise StormConfigError(
                "locked profiles require docs/verification/storm-profiles-v1.json"
            )
        PROFILE_CONFIG = load_profile_config(ARGS.config)
        validate_locked_qualification_thresholds(
            PROFILE_CONFIG, requested_profile or replay_profile
        )
except StormConfigError as error:
    CONFIG_ERROR = str(error)


URL = os.environ.get("SS_URL", "http://127.0.0.1:8000/mcp")
try:
    if ARGS.target:
        TARGETS = parse_target_specs(ARGS.target)
    else:
        TARGETS = [{"id": "default", "url": URL, "session_id": ""}]
except StormConfigError as error:
    CONFIG_ERROR = CONFIG_ERROR or str(error)
    TARGETS = [{"id": "default", "url": URL, "session_id": ""}]


PROFILE_ID = ARGS.profile or os.environ.get("SS_PROFILE", "").strip()
if REPLAY_TRACE is not None:
    PROFILE = REPLAY_TRACE["profile"]
    PROFILE_ID = PROFILE["id"]
elif PROFILE_ID and PROFILE_CONFIG and PROFILE_ID in PROFILE_CONFIG["profiles"]:
    PROFILE = normalize_profile(PROFILE_ID, PROFILE_CONFIG["profiles"][PROFILE_ID])
else:
    legacy_workers = int(os.environ.get("SS_WORKERS", "8"))
    legacy_waves = int(os.environ.get("SS_WAVES", "5"))
    legacy_calls = int(os.environ.get("SS_CALLS", "25"))
    legacy_reload = os.environ.get("SS_RELOAD", "1") != "0"
    legacy_reload_every = int(os.environ.get("SS_RELOAD_EVERY", "2"))
    PROFILE = normalize_profile(
        "legacy-default",
        {
            "editors": 1,
            "workers_per_editor": legacy_workers,
            "waves": legacy_waves,
            "calls_per_worker_wave": legacy_calls,
            "reload_enabled": legacy_reload,
            "reload_every": legacy_reload_every if legacy_reload else 0,
            # Preserve the old chaos-worker behavior outside locked profiles.
            "reload_replaces_wave": True,
            "reload_mode": os.environ.get("SS_RELOAD_MODE", "concurrent").strip().lower(),
            "session_pin_fraction": 0.0,
        },
    )

IS_LOCKED = PROFILE_ID in LOCKED_PROFILES
if IS_LOCKED and PROFILE_CONFIG:
    canonical_profile = normalize_profile(PROFILE_ID, PROFILE_CONFIG["profiles"][PROFILE_ID])
    if PROFILE != canonical_profile:
        CONFIG_ERROR = CONFIG_ERROR or (
            f"replay/profile body for {PROFILE_ID!r} differs from the canonical locked profile"
        )

WORKERS_PER_EDITOR = int(PROFILE["workers_per_editor"])
WORKERS = int(PROFILE["editors"]) * WORKERS_PER_EDITOR
WAVES = int(PROFILE["waves"])
CALLS_PER_WAVE = int(PROFILE["calls_per_worker_wave"])
RELOAD_ENABLED = bool(PROFILE["reload_enabled"])
RELOAD_EVERY = int(PROFILE["reload_every"])
RELOAD_REPLACES_WAVE = bool(PROFILE["reload_replaces_wave"])
requested_reload_mode = os.environ.get("SS_RELOAD_MODE", PROFILE["reload_mode"]).strip().lower()
if IS_LOCKED and requested_reload_mode != PROFILE["reload_mode"]:
    CONFIG_ERROR = CONFIG_ERROR or "locked profiles do not allow SS_RELOAD_MODE overrides"
RELOAD_MODE = str(PROFILE["reload_mode"]) if IS_LOCKED else requested_reload_mode

if REPLAY_TRACE is not None:
    RUN_SEED = int(REPLAY_TRACE["seed"])
    if ARGS.seed is not None and ARGS.seed != RUN_SEED:
        CONFIG_ERROR = CONFIG_ERROR or (
            f"--seed {ARGS.seed} conflicts with replay trace seed {RUN_SEED}"
        )
elif ARGS.seed is not None:
    RUN_SEED = ARGS.seed
elif os.environ.get("SS_SEED"):
    RUN_SEED = int(os.environ["SS_SEED"])
else:
    # Legacy invocations remain randomized, but the chosen seed is printed and
    # can be retained/replayed instead of being irreproducible.
    RUN_SEED = random.SystemRandom().randrange(0, 2**63)
if IS_LOCKED and RUN_SEED not in PROFILE_CONFIG.get("seeds", []):
    CONFIG_ERROR = CONFIG_ERROR or (
        f"locked profile seed {RUN_SEED} is not one of {PROFILE_CONFIG.get('seeds', [])}"
    )

TRACE_OUT = ARGS.trace_out or (
    Path(os.environ["SS_TRACE_OUT"]) if os.environ.get("SS_TRACE_OUT") else None
)
THRESHOLDS: dict = {}
if PROFILE_ID and PROFILE_CONFIG:
    THRESHOLDS.update(PROFILE_CONFIG.get("thresholds", {}))
    THRESHOLDS.update(PROFILE_CONFIG.get("profile_thresholds", {}).get(PROFILE_ID, {}))
try:
    threshold_path = ARGS.thresholds or (
        Path(os.environ["SS_THRESHOLDS"]) if os.environ.get("SS_THRESHOLDS") else None
    )
    if threshold_path:
        if IS_LOCKED:
            raise StormConfigError("locked profiles do not allow threshold overrides")
        THRESHOLDS.update(load_thresholds(threshold_path))
except StormConfigError as error:
    CONFIG_ERROR = CONFIG_ERROR or str(error)

if IS_LOCKED:
    reload_attempts = 0
    if PROFILE["reload_enabled"]:
        reload_attempts = int(PROFILE["editors"]) * (
            (int(PROFILE["waves"]) - 1) // int(PROFILE["reload_every"])
        )
    THRESHOLDS.update(
        expected_reload_attempts=reload_attempts,
        expected_scheduled_operations=int(PROFILE["calls_per_seed"]),
        require_cleanup_complete=True,
        require_live_at_end=True,
        require_not_aborted=True,
    )

PROFILE_CONFIG_SHA256 = canonical_sha256(PROFILE_CONFIG) if PROFILE_CONFIG else ""
THRESHOLDS_SHA256 = canonical_sha256(THRESHOLDS) if THRESHOLDS else ""

expected_target_ids = []
if REPLAY_TRACE is not None:
    expected_target_ids = list(
        dict.fromkeys(worker["target_id"] for worker in REPLAY_TRACE["workers"])
    )
    if len(TARGETS) == 1 and TARGETS[0]["id"] == "default" and len(expected_target_ids) == 1:
        TARGETS[0]["id"] = expected_target_ids[0]
else:
    expected_target_ids = [target["id"] for target in TARGETS]
if len(TARGETS) != int(PROFILE["editors"]):
    CONFIG_ERROR = CONFIG_ERROR or (
        f"profile {PROFILE_ID or PROFILE['id']!r} needs {PROFILE['editors']} --target routes, "
        f"got {len(TARGETS)}"
    )
if expected_target_ids and [target["id"] for target in TARGETS] != expected_target_ids:
    CONFIG_ERROR = CONFIG_ERROR or (
        f"target ids {[target['id'] for target in TARGETS]!r} do not match trace "
        f"targets {expected_target_ids!r}"
    )
if IS_LOCKED:
    try:
        validate_locked_target_ids(PROFILE_ID, [target["id"] for target in TARGETS])
    except StormConfigError as error:
        CONFIG_ERROR = CONFIG_ERROR or str(error)
if float(PROFILE["session_pin_fraction"]) > 0 and any(
    not target["session_id"] for target in TARGETS
):
    CONFIG_ERROR = CONFIG_ERROR or (
        f"profile {PROFILE['id']!r} requires session ids on every --target route"
    )

QUALIFICATION_PROJECTS: dict[str, Path] = {}
try:
    if IS_LOCKED:
        QUALIFICATION_PROJECTS = parse_qualification_project_specs(ARGS.qualification_project)
        target_ids = {target["id"] for target in TARGETS}
        if set(QUALIFICATION_PROJECTS) != target_ids:
            raise StormConfigError(
                "locked profiles require exactly one --qualification-project binding "
                f"for each target {sorted(target_ids)}; got "
                f"{sorted(QUALIFICATION_PROJECTS)}"
            )
    elif ARGS.qualification_project:
        raise StormConfigError("--qualification-project is only valid with a locked profile")
except StormConfigError as error:
    CONFIG_ERROR = CONFIG_ERROR or str(error)


def _positive_timeout(name: str, default: float) -> float:
    try:
        value = float(os.environ.get(name, str(default)))
    except ValueError as error:
        raise StormConfigError(f"{name} must be a positive finite number") from error
    if not math.isfinite(value) or value <= 0:
        raise StormConfigError(f"{name} must be a positive finite number")
    return value


try:
    RECONNECT_TIMEOUT = _positive_timeout("SS_RECONNECT_TIMEOUT", 30)
    CALL_TIMEOUT = _positive_timeout("SS_CALL_TIMEOUT", 20)
    CLOSE_TIMEOUT = _positive_timeout("SS_CLOSE_TIMEOUT", 5)
except StormConfigError as error:
    CONFIG_ERROR = CONFIG_ERROR or str(error)
    RECONNECT_TIMEOUT, CALL_TIMEOUT, CLOSE_TIMEOUT = 30.0, 20.0, 5.0
# Per-call ceiling. A plugin reload severs the connection the response would
# return on, so without this the reload call (and any in-flight call) hangs
# forever and wedges the whole run. On timeout we treat it as a CONNECTION
# failure and reconnect.
# Reload mode. "concurrent" (default) = the chaos worker reloads mid-run while
# N workers keep hammering. "isolated" = a single-threaded reload→reconnect→
# verify loop with no concurrent load. It distinguishes reload correctness from
# concurrency pressure and gives a clean survived-N/N number on every platform.
ISOLATED_ITERS = int(os.environ.get("SS_ISOLATED_ITERS", "10"))
# Hard ceiling on client teardown. On Windows a dead server's socket may not
# get a prompt RST, so a graceful close can hang; cap it so teardown can never
# wedge the loop (the concrete stall behind #513).

SCRATCH_DIR = "res://_stormtest"
SCRATCH_SCENE = f"{SCRATCH_DIR}/storm.tscn"

# ---------------------------------------------------------------------------
# global metrics (single event loop -> no lock needed)
# ---------------------------------------------------------------------------
M = {
    "calls": 0,
    "ok": 0,
    "err": 0,
    "unexpected_errors": 0,
    "tolerated_reload_transient_errors": 0,
    "by_op_ok": Counter(),
    "by_op_err": Counter(),
    "err_codes": Counter(),
    "reloads_attempted": 0,
    "reloads_survived": 0,
    "reconnects": 0,
    "scheduled_operations": 0,
    "session_pinned_calls": 0,
    "session_unpinned_calls": 0,
    "reload_recovery_s": [],  # wall-clock to reconnect after each reload
}
LAT = defaultdict(list)  # op_label -> [durations in ms]
ERR_BY_OP = defaultdict(Counter)  # op_label -> Counter(code -> n)
DOMAIN_CALLS = Counter()
ERROR_DISPOSITIONS = Counter()
RELOAD_WINDOWS = {target["id"]: False for target in TARGETS}
REPORT_JSON = os.environ.get(
    "SS_REPORT", os.path.join(tempfile.gettempdir(), "stormtest_report.json")
)
START = [0.0]
STOP = [False]  # set by signal handler / fatal server loss / normal teardown
# ABORTED distinguishes an early failure abort from STOP being set by the
# normal end-of-run teardown (the `finally` in main). Only the former should
# print "aborted — see reason above"; a clean run also has STOP set.
ABORTED = [False]
ROOT_PATHS = {target["id"]: "/Root" for target in TARGETS}
TRACE = [REPLAY_TRACE]
TRACE_BY_WORKER: dict[int, list[list[int]]] = {}
TARGET_READY = {target["id"]: asyncio.Event() for target in TARGETS}
TARGET_REPINNED = {target["id"]: asyncio.Event() for target in TARGETS}
TARGET_ROTATION_LOCKS = {target["id"]: asyncio.Lock() for target in TARGETS}
TARGET_ACTIVE_CALLS = Counter({target["id"]: 0 for target in TARGETS})
TARGET_GENERATIONS = Counter({target["id"]: 0 for target in TARGETS})
TARGET_RELOAD_EPOCHS = Counter({target["id"]: 0 for target in TARGETS})
TARGET_IDENTITIES: dict[str, dict] = {}
QUALIFICATION_BASELINES: dict[str, dict[str, str]] = {}
QUALIFICATION_EVIDENCE: dict[str, dict] = {}
SCRATCH_OWNED = {target["id"]: False for target in TARGETS}
CLEANUP_COMPLETE = [not IS_LOCKED]
for _target_ready in TARGET_READY.values():
    _target_ready.set()
for _target_repinned in TARGET_REPINNED.values():
    _target_repinned.set()


def _abort(reason: str) -> None:
    """Flip STOP + ABORTED and log why. Every early-exit failure path routes
    through here so a truncated run always states its cause (#634)."""
    print(f"  !!! stormtest aborting: {reason}")
    STOP[0] = True
    ABORTED[0] = True


def _sessions_from_result(result) -> list[dict]:
    data = getattr(result, "data", None)
    sessions = data.get("sessions") if isinstance(data, dict) else None
    if not isinstance(sessions, list):
        raise StormConfigError("session_manage returned no sessions list")
    return sessions


def _record_admin_error(code: str, label: str) -> None:
    """Make qualification-control errors visible to the locked contract."""

    M["err"] += 1
    M["unexpected_errors"] += 1
    M["err_codes"][code] += 1
    M["by_op_err"][label] += 1
    ERR_BY_OP[label][code] += 1
    ERROR_DISPOSITIONS["unexpected"] += 1


def _lat_stats(vals: list[float]) -> dict:
    return latency_stats(vals)


def flush_report_json():
    """Persist a full snapshot so a kill/crash still leaves analyzable data."""
    elapsed = max(1e-6, time.monotonic() - START[0]) if START[0] else 0.0
    all_lat = [d for v in LAT.values() for d in v]
    routed_calls = M["session_pinned_calls"] + M["session_unpinned_calls"]
    snap = {
        "profile": PROFILE["id"],
        "seed": RUN_SEED,
        "trace_sha256": TRACE[0]["trace_sha256"] if TRACE[0] else None,
        "profile_config_sha256": PROFILE_CONFIG_SHA256,
        "effective_thresholds_sha256": THRESHOLDS_SHA256,
        "effective_thresholds": THRESHOLDS,
        "elapsed_s": round(elapsed, 1),
        "calls": M["calls"],
        "scheduled_operations": M["scheduled_operations"],
        "ok": M["ok"],
        "err": M["err"],
        "unexpected_errors": M["unexpected_errors"],
        "tolerated_reload_transient_errors": M["tolerated_reload_transient_errors"],
        "error_dispositions": dict(ERROR_DISPOSITIONS),
        "throughput_cps": round(M["calls"] / elapsed, 1) if elapsed else 0,
        "reloads_attempted": M["reloads_attempted"],
        "reloads_survived": M["reloads_survived"],
        "reload_recovery_s": [round(x, 1) for x in M["reload_recovery_s"]],
        "reconnects": M["reconnects"],
        "stopped": STOP[0],
        "aborted": ABORTED[0],
        "cleanup_complete": CLEANUP_COMPLETE[0],
        "qualification": QUALIFICATION_EVIDENCE if IS_LOCKED else None,
        "overall_latency_ms": _lat_stats(all_lat),
        "err_codes": dict(M["err_codes"].most_common()),
        "per_domain": coverage_report(DOMAIN_CALLS, list(THRESHOLDS.get("required_domains", []))),
        "routing": {
            "targets": [target["id"] for target in TARGETS],
            "session_pinned_calls": M["session_pinned_calls"],
            "session_unpinned_calls": M["session_unpinned_calls"],
            "session_pinned_fraction": (
                round(M["session_pinned_calls"] / routed_calls, 6) if routed_calls else 0.0
            ),
        },
        "per_op": {
            op: {
                "ok": M["by_op_ok"][op],
                "err": M["by_op_err"][op],
                "latency_ms": _lat_stats(LAT.get(op, [])),
                "errs": dict(ERR_BY_OP[op].most_common()),
            }
            for op in sorted(set(M["by_op_ok"]) | set(M["by_op_err"]))
        },
    }
    snap["contract_failures"] = evaluate_contract(snap, THRESHOLDS) if THRESHOLDS else []
    tmp = REPORT_JSON + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(snap, f, indent=2)
    os.replace(tmp, REPORT_JSON)
    return snap


def _err_code(exc: Exception) -> str:
    """Best-effort extraction of a godot/MCP error code from an exception."""
    transport_code = transport_exception_code(exc)
    if transport_code:
        return transport_code
    data = getattr(exc, "data", None)
    if isinstance(data, dict):
        code = data.get("code") or data.get("error_code")
        if code:
            return str(code)
    msg = str(exc)
    for token in (
        "EDITOR_NOT_READY",
        "NODE_NOT_FOUND",
        "INVALID_PARAMS",
        "MISSING_REQUIRED_PARAM",
        "WRONG_TYPE",
        "VALUE_OUT_OF_RANGE",
        "ALREADY_EXISTS",
        "NOT_FOUND",
        "SESSION",
    ):
        if token in msg:
            return token
    if isinstance(exc, (ConnectionError, OSError, asyncio.TimeoutError)):
        return "CONNECTION"
    if "connect" in msg.lower() or "closed" in msg.lower() or "transport" in msg.lower():
        return "CONNECTION"
    return type(exc).__name__


async def _hard_close(client) -> None:
    """Close a client without ever hanging the loop. A graceful __aexit__ can
    stall on Windows when the peer server died mid-reload (the socket gets no
    prompt RST), so bound it with a timeout and swallow everything. See #513."""
    if client is None:
        return
    try:
        await asyncio.wait_for(client.__aexit__(None, None, None), timeout=CLOSE_TIMEOUT)
    except (Exception, asyncio.TimeoutError, asyncio.CancelledError):
        pass


async def _open_client(url: str) -> Client:
    """Open a client within the same deadline used for every tool call."""

    client = _mcp_client(url)
    try:
        async with asyncio.timeout(CALL_TIMEOUT):
            await client.__aenter__()
        return client
    except BaseException:
        await _hard_close(client)
        raise


@asynccontextmanager
async def _bounded_client(url: str):
    """Open and close a client under the harness's explicit deadlines."""

    client = await _open_client(url)
    try:
        yield client
    finally:
        await _hard_close(client)


async def _cancel_and_join(tasks: list[asyncio.Task]) -> bool:
    """Cancel tasks and prove they stopped before any destructive cleanup."""

    for task in tasks:
        task.cancel()
    if not tasks:
        return True
    _done, pending = await asyncio.wait(tasks, timeout=CALL_TIMEOUT + CLOSE_TIMEOUT)
    return not pending


class Worker:
    def __init__(self, wi: int, target: dict[str, str], local_worker: int):
        self.wi = wi
        self.target = target
        self.local_worker = local_worker
        self.seq = 0
        self.client: Client | None = None
        self.nodes: list[str] = []  # node paths this worker created
        self.scripts: list[str] = []  # res:// .gd paths this worker created
        self.generation = TARGET_GENERATIONS[target["id"]]
        self.container_generation = -1
        self.is_chaos = local_worker == 0
        self.rng = worker_rng(RUN_SEED, target["id"], local_worker, "payload")
        self.list_domain_cursor = worker_rng(
            RUN_SEED, target["id"], local_worker, "list-domain"
        ).randrange(6)
        # Administrative setup is always routed to an explicitly named
        # session. Only locked qualification profiles can intentionally vary
        # routing; an exploratory explicit target must never become unpinned.
        self.session_pinned = bool(target["session_id"])

    @property
    def base(self) -> str:
        return f"{ROOT_PATHS[self.target['id']]}/w{self.local_worker}"

    def routed(self, params: dict, *, force_session: bool = False) -> dict:
        routed = dict(params)
        if self.target["session_id"] and (force_session or self.session_pinned):
            routed["session_id"] = self.target["session_id"]
        return routed

    def nid(self) -> str:
        self.seq += 1
        return f"n{self.local_worker}_{self.seq}"

    async def connect(self) -> bool:
        """(Re)establish this worker's MCP connection. Retries until timeout."""
        if IS_LOCKED or self.target["session_id"]:
            await TARGET_REPINNED[self.target["id"]].wait()
        await _hard_close(self.client)
        self.client = None
        deadline = time.monotonic() + RECONNECT_TIMEOUT
        attempt = 0
        while time.monotonic() < deadline and not STOP[0]:
            attempt += 1
            if IS_LOCKED or self.target["session_id"]:
                await TARGET_REPINNED[self.target["id"]].wait()
            c = None
            try:
                c = await _open_client(self.target["url"])
                async with asyncio.timeout(CALL_TIMEOUT):
                    await c.call_tool("editor_state", self.routed({}, force_session=True))
                self.client = c
                return True
            except Exception as error:
                await _hard_close(c)
                code = _err_code(error)
                if IS_LOCKED and code.startswith("SESSION"):
                    _record_admin_error(code, "qualification.worker_reconnect")
                    _abort(
                        f"target {self.target['id']}: session routing failed during "
                        f"worker {self.wi} reconnect: {code}"
                    )
                    return False
                await asyncio.sleep(min(2.0, 0.2 * attempt))
        return False

    async def call(self, tool: str, params: dict, op_label: str | None = None):
        """Instrumented single tool call. Records metrics, re-raises on failure."""
        target_id = self.target["id"]
        if IS_LOCKED:
            await TARGET_READY[target_id].wait()
        reload_epoch = TARGET_RELOAD_EPOCHS[target_id]
        started_during_reload = RELOAD_WINDOWS[target_id]
        TARGET_ACTIVE_CALLS[target_id] += 1
        label = op_label or tool
        try:
            params = self.routed(params)
            M["calls"] += 1
            DOMAIN_CALLS[tool_domain(tool)] += 1
            if self.target["session_id"] and self.session_pinned:
                M["session_pinned_calls"] += 1
            else:
                M["session_unpinned_calls"] += 1
            t0 = time.perf_counter()
            try:
                async with asyncio.timeout(CALL_TIMEOUT):
                    res = await self.client.call_tool(tool, params)
                LAT[label].append((time.perf_counter() - t0) * 1000.0)
                M["ok"] += 1
                M["by_op_ok"][label] += 1
                return res
            except Exception as exc:  # ToolError, connection errors, timeouts
                LAT[label].append((time.perf_counter() - t0) * 1000.0)
                M["err"] += 1
                M["by_op_err"][label] += 1
                code = _err_code(exc)
                M["err_codes"][code] += 1
                ERR_BY_OP[label][code] += 1
                disposition = error_disposition(
                    code,
                    reload_window_open=(
                        started_during_reload
                        or RELOAD_WINDOWS[target_id]
                        or TARGET_RELOAD_EPOCHS[target_id] != reload_epoch
                    ),
                )
                ERROR_DISPOSITIONS[disposition] += 1
                if disposition == "tolerated_reload_transient":
                    M["tolerated_reload_transient_errors"] += 1
                else:
                    M["unexpected_errors"] += 1
                if IS_LOCKED and code.startswith("SESSION"):
                    _abort(f"target {target_id}: stale or misrouted session during {label}")
                if code == "CONNECTION":
                    raise
                return None
        finally:
            TARGET_ACTIVE_CALLS[target_id] -= 1

    def pick_node(self) -> str | None:
        generation = TARGET_GENERATIONS[self.target["id"]]
        if self.generation != generation:
            self.nodes.clear()
            self.generation = generation
        return self.rng.choice(self.nodes) if self.nodes else None

    async def ensure_container(self):
        """Create this worker's root container under the scene root (idempotent)."""
        generation = TARGET_GENERATIONS[self.target["id"]]
        if self.container_generation == generation:
            return
        result = await self.call(
            "node_create",
            {
                "type": "Node3D",
                "name": f"w{self.local_worker}",
                "parent_path": ROOT_PATHS[self.target["id"]],
            },
            op_label="ensure_container",
        )
        if result is not None:
            self.container_generation = generation


# ---------------------------------------------------------------------------
# operation catalog — each takes a Worker, fires one (or a few) calls
# ---------------------------------------------------------------------------
async def op_editor_state(w: Worker):
    await w.call("editor_state", {})


async def op_hierarchy(w: Worker):
    await w.call(
        "scene_get_hierarchy",
        {"depth": w.rng.randint(1, 6), "limit": w.rng.choice([20, 50, 100])},
    )


async def op_node_find(w: Worker):
    await w.call(
        "node_find",
        {"type": w.rng.choice(["Node3D", "Camera3D", "MeshInstance3D", "Node"])},
    )


async def op_node_props(w: Worker):
    p = w.pick_node()
    if p:
        await w.call("node_get_properties", {"path": p})


async def op_editor_manage(w: Worker):
    # NB: no logs_clear here — a diagnostic storm must not wipe its own evidence
    op = w.rng.choice(["state", "monitors_get", "selection_get"])
    await w.call("editor_manage", {"op": op, "params": {}}, op_label=f"editor_manage.{op}")


async def op_logs(w: Worker):
    await w.call(
        "logs_read",
        {
            "count": w.rng.choice([10, 50]),
            "source": w.rng.choice(["plugin", "editor", "all"]),
        },
    )


async def op_session_list(w: Worker):
    await w.call("session_manage", {"op": "list", "params": {}}, op_label="session_manage.list")


async def op_list_domain(w: Worker):
    options = [
        ("material_manage", "list"),
        ("audio_manage", "list"),
        ("camera_manage", "list"),
        ("input_map_manage", "list"),
        ("scene_manage", "get_roots"),
        ("project_manage", "settings_get"),
    ]
    if IS_LOCKED:
        # Balance the low-frequency rollup domains per worker, independent of
        # concurrency/state-dependent payload branches. Consume the historical
        # payload draw so later deterministic payloads retain their sequence.
        w.rng.randrange(len(options))
        tool, op = options[w.list_domain_cursor % len(options)]
        w.list_domain_cursor += 1
    else:
        tool, op = w.rng.choice(options)
    params = {}
    if op == "settings_get":
        params = {"key": "application/config/name"}
    await w.call(tool, {"op": op, "params": params}, op_label=f"{tool}.{op}")


async def op_search(w: Worker):
    tool, op, params = w.rng.choice(
        [
            (
                "resource_manage",
                "search",
                {"type": w.rng.choice(["Texture2D", "Material", "Resource", "PackedScene"])},
            ),
            (
                "filesystem_manage",
                "search",
                {"name": w.rng.choice([".gd", ".tscn", ".import"])},
            ),
        ]
    )
    await w.call(tool, {"op": op, "params": params}, op_label=f"{tool}.{op}")


async def op_screenshot(w: Worker):
    await w.call(
        "editor_screenshot", {"source": "viewport", "include_image": False, "max_resolution": 320}
    )


# ---- writes (scoped to worker's subtree / scratch dir) ----
async def op_node_create(w: Worker):
    await w.ensure_container()
    name = w.nid()
    # Every tracked node must support the later position mutation. Keep five
    # choices (and therefore the existing payload RNG stream) without plain Node.
    typ = w.rng.choice(["Node3D", "MeshInstance3D", "Marker3D", "Node3D", "Camera3D"])
    res = await w.call("node_create", {"type": typ, "name": name, "parent_path": w.base})
    if res is not None:
        w.nodes.append(f"{w.base}/{name}")
        if len(w.nodes) > 40:
            w.nodes = w.nodes[-40:]


async def op_node_set_prop(w: Worker):
    p = w.pick_node()
    if not p:
        return
    await w.call(
        "node_set_property",
        {
            "path": p,
            "property": "position",
            "value": {
                "x": w.rng.uniform(-9, 9),
                "y": w.rng.uniform(-9, 9),
                "z": w.rng.uniform(-9, 9),
            },
        },
    )


async def op_node_manage(w: Worker):
    p = w.pick_node()
    if not p:
        return
    op = w.rng.choice(
        [
            "add_to_group",
            "duplicate",
            "rename",
            "get_children",
            "get_groups",
            "remove_from_group",
            "move",
        ]
    )
    params = {"path": p}
    if op == "add_to_group" or op == "remove_from_group":
        params["group"] = f"ss_grp_{w.rng.randint(0, 4)}"
    elif op == "duplicate":
        params["name"] = w.nid()
    elif op == "rename":
        params["new_name"] = w.nid()
    elif op == "move":
        params["index"] = min(w.rng.randint(0, 3), len(w.nodes) - 1)
    res = await w.call("node_manage", {"op": op, "params": params}, op_label=f"node_manage.{op}")
    if op == "duplicate" and res is not None:
        w.nodes.append(f"{w.base}/{params['name']}")
    elif op == "rename" and res is not None:
        try:
            index = w.nodes.index(p)
        except ValueError:
            pass
        else:
            parent = p.rsplit("/", 1)[0]
            w.nodes[index] = f"{parent}/{params['new_name']}"


async def op_node_delete(w: Worker):
    # only delete our own, and keep at least a couple around
    if len(w.nodes) < 4:
        return
    p = w.nodes.pop(w.rng.randrange(len(w.nodes)))
    await w.call(
        "node_manage", {"op": "delete", "params": {"path": p}}, op_label="node_manage.delete"
    )


async def op_batch(w: Worker):
    await w.ensure_container()
    cmds = []
    names = []
    for _ in range(w.rng.randint(2, 5)):
        nm = w.nid()
        names.append(nm)
        cmds.append(
            {
                "command": "create_node",
                "params": {"type": "Node3D", "name": nm, "parent_path": w.base},
            }
        )
    res = await w.call("batch_execute", {"commands": cmds, "undo": True}, op_label="batch_execute")
    if res is not None:
        w.nodes.extend(f"{w.base}/{nm}" for nm in names)


async def op_script(w: Worker):
    path = f"{SCRATCH_DIR}/ss_w{w.wi}_{w.nid()}.gd"
    content = f"@tool\nextends Node3D\nvar v := {w.rng.randint(0, 99999)}\nfunc _ready():\n\tpass\n"
    res = await w.call(
        "script_create", {"path": path, "content": content}, op_label="script_create"
    )
    if res is None:
        return
    w.scripts.append(path)
    # patch it
    await w.call(
        "script_patch",
        {"path": path, "old_text": "pass", "new_text": "print(v)"},
        op_label="script_patch",
    )
    await w.call(
        "script_manage", {"op": "read", "params": {"path": path}}, op_label="script_manage.read"
    )
    await w.call(
        "script_manage",
        {"op": "find_symbols", "params": {"path": path}},
        op_label="script_manage.find_symbols",
    )
    # attach to one of our nodes, then detach
    node = w.pick_node()
    if node:
        att = await w.call(
            "script_attach", {"path": node, "script_path": path}, op_label="script_attach"
        )
        if att is not None:
            await w.call(
                "script_manage",
                {"op": "detach", "params": {"path": node}},
                op_label="script_manage.detach",
            )


async def op_resource(w: Worker):
    op = w.rng.choice(
        ["create", "noise_texture_create", "gradient_texture_create", "environment_create"]
    )
    n = w.nid()
    # NB: `resource_path` saves a standalone resource to disk; `path` would be
    # interpreted as a *node* path to assign onto (and fail here).
    if op == "create":
        params = {"type": "FastNoiseLite", "resource_path": f"{SCRATCH_DIR}/ss_res_{w.wi}_{n}.tres"}
    elif op == "noise_texture_create":
        params = {
            "resource_path": f"{SCRATCH_DIR}/ss_noise_{w.wi}_{n}.tres",
            "width": 64,
            "height": 64,
        }
    elif op == "gradient_texture_create":
        params = {
            "resource_path": f"{SCRATCH_DIR}/ss_grad_{w.wi}_{n}.tres",
            "stops": [
                {"offset": 0.0, "color": {"r": 0, "g": 0, "b": 0, "a": 1}},
                {"offset": 1.0, "color": {"r": 1, "g": 1, "b": 1, "a": 1}},
            ],
        }
    else:
        params = {"resource_path": f"{SCRATCH_DIR}/ss_env_{w.wi}_{n}.tres", "preset": "default"}
    await w.call("resource_manage", {"op": op, "params": params}, op_label=f"resource_manage.{op}")


async def op_material(w: Worker):
    n = w.nid()
    path = f"{SCRATCH_DIR}/ss_mat_{w.wi}_{n}.tres"
    res = await w.call(
        "material_manage",
        {"op": "create", "params": {"path": path, "type": "standard"}},
        op_label="material_manage.create",
    )
    if res is not None:
        await w.call(
            "material_manage",
            {
                "op": "set_param",
                "params": {
                    "path": path,
                    "param": "albedo_color",
                    "value": {
                        "r": w.rng.random(),
                        "g": w.rng.random(),
                        "b": w.rng.random(),
                        "a": 1.0,
                    },
                },
            },
            op_label="material_manage.set_param",
        )


async def op_theme(w: Worker):
    n = w.nid()
    path = f"{SCRATCH_DIR}/ss_theme_{w.wi}_{n}.tres"
    res = await w.call(
        "theme_manage", {"op": "create", "params": {"path": path}}, op_label="theme_manage.create"
    )
    if res is not None:
        await w.call(
            "theme_manage",
            {
                "op": "set_color",
                "params": {
                    "theme_path": path,
                    "class_name": "Label",
                    "name": "font_color",
                    "value": {"r": 1, "g": 0, "b": 0, "a": 1},
                },
            },
            op_label="theme_manage.set_color",
        )


async def op_camera(w: Worker):
    await w.ensure_container()
    await w.call(
        "camera_manage",
        {"op": "create", "params": {"parent_path": w.base, "name": f"Cam{w.nid()}", "type": "3d"}},
        op_label="camera_manage.create",
    )


async def op_particle(w: Worker):
    await w.ensure_container()
    name = f"P{w.nid()}"
    res = await w.call(
        "particle_manage",
        {
            "op": "create",
            "params": {"parent_path": w.base, "name": name, "type": "gpu_3d"},
        },
        op_label="particle_manage.create",
    )
    if res is not None:
        # set_process auto-creates a ParticleProcessMaterial in the same undo action.
        # gravity coerces from a {x,y,z} dict (a ParticleProcessMaterial Vector3 prop).
        await w.call(
            "particle_manage",
            {
                "op": "set_process",
                "params": {
                    "node_path": f"{w.base}/{name}",
                    "properties": {"gravity": {"x": 0, "y": -9.8, "z": 0}},
                },
            },
            op_label="particle_manage.set_process",
        )


async def op_audio(w: Worker):
    await w.ensure_container()
    await w.call(
        "audio_manage",
        {
            "op": "player_create",
            "params": {"parent_path": w.base, "name": f"A{w.nid()}", "type": "1d"},
        },
        op_label="audio_manage.player_create",
    )


async def op_animation(w: Worker):
    await w.ensure_container()
    await w.call(
        "animation_manage",
        {"op": "player_create", "params": {"parent_path": w.base, "name": f"AP{w.nid()}"}},
        op_label="animation_manage.player_create",
    )


async def op_input_map(w: Worker):
    action = f"ss_act_{w.wi}_{w.rng.randint(0, 6)}"
    op = w.rng.choice(["add_action", "bind_event", "remove_action", "list"])
    if IS_LOCKED:
        # Input-map writes persist in project.godot. Qualification keeps this
        # domain covered without mutating durable project configuration. Keep
        # the legacy payload RNG draws above so later deterministic payloads do
        # not shift solely because this operation became read-only.
        await w.call(
            "input_map_manage",
            {"op": "list", "params": {}},
            op_label="input_map_manage.list",
        )
        return
    if op == "add_action":
        # The small name pool deliberately repeats. Stress valid mutations;
        # duplicate-add and missing-remove refusals belong to negative tests.
        op = "ensure_action"
        params = {"action": action}
    elif op == "bind_event":
        # ensure the action exists first, else bind_event errors NOT_FOUND
        await w.call(
            "input_map_manage",
            {"op": "ensure_action", "params": {"action": action}},
            op_label="input_map_manage.ensure_action",
        )
        params = {"action": action, "event_type": "key", "keycode": "A"}
    elif op == "remove_action":
        await w.call(
            "input_map_manage",
            {"op": "ensure_action", "params": {"action": action}},
            op_label="input_map_manage.ensure_action",
        )
        params = {"action": action}
    else:
        params = {}
    await w.call(
        "input_map_manage", {"op": op, "params": params}, op_label=f"input_map_manage.{op}"
    )


async def op_signal(w: Worker):
    path = w.pick_node() or ROOT_PATHS[w.target["id"]]
    await w.call(
        "signal_manage",
        {"op": "list", "params": {"path": path}},
        op_label="signal_manage.list",
    )


async def op_filesystem(w: Worker):
    path = f"{SCRATCH_DIR}/ss_w{w.wi}_{w.nid()}.txt"
    res = await w.call(
        "filesystem_manage",
        {"op": "write_text", "params": {"path": path, "content": "storm " * 20}},
        op_label="filesystem_manage.write_text",
    )
    if res is not None:
        await w.call(
            "filesystem_manage",
            {"op": "read_text", "params": {"path": path}},
            op_label="filesystem_manage.read_text",
        )


async def op_scene_save(w: Worker):
    await w.call("scene_save", {})


# weighted op table (reads dominate, like real traffic; writes hit every domain)
OPS = (
    [op_editor_state] * 6
    + [op_hierarchy] * 5
    + [op_node_find] * 4
    + [op_node_props] * 4
    + [op_editor_manage] * 4
    + [op_logs] * 3
    + [op_session_list] * 2
    + [op_list_domain] * 4
    + [op_search] * 3
    + [op_screenshot] * 1
    + [op_node_create] * 6
    + [op_node_set_prop] * 5
    + [op_node_manage] * 5
    + [op_node_delete] * 3
    + [op_batch] * 4
    + [op_script] * 3
    + [op_resource] * 3
    + [op_material] * 3
    + [op_theme] * 2
    + [op_camera] * 2
    + [op_particle] * 2
    + [op_audio] * 2
    + [op_animation] * 2
    + [op_input_map] * 2
    + [op_signal] * 2
    + [op_filesystem] * 2
    + [op_scene_save] * 1
)
OPERATION_BY_NAME = {operation.__name__: operation for operation in OPS}
WEIGHTED_OPERATION_NAMES = [operation.__name__ for operation in OPS]


def prepare_operation_trace() -> None:
    """Generate or validate the retained schedule before touching an editor."""
    if TRACE[0] is None:
        TRACE[0] = generate_trace(
            profile=PROFILE,
            seed=RUN_SEED,
            weighted_operations=WEIGHTED_OPERATION_NAMES,
            target_ids=[target["id"] for target in TARGETS],
        )
    elif IS_LOCKED:
        validate_canonical_trace(
            TRACE[0],
            profile=PROFILE,
            seed=RUN_SEED,
            weighted_operations=WEIGHTED_OPERATION_NAMES,
            target_ids=[target["id"] for target in TARGETS],
        )
    unknown = sorted(set(TRACE[0]["operations"]) - set(OPERATION_BY_NAME))
    if unknown:
        raise StormConfigError(f"trace names operations absent from this harness: {unknown}")
    TRACE_BY_WORKER.clear()
    TRACE_BY_WORKER.update(trace_entries_by_worker(TRACE[0]))
    if TRACE_OUT is not None:
        save_trace(TRACE_OUT, TRACE[0])


async def worker_loop(w: Worker):
    if not await w.connect():
        _abort(
            f"worker {w.wi} could not reach the editor on initial connect — "
            f"is it running with the plugin enabled?"
        )
        return
    try:
        await w.ensure_container()
        entries_by_wave: dict[int, list[list[int]]] = defaultdict(list)
        for entry in TRACE_BY_WORKER[w.wi]:
            entries_by_wave[entry[1]].append(entry)
        for wave in range(WAVES):
            if STOP[0]:
                break
            # chaos worker periodically triggers a plugin reload instead of a burst
            if w.is_chaos and RELOAD_ENABLED and wave > 0 and wave % RELOAD_EVERY == 0:
                await do_reload(w)
                if RELOAD_REPLACES_WAVE:
                    continue
            for entry in entries_by_wave[wave]:
                if STOP[0]:
                    break
                operation_name = TRACE[0]["operations"][entry[3]]
                op = OPERATION_BY_NAME[operation_name]
                w.session_pinned = bool(entry[4]) or (
                    not IS_LOCKED and bool(w.target["session_id"])
                )
                M["scheduled_operations"] += 1
                try:
                    await op(w)
                except Exception as exc:
                    # connection-class failure -> try to reconnect (reload window or crash)
                    code = _err_code(exc)
                    if code == "CONNECTION":
                        M["reconnects"] += 1
                        ok = await w.connect()
                        if not ok:
                            _abort(
                                f"worker {w.wi} reconnect failed after a CONNECTION "
                                f"error (wave {wave}) — server did not return within "
                                f"the reconnect window"
                            )
                            break
                        w.nodes.clear()  # scene may have reset after reload
                        await w.ensure_container()
                    else:
                        M["by_op_err"]["UNCAUGHT"] += 1
            # tiny yield so workers interleave but stay hot
            await asyncio.sleep(0)
    finally:
        await _hard_close(w.client)
        w.client = None


def _requires_single_editor_topology() -> bool:
    return PROFILE_ID in {"steady", "reload-churn"}


def _blocks_workers_during_rotation() -> bool:
    return PROFILE_ID == "multi-editor"


async def _drain_target_calls(target_id: str) -> bool:
    deadline = time.monotonic() + CALL_TIMEOUT
    while TARGET_ACTIVE_CALLS[target_id] and time.monotonic() < deadline:
        await asyncio.sleep(0.01)
    if TARGET_ACTIVE_CALLS[target_id]:
        _record_admin_error("CONNECTION", "qualification.rotation_barrier")
        _abort(
            f"target {target_id}: {TARGET_ACTIVE_CALLS[target_id]} worker calls did not "
            "drain before reload"
        )
        return False
    return True


async def _repin_locked_target(w: Worker, previous_session_id: str) -> bool:
    """Find and prove one replacement for the target's immutable editor."""

    target_id = w.target["id"]
    identity = TARGET_IDENTITIES[target_id]
    await _hard_close(w.client)
    w.client = None
    deadline = time.monotonic() + RECONNECT_TIMEOUT
    attempt = 0
    while time.monotonic() < deadline and not STOP[0]:
        attempt += 1
        candidate_client = None
        try:
            candidate_client = await _open_client(w.target["url"])
            async with asyncio.timeout(CALL_TIMEOUT):
                result = await candidate_client.call_tool(
                    "session_manage", {"op": "list", "params": {}}
                )
            sessions = _sessions_from_result(result)
            if _requires_single_editor_topology() and len(sessions) != 1:
                await _hard_close(candidate_client)
                await asyncio.sleep(min(1.0, 0.1 * attempt))
                continue
            replacement = select_replacement_session(
                sessions,
                expected_project_path=identity["project_path"],
                editor_pid=identity["editor_pid"],
                previous_session_id=previous_session_id,
            )
            if replacement is None:
                await _hard_close(candidate_client)
                await asyncio.sleep(min(1.0, 0.1 * attempt))
                continue
            replacement_id = replacement["session_id"]
            async with asyncio.timeout(CALL_TIMEOUT):
                await candidate_client.call_tool("editor_state", {"session_id": replacement_id})

            # No await between publication and client ownership: all waiting
            # workers observe the new route before the barrier is released.
            w.target["session_id"] = replacement_id
            w.client = candidate_client
            QUALIFICATION_EVIDENCE[target_id]["current_session_id"] = replacement_id
            QUALIFICATION_EVIDENCE[target_id]["repins"].append(
                {
                    "old_session_id": previous_session_id,
                    "new_session_id": replacement_id,
                    "editor_pid": identity["editor_pid"],
                    "project_path": identity["project_path"],
                }
            )
            return True
        except StormConfigError as error:
            await _hard_close(candidate_client)
            _record_admin_error("QUALIFICATION_IDENTITY", "qualification.repin")
            _abort(f"target {target_id}: replacement identity is ambiguous: {error}")
            return False
        except Exception as error:
            await _hard_close(candidate_client)
            code = _err_code(error)
            if code not in TOLERATED_RELOAD_ERRORS:
                _record_admin_error(code, "qualification.repin")
                _abort(f"target {target_id}: replacement-session proof failed: {code}")
                return False
            await asyncio.sleep(min(1.0, 0.1 * attempt))

    _record_admin_error("CONNECTION", "qualification.repin")
    _abort(
        f"target {target_id}: no unique replacement for editor "
        f"{identity['editor_pid']} and project {identity['project_path']} appeared within "
        f"{RECONNECT_TIMEOUT}s"
    )
    return False


async def _recover_locked_scratch(w: Worker) -> bool:
    target_id = w.target["id"]
    try:
        await w.client.call_tool(
            "scene_open", w.routed({"path": SCRATCH_SCENE}, force_session=True)
        )
        state = await w.client.call_tool("editor_state", w.routed({}, force_session=True))
        state_data = getattr(state, "data", None)
        if not isinstance(state_data, dict) or state_data.get("current_scene") != SCRATCH_SCENE:
            current = state_data.get("current_scene") if isinstance(state_data, dict) else None
            raise StormConfigError(f"expected current scene {SCRATCH_SCENE}, got {current!r}")
        await w.client.call_tool(
            "node_create",
            w.routed(
                {
                    "type": "Node3D",
                    "name": f"w{w.local_worker}",
                    "parent_path": ROOT_PATHS[target_id],
                },
                force_session=True,
            ),
        )
    except Exception as error:
        code = _err_code(error)
        _record_admin_error(code, "qualification.scratch_recovery")
        _abort(f"target {target_id}: scratch scene recovery failed: {code}: {error}")
        return False
    TARGET_GENERATIONS[target_id] += 1
    w.nodes.clear()
    w.generation = TARGET_GENERATIONS[target_id]
    w.container_generation = TARGET_GENERATIONS[target_id]
    return True


async def _do_locked_reload(w: Worker) -> None:
    target_id = w.target["id"]
    async with TARGET_ROTATION_LOCKS[target_id]:
        M["reloads_attempted"] += 1
        previous_session = w.target["session_id"]
        ready = TARGET_READY[target_id]
        repinned = TARGET_REPINNED[target_id]
        blocks_workers = _blocks_workers_during_rotation()
        repinned.clear()
        if blocks_workers:
            ready.clear()
        try:
            if blocks_workers and not await _drain_target_calls(target_id):
                return
            TARGET_RELOAD_EPOCHS[target_id] += 1
            RELOAD_WINDOWS[target_id] = True
            t_reload = time.monotonic()
            print(
                "  [chaos] >>> editor_reload_plugin (locked wave) — "
                f"attempt #{M['reloads_attempted']} target={target_id}"
            )
            try:
                async with asyncio.timeout(CALL_TIMEOUT):
                    await w.client.call_tool(
                        "editor_reload_plugin", w.routed({}, force_session=True)
                    )
            except Exception as error:
                code = _err_code(error)
                if code not in TOLERATED_RELOAD_ERRORS:
                    _record_admin_error(code, "qualification.reload")
                    _abort(f"target {target_id}: reload call failed unexpectedly: {code}")
                    return
                print(f"  [chaos] reload handoff: {code}")

            if not await _repin_locked_target(w, previous_session):
                return
            if not await _recover_locked_scratch(w):
                return
            M["reload_recovery_s"].append(time.monotonic() - t_reload)
            M["reloads_survived"] += 1
            print(
                "  [chaos] <<< replacement proven and scratch recovered "
                f"(survived {M['reloads_survived']}/{M['reloads_attempted']})"
            )
        finally:
            RELOAD_WINDOWS[target_id] = False
            repinned.set()
            ready.set()


async def do_reload(w: Worker):
    # An explicit session pin rotates on every plugin reload in exploratory
    # runs too. Use the same immutable project/PID proof; never silently fall
    # back to whichever editor became active on the endpoint.
    if IS_LOCKED or w.target["session_id"]:
        await _do_locked_reload(w)
        return
    M["reloads_attempted"] += 1
    target_id = w.target["id"]
    TARGET_RELOAD_EPOCHS[target_id] += 1
    previous_session = await _active_session_id(w)
    RELOAD_WINDOWS[target_id] = True
    print(f"  [chaos] >>> editor_reload_plugin (wave) — attempt #{M['reloads_attempted']}")
    try:
        # The reload severs this connection, so the response often never comes
        # back — cap the wait, then recover by reconnecting below.
        async with asyncio.timeout(CALL_TIMEOUT):
            await w.client.call_tool("editor_reload_plugin", w.routed({}, force_session=True))
    except Exception as exc:
        print(f"  [chaos] reload call returned/raised: {_err_code(exc)} (expected during handoff)")
    # the reload tears down + re-establishes the session; reconnect this worker
    t_reload = time.monotonic()
    await asyncio.sleep(2.0)
    ok = await w.connect()
    M["reload_recovery_s"].append(time.monotonic() - t_reload)
    if not ok:
        RELOAD_WINDOWS[target_id] = False
        _abort("server or replacement session did not return after a chaos-worker reload")
        return
    replacement_session = await _active_session_id(w)
    if previous_session != "?" and replacement_session == previous_session:
        RELOAD_WINDOWS[target_id] = False
        _abort(f"target {target_id}: reload did not publish a distinct replacement session")
        return
    # Reload may have reset the edited scene. Do not resume workers until the
    # scratch scene is both reopened and observed as current.
    try:
        await w.client.call_tool(
            "scene_open", w.routed({"path": SCRATCH_SCENE}, force_session=True)
        )
        state = await w.client.call_tool("editor_state", w.routed({}, force_session=True))
        state_data = getattr(state, "data", None) or {}
        if state_data.get("current_scene") != SCRATCH_SCENE:
            raise RuntimeError(
                f"expected current scene {SCRATCH_SCENE}, got {state_data.get('current_scene')!r}"
            )
    except Exception as exc:
        RELOAD_WINDOWS[target_id] = False
        _abort(f"target {target_id}: scratch scene did not recover: {_err_code(exc)}")
        return
    w.nodes.clear()
    try:
        await w.ensure_container()
    except Exception as exc:
        RELOAD_WINDOWS[target_id] = False
        _abort(f"target {target_id}: scratch recovery failed after reload: {_err_code(exc)}")
        return
    RELOAD_WINDOWS[target_id] = False
    M["reloads_survived"] += 1
    print(
        f"  [chaos] <<< reconnected after reload "
        f"(survived {M['reloads_survived']}/{M['reloads_attempted']})"
    )


async def _active_session_id(w: Worker) -> str:
    """Best-effort current session id, for confirming a reload rotated it.
    Returns '?' on any hiccup — the survived count is the real signal."""
    try:
        res = await w.client.call_tool("session_manage", {"op": "list", "params": {}})
        data = getattr(res, "data", None) or {}
        sessions = data.get("sessions") or []
        if sessions:
            first = sessions[0]
            return str(first.get("session_id") or first.get("id") or "?")
    except Exception:
        return "?"
    return "?"


async def run_isolated_reload() -> None:
    """Single-threaded reload/reconnect/verify loop with no concurrent load."""
    print(
        f"stormtest [isolated reload]  iters={ISOLATED_ITERS} "
        f"reconnect_timeout={RECONNECT_TIMEOUT}s  url={TARGETS[0]['url']}"
    )
    w = Worker(0, TARGETS[0], 0)
    if not await w.connect():
        _abort("could not reach the editor — is it running with the plugin enabled?")
        return

    for i in range(ISOLATED_ITERS):
        if STOP[0]:
            break
        before = await _active_session_id(w)
        M["reloads_attempted"] += 1
        print(f"  >>> reload #{i + 1}/{ISOLATED_ITERS}  (session before: {before})")
        try:
            async with asyncio.timeout(CALL_TIMEOUT):
                await w.client.call_tool("editor_reload_plugin", w.routed({}, force_session=True))
        except Exception as exc:
            print(f"      reload call returned/raised: {_err_code(exc)} (expected during handoff)")

        # Drop the (now-severed) client without risking a teardown stall, then
        # wait for the disable→extract→enable window before reconnecting.
        await _hard_close(w.client)
        w.client = None
        t0 = time.monotonic()
        await asyncio.sleep(2.0)
        ok = await w.connect()
        dt = time.monotonic() - t0
        if not ok:
            _abort(
                f"editor did not return within {RECONNECT_TIMEOUT}s of an "
                "isolated reload — server or replacement session did not return"
            )
            break
        after = await _active_session_id(w)
        M["reloads_survived"] += 1
        M["reload_recovery_s"].append(dt)
        M["reconnects"] += 1
        print(
            f"      <<< reconnected in {dt:.1f}s  (session after: {after})  "
            f"survived {M['reloads_survived']}/{M['reloads_attempted']}"
        )

    await _hard_close(w.client)
    w.client = None


def _target_params(target: dict[str, str], params: dict) -> dict:
    routed = dict(params)
    if target["session_id"]:
        routed["session_id"] = target["session_id"]
    return routed


async def health_monitor(target: dict[str, str]):
    """Independent heartbeat: if the editor stops answering, flip STOP."""
    misses = 0
    while not STOP[0]:
        await asyncio.sleep(3)
        if IS_LOCKED or target["session_id"]:
            await TARGET_REPINNED[target["id"]].wait()
            if STOP[0]:
                return
        try:
            flush_report_json()
        except Exception:
            pass
        try:
            c = await _open_client(target["url"])
            try:
                async with asyncio.timeout(CALL_TIMEOUT):
                    await c.call_tool("editor_state", _target_params(target, {}))
            finally:
                await _hard_close(c)
            misses = 0
        except Exception:
            misses += 1
            if misses == 1:
                print(f"  [health:{target['id']}] editor not answering (reload window?) ...")
            if misses >= int(RECONNECT_TIMEOUT / 3) + 1:
                _abort(
                    f"health monitor {target['id']}: editor unreachable for ~{misses * 3}s "
                    f"(> reconnect window) — presumed DEAD"
                )
                return


def _validated_original_scene(project_root: Path, current_scene: object) -> str:
    if not isinstance(current_scene, str) or not current_scene.startswith("res://"):
        raise StormConfigError(
            f"locked qualification requires an open saved res:// scene, got {current_scene!r}"
        )
    relative = current_scene.removeprefix("res://")
    if not relative:
        raise StormConfigError("locked qualification original scene path is empty")
    candidate = project_root / relative
    if candidate.is_symlink() or not candidate.is_file():
        raise StormConfigError(
            f"locked qualification original scene is not a regular file: {candidate}"
        )
    resolved = candidate.resolve(strict=True)
    if not resolved.is_relative_to(project_root):
        raise StormConfigError(
            f"locked qualification original scene escapes the project: {current_scene}"
        )
    return current_scene


async def preflight_locked(originals: dict[str, str]) -> None:
    """Prove project authorization, editor identity, topology, and baseline."""

    selected_session_ids: set[str] = set()
    for target in TARGETS:
        target_id = target["id"]
        project_root = QUALIFICATION_PROJECTS[target_id]
        baseline = project_tree_inventory(project_root)
        try:
            async with _bounded_client(target["url"]) as client:
                listing = await client.call_tool("session_manage", {"op": "list", "params": {}})
                selected = select_initial_session(
                    _sessions_from_result(listing),
                    expected_project_path=project_root,
                    requested_session_id=target["session_id"],
                    require_only_session=_requires_single_editor_topology(),
                )
                session_id = selected["session_id"]
                if session_id in selected_session_ids:
                    raise StormConfigError(
                        f"session {session_id!r} is bound to more than one locked target"
                    )
                state = await client.call_tool("editor_state", {"session_id": session_id})
                state_data = getattr(state, "data", None)
                if not isinstance(state_data, dict):
                    raise StormConfigError("editor_state returned malformed qualification data")
                original_scene = _validated_original_scene(
                    project_root, state_data.get("current_scene")
                )
        except StormConfigError:
            raise
        except Exception as error:
            raise StormConfigError(
                f"target {target_id!r} qualification preflight failed: {_err_code(error)}: {error}"
            ) from error

        selected_session_ids.add(session_id)
        target["session_id"] = session_id
        originals[target_id] = original_scene
        canonical_root = canonical_project_path(project_root)
        TARGET_IDENTITIES[target_id] = {
            "editor_pid": selected["editor_pid"],
            "project_path": canonical_root,
        }
        QUALIFICATION_BASELINES[target_id] = baseline
        QUALIFICATION_EVIDENCE[target_id] = {
            "authorized_marker": str(project_root / DISPOSABLE_MARKER),
            "authorized_marker_token": DISPOSABLE_MARKER_TOKEN,
            "project_path": canonical_root,
            "editor_pid": selected["editor_pid"],
            "initial_session_id": session_id,
            "current_session_id": session_id,
            "original_scene": original_scene,
            "topology": (
                "exactly-one-session"
                if _requires_single_editor_topology()
                else "explicit-session-route"
            ),
            "tree_before_sha256": canonical_sha256(baseline),
            "repins": [],
            "cleanup_complete": False,
        }


async def setup(originals: dict[str, str]) -> None:
    print(
        f"stormtest  workers={WORKERS} waves={WAVES} calls/wave={CALLS_PER_WAVE} "
        f"reload={'on' if RELOAD_ENABLED else 'off'} profile={PROFILE['id']} seed={RUN_SEED}"
    )
    print(f"  trace: {TRACE[0]['trace_sha256']} targets={[target['id'] for target in TARGETS]}")
    for target in TARGETS:
        target_id = target["id"]
        async with _bounded_client(target["url"]) as c:
            if not IS_LOCKED and target["session_id"]:
                listing = await c.call_tool("session_manage", {"op": "list", "params": {}})
                selected = pinned_session_identity(
                    _sessions_from_result(listing), target["session_id"]
                )
                TARGET_IDENTITIES[target_id] = selected
                # Routing evidence is useful even without claiming a locked
                # qualification row or inventing a durable-tree baseline.
                QUALIFICATION_EVIDENCE[target_id] = {
                    **selected,
                    "initial_session_id": target["session_id"],
                    "current_session_id": target["session_id"],
                    "repins": [],
                }
            st = (await c.call_tool("editor_state", _target_params(target, {}))).data
            original = st.get("current_scene") or ""
            if IS_LOCKED:
                if original != originals[target_id]:
                    raise StormConfigError(
                        f"target {target_id}: original scene changed between preflight and setup: "
                        f"{original!r} != {originals[target_id]!r}"
                    )
                scratch_path = QUALIFICATION_PROJECTS[target_id] / SCRATCH_DIRECTORY
                scratch_path.mkdir(mode=0o700)
                SCRATCH_OWNED[target_id] = True
            else:
                originals[target_id] = original
            print(f"  [{target_id}] connected. original scene: {original!r}")
            # scratch scene to play in (so we never touch the user's real scene)
            await c.call_tool(
                "scene_manage",
                _target_params(
                    target,
                    {
                        "op": "create",
                        "params": {
                            "path": SCRATCH_SCENE,
                            "root_type": "Node3D",
                            "root_name": "Root",
                        },
                    },
                ),
            )
            await asyncio.sleep(0.4)
            hierarchy = await c.call_tool(
                "scene_get_hierarchy", _target_params(target, {"depth": 1})
            )
            # The hierarchy contract is the paginated node list; the old
            # top-level `root` passthrough never came from the real plugin.
            nodes = hierarchy.data.get("nodes", [])
            root = nodes[0].get("path") if nodes and isinstance(nodes[0], dict) else None
            if root:
                ROOT_PATHS[target_id] = root if str(root).startswith("/") else f"/{root}"
            else:
                raise StormConfigError(f"target {target_id}: scratch scene has no root")
            print(f"  [{target_id}] scratch scene ready, root path = {ROOT_PATHS[target_id]}")
            await c.call_tool("scene_save", _target_params(target, {}))
            if IS_LOCKED:
                verified = await c.call_tool("editor_state", _target_params(target, {}))
                verified_data = getattr(verified, "data", None)
                if (
                    not isinstance(verified_data, dict)
                    or verified_data.get("current_scene") != SCRATCH_SCENE
                ):
                    raise StormConfigError(
                        f"target {target_id}: scratch scene was not observed after setup"
                    )


def _remove_owned_scratch_tree(project_root: Path) -> None:
    """Remove only a plain, in-project scratch tree; reject link/reparse swaps."""

    scratch_path = project_root / SCRATCH_DIRECTORY
    expected_root = os.path.normcase(os.path.abspath(scratch_path))
    try:
        resolved_root = os.path.normcase(str(scratch_path.resolve(strict=True)))
    except (OSError, RuntimeError) as error:
        raise StormConfigError(
            f"cannot resolve owned scratch tree {scratch_path}: {error}"
        ) from error
    if resolved_root != expected_root or scratch_path.is_symlink() or not scratch_path.is_dir():
        raise StormConfigError(
            f"owned scratch path changed type or target; refusing removal: {scratch_path}"
        )
    for current, directories, files in os.walk(scratch_path, topdown=True, followlinks=False):
        for name in [*directories, *files]:
            entry = Path(current) / name
            expected_entry = os.path.normcase(os.path.abspath(entry))
            try:
                resolved_entry = os.path.normcase(str(entry.resolve(strict=True)))
            except (OSError, RuntimeError) as error:
                raise StormConfigError(
                    f"cannot resolve owned scratch entry {entry}: {error}"
                ) from error
            if entry.is_symlink() or resolved_entry != expected_entry:
                raise StormConfigError(
                    f"owned scratch tree contains a link/reparse target; refusing removal: {entry}"
                )
    shutil.rmtree(scratch_path)


async def _prove_locked_target(
    client,
    target: dict[str, str],
    *,
    expected_scene: str | None,
    require_current_session: bool,
) -> dict:
    """Prove one target's identity, topology, route, and optional scene."""

    target_id = target["id"]
    identity = TARGET_IDENTITIES[target_id]
    listing = await client.call_tool("session_manage", {"op": "list", "params": {}})
    sessions = _sessions_from_result(listing)
    if _requires_single_editor_topology() and len(sessions) != 1:
        raise StormConfigError(
            f"target {target_id}: topology has {len(sessions)} sessions, expected 1"
        )
    selected = select_identity_session(
        sessions,
        expected_project_path=identity["project_path"],
        editor_pid=identity["editor_pid"],
    )
    if require_current_session and selected["session_id"] != target["session_id"]:
        raise StormConfigError(
            f"target {target_id}: session rotated outside the controlled reload barrier"
        )
    state = await client.call_tool("editor_state", {"session_id": selected["session_id"]})
    state_data = getattr(state, "data", None)
    current_scene = state_data.get("current_scene") if isinstance(state_data, dict) else None
    if expected_scene is not None and current_scene != expected_scene:
        raise StormConfigError(
            f"target {target_id}: current scene {current_scene!r} != {expected_scene!r}"
        )
    return selected


async def _teardown_locked_target(target: dict[str, str], original: str) -> None:
    target_id = target["id"]
    evidence = QUALIFICATION_EVIDENCE[target_id]
    project_root = QUALIFICATION_PROJECTS[target_id]
    _validated_original_scene(project_root, original)
    async with _bounded_client(target["url"]) as client:
        selected = await _prove_locked_target(
            client,
            target,
            expected_scene=None,
            require_current_session=False,
        )
        target["session_id"] = selected["session_id"]
        evidence["current_session_id"] = selected["session_id"]
        await client.call_tool("scene_open", _target_params(target, {"path": original}))
        await _prove_locked_target(
            client,
            target,
            expected_scene=original,
            require_current_session=True,
        )
        evidence["restored_scene"] = original

    scratch_path = project_root / SCRATCH_DIRECTORY
    if not SCRATCH_OWNED[target_id]:
        if os.path.lexists(scratch_path):
            raise StormConfigError(
                f"target {target_id}: refusing to remove unowned scratch path {scratch_path}"
            )
    else:
        _remove_owned_scratch_tree(project_root)
        SCRATCH_OWNED[target_id] = False

    await asyncio.sleep(0.5)
    after = project_tree_inventory(project_root)
    drift = project_tree_drift(QUALIFICATION_BASELINES[target_id], after)
    evidence["tree_after_sha256"] = canonical_sha256(after)
    evidence["tree_drift"] = drift[:100]
    evidence["tree_drift_count"] = len(drift)
    if drift:
        raise StormConfigError(
            f"target {target_id}: durable project tree drifted: {', '.join(drift[:10])}"
        )
    async with _bounded_client(target["url"]) as client:
        await _prove_locked_target(
            client,
            target,
            expected_scene=original,
            require_current_session=True,
        )
    evidence["cleanup_complete"] = True


async def teardown(originals: dict[str, str]) -> None:
    print("\nteardown: restoring original scene ...")
    if IS_LOCKED:
        clean = True
        for target in TARGETS:
            target_id = target["id"]
            try:
                await _teardown_locked_target(target, originals[target_id])
                print(f"  [{target_id}] original scene restored; scratch removed; tree exact")
            except Exception as error:
                clean = False
                if target_id in QUALIFICATION_EVIDENCE:
                    QUALIFICATION_EVIDENCE[target_id]["cleanup_error"] = str(error)
                _abort(f"target {target_id}: locked cleanup failed: {error}")
        CLEANUP_COMPLETE[0] = clean
        return

    for target in TARGETS:
        original = originals.get(target["id"], "")
        try:
            async with _bounded_client(target["url"]) as c:
                if original:
                    await c.call_tool("scene_open", _target_params(target, {"path": original}))
                print(f"  [{target['id']}] reopened: {original}")
        except Exception as exc:
            print(f"  [{target['id']}] could not reopen original scene: {_err_code(exc)}")


async def final_liveness() -> tuple[bool, str]:
    """Prove the expected target(s), not merely any active editor, are alive."""

    try:
        for target in TARGETS:
            client = await _open_client(target["url"])
            try:
                async with asyncio.timeout(CALL_TIMEOUT):
                    if IS_LOCKED:
                        await _prove_locked_target(
                            client,
                            target,
                            expected_scene=SCRATCH_SCENE,
                            require_current_session=True,
                        )
                    else:
                        await client.call_tool("editor_state", _target_params(target, {}))
            finally:
                await _hard_close(client)
        return True, ""
    except Exception as error:
        return False, str(error)


def report():
    elapsed = max(1e-6, time.monotonic() - START[0])
    print("\n" + "=" * 60)
    print("stormtest REPORT")
    print("=" * 60)
    print(f"  duration         : {elapsed:6.1f}s")
    print(f"  profile / seed   : {PROFILE['id']} / {RUN_SEED}")
    if TRACE[0]:
        print(f"  trace SHA-256    : {TRACE[0]['trace_sha256']}")
    print(f"  scheduled ops    : {M['scheduled_operations']}")
    print(f"  total calls      : {M['calls']}")
    print(f"  throughput       : {M['calls'] / elapsed:6.1f} calls/sec")
    print(f"  ok / err         : {M['ok']} / {M['err']}")
    print(
        f"  errors           : unexpected {M['unexpected_errors']} / "
        f"reload-transient {M['tolerated_reload_transient_errors']}"
    )
    print(
        f"  reloads          : survived {M['reloads_survived']} "
        f"/ attempted {M['reloads_attempted']}"
    )
    if IS_LOCKED:
        print(f"  cleanup / tree   : {'PASS' if CLEANUP_COMPLETE[0] else 'FAIL'}")
    if M["reload_recovery_s"]:
        rr = M["reload_recovery_s"]
        print(
            f"  reload recovery  : {', '.join(f'{x:.1f}s' for x in rr)}  "
            f"(avg {sum(rr) / len(rr):.1f}s)"
        )
    print(f"  reconnects       : {M['reconnects']}")
    all_lat = [d for v in LAT.values() for d in v]
    s = _lat_stats(all_lat)
    if s["n"]:
        print(
            f"  latency (ms)     : p50={s['p50']} p95={s['p95']} "
            f"p99={s['p99']} max={s['max']} avg={s['avg']}"
        )
    # Verdict keys off STOP[0] as it stands at report() time, which is the
    # authoritative end-of-run liveness signal — NOT any prior success. In
    # concurrent mode the final liveness probe in main() sets STOP[0]=False
    # when the editor answers editor_state (True if it can't be reached); in
    # isolated mode STOP[0] is left False unless a path aborted. A mid-run
    # abort that the editor recovered from still reads ALIVE (correct — it is
    # alive now); the ABORTED line below explains any truncation separately.
    verdict = "EDITOR ALIVE" if not STOP[0] else "EDITOR DEAD/UNREACHABLE"
    print(f"  final verdict    : {verdict}")
    if ABORTED[0]:
        print("  (run aborted early — see the 'stormtest aborting:' reason above)")
    print("\n  error codes:")
    for code, n in M["err_codes"].most_common():
        print(f"    {n:6d}  {code}")
    domains = coverage_report(DOMAIN_CALLS, list(THRESHOLDS.get("required_domains", [])))
    print("\n  per-domain calls:")
    for domain, calls in domains["calls"].items():
        print(f"    {calls:6d}  {domain}")
    print("\n  per-op:  ok / err   p50ms / p95ms / p99ms / maxms   [error codes]")
    ops = sorted(set(M["by_op_ok"]) | set(M["by_op_err"]))
    for op in ops:
        ls = _lat_stats(LAT.get(op, []))
        ecs = ""
        if M["by_op_err"][op]:
            ecs = ", ".join(f"{c}:{n}" for c, n in ERR_BY_OP[op].most_common())
        print(
            f"    {M['by_op_ok'][op]:5d} / {M['by_op_err'][op]:<5d}  "
            f"{ls.get('p50', 0):6.0f} / {ls.get('p95', 0):6.0f} / "
            f"{ls.get('p99', 0):6.0f} / {ls.get('max', 0):6.0f}  {op}  {ecs}"
        )
    print("=" * 60)
    try:
        snapshot = flush_report_json()
        print(f"\n  full JSON snapshot: {REPORT_JSON}")
        failures = snapshot["contract_failures"]
        if failures:
            print("\n  CONTRACT FAILED:")
            for failure in failures:
                print(f"    - {failure}")
            return threshold_exit_code(failures)
        if ABORTED[0]:
            return 1
        if THRESHOLDS:
            print("\n  contract thresholds: PASS")
    except Exception as error:
        print(f"\n  could not write/evaluate report: {error}", file=sys.stderr)
        return 2
    return 0


async def main() -> int:
    if CONFIG_ERROR:
        print(f"stormtest configuration error: {CONFIG_ERROR}", file=sys.stderr)
        return 2
    try:
        prepare_operation_trace()
    except StormConfigError as error:
        print(f"stormtest trace error: {error}", file=sys.stderr)
        return 2

    originals: dict[str, str] = {}
    if IS_LOCKED:
        try:
            await preflight_locked(originals)
        except StormConfigError as error:
            print(f"stormtest qualification preflight failed: {error}", file=sys.stderr)
            return 2

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, lambda: STOP.__setitem__(0, True))
        except (NotImplementedError, RuntimeError):
            pass

    # Isolated reload mode: no scratch scene, no concurrent workers — just the
    # single-threaded reload survival loop. Self-contained so it sidesteps the
    # concurrent-churn wedge entirely (#513).
    if RELOAD_MODE == "isolated":
        START[0] = time.monotonic()
        exit_code = 0
        try:
            await run_isolated_reload()
        finally:
            exit_code = report()
        return exit_code

    START[0] = time.monotonic()
    monitors: list[asyncio.Task] = []
    worker_tasks: list[asyncio.Task] = []
    workers_quiesced = True
    exit_code = 0
    try:
        await setup(originals)
        targets_by_id = {target["id"]: target for target in TARGETS}
        workers = [
            Worker(
                record["worker"],
                targets_by_id[record["target_id"]],
                record["local_worker"],
            )
            for record in TRACE[0]["workers"]
        ]
        monitors = [asyncio.create_task(health_monitor(target)) for target in TARGETS]
        worker_tasks = [asyncio.create_task(worker_loop(worker)) for worker in workers]
        try:
            await asyncio.gather(*worker_tasks)
        except BaseException:
            workers_quiesced = await _cancel_and_join(worker_tasks)
            if not workers_quiesced:
                _abort("worker tasks did not quiesce after cancellation")
            raise
    except Exception as error:
        _abort(f"unhandled harness failure: {_err_code(error)}: {error}")
    finally:
        STOP[0] = True
        if not await _cancel_and_join(monitors):
            _abort("health monitors did not quiesce after cancellation")
        workers_quiesced = (
            workers_quiesced
            and all(task.done() for task in worker_tasks)
            and not any(TARGET_ACTIVE_CALLS.values())
        )
        if not workers_quiesced:
            _abort("worker activity remained live; refusing qualification cleanup")
        all_alive, liveness_error = await final_liveness()
        STOP[0] = not all_alive
        if not all_alive:
            _abort(f"final target/topology proof failed: {liveness_error}")
        if workers_quiesced:
            await teardown(originals)
        else:
            CLEANUP_COMPLETE[0] = False
        exit_code = report()
    return exit_code


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
