#!/usr/bin/env python3
"""stormtest — godot-ai concurrency / reload stress harness.

Many concurrent MCP clients fire rapid, randomized tool calls across every
domain against a live Godot editor, with periodic `editor_reload_plugin`
churn thrown in mid-run. The point is not that every call succeeds — it is to
see whether the editor + plugin + WebSocket dispatcher survive sustained
concurrent abuse (and reload cycles) without crashing, and to surface latency
and error hot-spots per tool.

Each worker is its own MCP connection. Workers route to the *active* session
(empty session_id), so when a reload swaps the session id they automatically
follow the new one. Writes are namespaced per-worker (`<root>/wN/...`) so the
workers hammer one shared edited scene without stepping on each other's node
paths. Disk artifacts (scratch scripts / resources / scene) all land under
res://_stormtest/ in whatever project the target editor has open — scratch
material that's safe to delete afterwards.

Reads dominate the op mix (like real traffic); writes exercise every domain.
A full JSON snapshot is flushed to stormtest_report.json every few seconds so
a crash or kill still leaves analyzable data (latency p50/p95/max + per-op
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

    Default ≈ 1000 calls.  Brutal: SS_WORKERS=12 SS_WAVES=30 (≈ 9000 calls).
    Reads-only smoke: SS_RELOAD=0.
    Windows-friendly reload survival check: SS_RELOAD_MODE=isolated.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# Re-exec into the project's .venv so a bare `python script/stormtest.py` works
# on every OS without first activating the venv — the third-party imports below
# resolve there. No-op when already in the venv, when there's no venv, or when
# SS_NO_REEXEC is set. See #509.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from _dev_env import reexec_into_venv  # noqa: E402

reexec_into_venv(guard_env="GODOT_AI_STORMTEST_REEXEC", opt_out_env="SS_NO_REEXEC")

import asyncio  # noqa: E402
import json  # noqa: E402
import random  # noqa: E402
import signal  # noqa: E402
import tempfile  # noqa: E402
import time  # noqa: E402
from collections import Counter, defaultdict  # noqa: E402

from fastmcp import Client  # noqa: E402

URL = os.environ.get("SS_URL", "http://127.0.0.1:8000/mcp")

# ---- knobs (defaults ≈ 1000 calls; override via env) ----
WORKERS = int(os.environ.get("SS_WORKERS", "8"))
WAVES = int(os.environ.get("SS_WAVES", "5"))
CALLS_PER_WAVE = int(os.environ.get("SS_CALLS", "25"))  # per worker, per wave
RELOAD_ENABLED = os.environ.get("SS_RELOAD", "1") != "0"
RELOAD_EVERY = int(os.environ.get("SS_RELOAD_EVERY", "2"))  # chaos worker reloads every N waves
RECONNECT_TIMEOUT = float(os.environ.get("SS_RECONNECT_TIMEOUT", "30"))
# Per-call ceiling. A plugin reload severs the connection the response would
# return on, so without this the reload call (and any in-flight call) hangs
# forever and wedges the whole run. On timeout we treat it as a CONNECTION
# failure and reconnect.
CALL_TIMEOUT = float(os.environ.get("SS_CALL_TIMEOUT", "20"))
# Reload mode. "concurrent" (default) = the chaos worker reloads mid-run while
# N workers keep hammering. "isolated" = a single-threaded reload→reconnect→
# verify loop with no concurrent load — the Windows-friendly survival check,
# since concurrent churn against a plugin-managed server can wedge the asyncio
# loop on Windows (#513). Isolated mode gives a clean survived-N/N number.
RELOAD_MODE = os.environ.get("SS_RELOAD_MODE", "concurrent").strip().lower()
ISOLATED_ITERS = int(os.environ.get("SS_ISOLATED_ITERS", "10"))
# Hard ceiling on client teardown. On Windows a dead server's socket may not
# get a prompt RST, so a graceful close can hang; cap it so teardown can never
# wedge the loop (the concrete stall behind #513).
CLOSE_TIMEOUT = float(os.environ.get("SS_CLOSE_TIMEOUT", "5"))

SCRATCH_DIR = "res://_stormtest"
SCRATCH_SCENE = f"{SCRATCH_DIR}/storm.tscn"

# ---------------------------------------------------------------------------
# global metrics (single event loop -> no lock needed)
# ---------------------------------------------------------------------------
M = {
    "calls": 0,
    "ok": 0,
    "err": 0,
    "by_op_ok": Counter(),
    "by_op_err": Counter(),
    "err_codes": Counter(),
    "reloads_attempted": 0,
    "reloads_survived": 0,
    "reconnects": 0,
    "reload_recovery_s": [],  # wall-clock to reconnect after each reload
}
LAT = defaultdict(list)  # op_label -> [durations in ms]
ERR_BY_OP = defaultdict(Counter)  # op_label -> Counter(code -> n)
REPORT_JSON = os.environ.get(
    "SS_REPORT", os.path.join(tempfile.gettempdir(), "stormtest_report.json")
)
START = [0.0]
STOP = [False]  # set by signal handler / fatal server loss / normal teardown
# ABORTED distinguishes an early failure abort from STOP being set by the
# normal end-of-run teardown (the `finally` in main). Only the former should
# print "aborted — see reason above"; a clean run also has STOP set.
ABORTED = [False]
ROOT_PATH = ["/Root"]  # resolved after scratch-scene creation


def _abort(reason: str) -> None:
    """Flip STOP + ABORTED and log why. Every early-exit failure path routes
    through here so a truncated run always states its cause (#634)."""
    print(f"  !!! stormtest aborting: {reason}")
    STOP[0] = True
    ABORTED[0] = True


def _pct(vals: list[float], p: float) -> float:
    if not vals:
        return 0.0
    s = sorted(vals)
    k = max(0, min(len(s) - 1, int(round((p / 100.0) * (len(s) - 1)))))
    return s[k]


def _lat_stats(vals: list[float]) -> dict:
    if not vals:
        return {"n": 0}
    return {
        "n": len(vals),
        "min": round(min(vals), 1),
        "p50": round(_pct(vals, 50), 1),
        "p95": round(_pct(vals, 95), 1),
        "max": round(max(vals), 1),
        "avg": round(sum(vals) / len(vals), 1),
    }


def flush_report_json():
    """Persist a full snapshot so a kill/crash still leaves analyzable data."""
    elapsed = max(1e-6, time.monotonic() - START[0]) if START[0] else 0.0
    all_lat = [d for v in LAT.values() for d in v]
    snap = {
        "elapsed_s": round(elapsed, 1),
        "calls": M["calls"],
        "ok": M["ok"],
        "err": M["err"],
        "throughput_cps": round(M["calls"] / elapsed, 1) if elapsed else 0,
        "reloads_attempted": M["reloads_attempted"],
        "reloads_survived": M["reloads_survived"],
        "reload_recovery_s": [round(x, 1) for x in M["reload_recovery_s"]],
        "reconnects": M["reconnects"],
        "stopped": STOP[0],
        "aborted": ABORTED[0],
        "overall_latency_ms": _lat_stats(all_lat),
        "err_codes": dict(M["err_codes"].most_common()),
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
    tmp = REPORT_JSON + ".tmp"
    with open(tmp, "w") as f:
        json.dump(snap, f, indent=2)
    os.replace(tmp, REPORT_JSON)


def _err_code(exc: Exception) -> str:
    """Best-effort extraction of a godot/MCP error code from an exception."""
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


class Worker:
    def __init__(self, wi: int):
        self.wi = wi
        self.seq = 0
        self.client: Client | None = None
        self.nodes: list[str] = []  # node paths this worker created
        self.scripts: list[str] = []  # res:// .gd paths this worker created
        self.is_chaos = wi == 0

    @property
    def base(self) -> str:
        return f"{ROOT_PATH[0]}/w{self.wi}"

    def nid(self) -> str:
        self.seq += 1
        return f"n{self.wi}_{self.seq}"

    async def connect(self) -> bool:
        """(Re)establish this worker's MCP connection. Retries until timeout."""
        await _hard_close(self.client)
        self.client = None
        deadline = time.monotonic() + RECONNECT_TIMEOUT
        attempt = 0
        while time.monotonic() < deadline and not STOP[0]:
            attempt += 1
            c = Client(URL)
            try:
                await c.__aenter__()
                await c.call_tool("editor_state", {})
                self.client = c
                return True
            except Exception:
                await _hard_close(c)
                await asyncio.sleep(min(2.0, 0.2 * attempt))
        return False

    async def call(self, tool: str, params: dict, op_label: str | None = None):
        """Instrumented single tool call. Records metrics, re-raises on failure."""
        label = op_label or tool
        M["calls"] += 1
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
            if code == "CONNECTION":
                raise
            return None

    def pick_node(self) -> str | None:
        return random.choice(self.nodes) if self.nodes else None

    async def ensure_container(self):
        """Create this worker's root container under the scene root (idempotent)."""
        await self.call(
            "node_create",
            {"type": "Node3D", "name": f"w{self.wi}", "parent_path": ROOT_PATH[0]},
            op_label="ensure_container",
        )


# ---------------------------------------------------------------------------
# operation catalog — each takes a Worker, fires one (or a few) calls
# ---------------------------------------------------------------------------
async def op_editor_state(w: Worker):
    await w.call("editor_state", {})


async def op_hierarchy(w: Worker):
    await w.call(
        "scene_get_hierarchy",
        {"depth": random.randint(1, 6), "limit": random.choice([20, 50, 100])},
    )


async def op_node_find(w: Worker):
    await w.call(
        "node_find",
        {"type": random.choice(["Node3D", "Camera3D", "MeshInstance3D", "Node"])},
    )


async def op_node_props(w: Worker):
    p = w.pick_node()
    if p:
        await w.call("node_get_properties", {"path": p})


async def op_editor_manage(w: Worker):
    # NB: no logs_clear here — a diagnostic storm must not wipe its own evidence
    op = random.choice(["state", "monitors_get", "selection_get"])
    await w.call("editor_manage", {"op": op, "params": {}}, op_label=f"editor_manage.{op}")


async def op_logs(w: Worker):
    await w.call(
        "logs_read",
        {
            "count": random.choice([10, 50]),
            "source": random.choice(["plugin", "editor", "all"]),
        },
    )


async def op_session_list(w: Worker):
    await w.call("session_manage", {"op": "list", "params": {}}, op_label="session_manage.list")


async def op_list_domain(w: Worker):
    tool, op = random.choice(
        [
            ("material_manage", "list"),
            ("audio_manage", "list"),
            ("camera_manage", "list"),
            ("input_map_manage", "list"),
            ("scene_manage", "get_roots"),
            ("project_manage", "settings_get"),
        ]
    )
    params = {}
    if op == "settings_get":
        params = {"key": "application/config/name"}
    await w.call(tool, {"op": op, "params": params}, op_label=f"{tool}.{op}")


async def op_search(w: Worker):
    tool, op, params = random.choice(
        [
            (
                "resource_manage",
                "search",
                {"type": random.choice(["Texture2D", "Material", "Resource", "PackedScene"])},
            ),
            ("filesystem_manage", "search", {"name": random.choice([".gd", ".tscn", ".import"])}),
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
    typ = random.choice(["Node3D", "MeshInstance3D", "Marker3D", "Node", "Camera3D"])
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
                "x": random.uniform(-9, 9),
                "y": random.uniform(-9, 9),
                "z": random.uniform(-9, 9),
            },
        },
    )


async def op_node_manage(w: Worker):
    p = w.pick_node()
    if not p:
        return
    op = random.choice(
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
        params["group"] = f"ss_grp_{random.randint(0, 4)}"
    elif op == "duplicate":
        params["name"] = w.nid()
    elif op == "rename":
        params["new_name"] = w.nid()
    elif op == "move":
        params["index"] = random.randint(0, 3)
    res = await w.call("node_manage", {"op": op, "params": params}, op_label=f"node_manage.{op}")
    if op == "duplicate" and res is not None:
        w.nodes.append(f"{w.base}/{params['name']}")


async def op_node_delete(w: Worker):
    # only delete our own, and keep at least a couple around
    if len(w.nodes) < 4:
        return
    p = w.nodes.pop(random.randrange(len(w.nodes)))
    await w.call(
        "node_manage", {"op": "delete", "params": {"path": p}}, op_label="node_manage.delete"
    )


async def op_batch(w: Worker):
    await w.ensure_container()
    cmds = []
    names = []
    for _ in range(random.randint(2, 5)):
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
    content = (
        f"@tool\nextends Node3D\nvar v := {random.randint(0, 99999)}\nfunc _ready():\n\tpass\n"
    )
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
    op = random.choice(
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
                        "r": random.random(),
                        "g": random.random(),
                        "b": random.random(),
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
    action = f"ss_act_{w.wi}_{random.randint(0, 6)}"
    op = random.choice(["add_action", "bind_event", "remove_action", "list"])
    if op == "add_action":
        params = {"action": action}
    elif op == "bind_event":
        # ensure the action exists first, else bind_event errors NOT_FOUND
        await w.call(
            "input_map_manage",
            {"op": "add_action", "params": {"action": action}},
            op_label="input_map_manage.add_action",
        )
        params = {"action": action, "event_type": "key", "keycode": "A"}
    elif op == "remove_action":
        params = {"action": action}
    else:
        params = {}
    await w.call(
        "input_map_manage", {"op": op, "params": params}, op_label=f"input_map_manage.{op}"
    )


async def op_signal(w: Worker):
    p = w.pick_node()
    if p:
        await w.call(
            "signal_manage", {"op": "list", "params": {"path": p}}, op_label="signal_manage.list"
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


async def worker_loop(w: Worker):
    if not await w.connect():
        _abort(
            f"worker {w.wi} could not reach the editor on initial connect — "
            f"is it running with the plugin enabled?"
        )
        return
    await w.ensure_container()
    for wave in range(WAVES):
        if STOP[0]:
            break
        # chaos worker periodically triggers a plugin reload instead of a burst
        if w.is_chaos and RELOAD_ENABLED and wave > 0 and wave % RELOAD_EVERY == 0:
            await do_reload(w)
            continue
        for _ in range(CALLS_PER_WAVE):
            if STOP[0]:
                break
            op = random.choice(OPS)
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
    await _hard_close(w.client)
    w.client = None


async def do_reload(w: Worker):
    M["reloads_attempted"] += 1
    print(f"  [chaos] >>> editor_reload_plugin (wave) — attempt #{M['reloads_attempted']}")
    try:
        # The reload severs this connection, so the response often never comes
        # back — cap the wait, then recover by reconnecting below.
        async with asyncio.timeout(CALL_TIMEOUT):
            await w.client.call_tool("editor_reload_plugin", {})
    except Exception as exc:
        print(f"  [chaos] reload call returned/raised: {_err_code(exc)} (expected during handoff)")
    # the reload tears down + re-establishes the session; reconnect this worker
    t_reload = time.monotonic()
    await asyncio.sleep(2.0)
    ok = await w.connect()
    M["reload_recovery_s"].append(time.monotonic() - t_reload)
    if not ok:
        _abort(
            "server did not come back after a chaos-worker reload "
            "(managed server likely killed by the reload)"
        )
        return
    M["reloads_survived"] += 1
    # reload may have reset the edited scene off our scratch scene — reopen it
    try:
        await w.client.call_tool("scene_open", {"path": SCRATCH_SCENE})
    except Exception:
        pass
    w.nodes.clear()
    await w.ensure_container()
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
    """Single-threaded reload→reconnect→verify loop (#513). No concurrent load,
    so it can't hit the Windows concurrent-churn wedge — it yields a clean
    survived-N/N number and per-reload recovery time. This is the documented
    Windows path for validating reload survival."""
    print(
        f"stormtest [isolated reload]  iters={ISOLATED_ITERS} "
        f"reconnect_timeout={RECONNECT_TIMEOUT}s  url={URL}"
    )
    w = Worker(0)
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
                await w.client.call_tool("editor_reload_plugin", {})
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
                f"isolated reload — reload NOT survived (managed server likely "
                f"killed by the reload)"
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


async def health_monitor():
    """Independent heartbeat: if the editor stops answering, flip STOP."""
    misses = 0
    while not STOP[0]:
        await asyncio.sleep(3)
        try:
            flush_report_json()
        except Exception:
            pass
        try:
            c = Client(URL)
            await c.__aenter__()
            await c.call_tool("editor_state", {})
            await c.__aexit__(None, None, None)
            misses = 0
        except Exception:
            misses += 1
            if misses == 1:
                print("  [health] editor not answering (reload window?) ...")
            if misses >= int(RECONNECT_TIMEOUT / 3) + 1:
                _abort(
                    f"health monitor: editor unreachable for ~{misses * 3}s "
                    f"(> reconnect window) — presumed DEAD"
                )
                return


async def setup() -> str:
    print(
        f"stormtest  workers={WORKERS} waves={WAVES} calls/wave={CALLS_PER_WAVE} "
        f"reload={'on' if RELOAD_ENABLED else 'off'}"
    )
    async with Client(URL) as c:
        st = (await c.call_tool("editor_state", {})).data
        original = st.get("current_scene") or ""
        print(f"  connected. original scene: {original!r}")
        # scratch scene to play in (so we never touch the user's real scene)
        await c.call_tool(
            "scene_manage",
            {
                "op": "create",
                "params": {"path": SCRATCH_SCENE, "root_type": "Node3D", "root_name": "Root"},
            },
        )
        await asyncio.sleep(0.4)
        h = (await c.call_tool("scene_get_hierarchy", {"depth": 1})).data
        root = h.get("root")
        if root:
            ROOT_PATH[0] = root if str(root).startswith("/") else f"/{root}"
        print(f"  scratch scene ready, root path = {ROOT_PATH[0]}")
        await c.call_tool("scene_save", {})
    return original


async def teardown(original: str):
    print("\nteardown: restoring original scene ...")
    try:
        async with Client(URL) as c:
            if original:
                await c.call_tool("scene_open", {"path": original})
            print("  reopened:", original)
    except Exception as exc:
        print("  (could not reopen original scene:", _err_code(exc), ")")


def report():
    elapsed = max(1e-6, time.monotonic() - START[0])
    print("\n" + "=" * 60)
    print("stormtest REPORT")
    print("=" * 60)
    print(f"  duration         : {elapsed:6.1f}s")
    print(f"  total calls      : {M['calls']}")
    print(f"  throughput       : {M['calls'] / elapsed:6.1f} calls/sec")
    print(f"  ok / err         : {M['ok']} / {M['err']}")
    print(
        f"  reloads          : survived {M['reloads_survived']} "
        f"/ attempted {M['reloads_attempted']}"
    )
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
        print(f"  latency (ms)     : p50={s['p50']} p95={s['p95']} max={s['max']} avg={s['avg']}")
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
    print("\n  per-op:  ok / err   p50ms / p95ms / maxms   [error codes]")
    ops = sorted(set(M["by_op_ok"]) | set(M["by_op_err"]))
    for op in ops:
        ls = _lat_stats(LAT.get(op, []))
        ecs = ""
        if M["by_op_err"][op]:
            ecs = ", ".join(f"{c}:{n}" for c, n in ERR_BY_OP[op].most_common())
        print(
            f"    {M['by_op_ok'][op]:5d} / {M['by_op_err'][op]:<5d}  "
            f"{ls.get('p50', 0):6.0f} / {ls.get('p95', 0):6.0f} / "
            f"{ls.get('max', 0):6.0f}  {op}  {ecs}"
        )
    print("=" * 60)
    try:
        flush_report_json()
        print(f"\n  full JSON snapshot: {REPORT_JSON}")
    except Exception:
        pass


async def main():
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
        try:
            await run_isolated_reload()
        finally:
            report()
        return

    original = await setup()
    START[0] = time.monotonic()

    workers = [Worker(i) for i in range(WORKERS)]
    mon = asyncio.create_task(health_monitor())
    try:
        await asyncio.gather(*(worker_loop(w) for w in workers))
    finally:
        STOP[0] = True
        mon.cancel()
        try:
            await mon
        except (asyncio.CancelledError, Exception):
            pass
        # final liveness check for the verdict
        try:
            async with Client(URL) as c:
                await c.call_tool("editor_state", {})
            STOP[0] = False  # alive
        except Exception:
            pass
        await teardown(original)
        report()


if __name__ == "__main__":
    asyncio.run(main())
