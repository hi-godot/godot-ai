#!/usr/bin/env python3
"""Report the purpose-built source gates approved for Godot AI v4."""

from __future__ import annotations

import argparse
import ast
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

LIFECYCLE_PATH = Path("plugin/addons/godot_ai/utils/server_lifecycle.gd")
UPDATE_MANAGER_PATH = Path("plugin/addons/godot_ai/utils/update_manager.gd")
DOCK_PATH = Path("plugin/addons/godot_ai/mcp_dock.gd")
CLIENT_HANDLER_PATH = Path("plugin/addons/godot_ai/handlers/client_handler.gd")
SESSION_REGISTRY_PATH = Path("src/godot_ai/sessions/registry.py")
WEBSOCKET_PATH = Path("src/godot_ai/transport/websocket.py")
ENVELOPE_PATH = Path("src/godot_ai/protocol/envelope.py")
CONNECTION_PATH = Path("plugin/addons/godot_ai/connection.gd")
RELEASE_VERIFY_PATH = Path("src/godot_ai/release_verify.py")
_CANONICAL_RELEASE_SHAPE = ("godot-ai-v4-plugin.zip", "addons/godot_ai/")
_LIFECYCLE_VARIANT_FIELDS = {
    "_episode",
    "_server_state",
    "_start_in_flight",
    "_recovery_in_flight",
    "_startup_path",
}
_FORBIDDEN_OWNER_FIELDS = {
    UPDATE_MANAGER_PATH: {
        "_client_jobs",
        "_dock",
        "_host",
        "_lifecycle",
        "_plugin",
        "_preflight",
    },
    LIFECYCLE_PATH: {"_dock", "_host", "_plugin", "_update_manager"},
    DOCK_PATH: {"_client_jobs", "_connection", "_host", "_lifecycle", "_plugin", "_update_manager"},
    Path("plugin/addons/godot_ai/utils/client_job_owner.gd"): {
        "_dock",
        "_host",
        "_lifecycle",
        "_plugin",
        "_update_manager",
    },
}

_GDSCRIPT_FIELD_RE = re.compile(
    r"^(?P<static>static\s+)?var\s+(?P<name>[A-Za-z_]\w*)[^\n]*$",
    re.MULTILINE,
)
_HOST_MEMBER_RE = re.compile(r"\b_host\.([A-Za-z_]\w*)")
_MEMBERSHIP_NAME_RE = re.compile(r"(?:session|connection|peer|editor|client)s?", re.I)
_MUTATING_METHODS = frozenset(
    {"add", "append", "clear", "discard", "extend", "pop", "remove", "setdefault", "update"}
)


def _read(root: Path, relative: Path) -> str:
    return (root / relative).read_text(encoding="utf-8")


def _line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def _gdscript_code(source: str) -> str:
    """Discard comment tails for the narrow member-reference scans below."""

    return "\n".join(line.split("#", 1)[0] for line in source.splitlines())


def _gdscript_fields(source: str) -> list[dict[str, Any]]:
    code = _gdscript_code(source)
    return [
        {
            "line": _line_number(code, match.start()),
            "name": match.group("name"),
            "static": match.group("static") is not None,
        }
        for match in _GDSCRIPT_FIELD_RE.finditer(code)
    ]


def _gate(
    definition: str, unit: str, value: int, target: int | None = None, **proof: Any
) -> dict[str, Any]:
    result = {"definition": definition, "unit": unit, "value": value, **proof}
    if target is not None:
        result["target"] = target
    return result


def _lifecycle_host_dependencies(root: Path) -> dict[str, Any]:
    source = _read(root, LIFECYCLE_PATH)
    members = sorted(set(_HOST_MEMBER_RE.findall(_gdscript_code(source))))
    return _gate(
        "unique member names accessed through server_lifecycle.gd `_host.*`",
        "unique_host_members",
        len(members),
        0,
        path=LIFECYCLE_PATH.as_posix(),
        members=members,
    )


def _owner_fields(root: Path, path: Path, names: set[str], definition: str) -> dict[str, Any]:
    fields = [field for field in _gdscript_fields(_read(root, path)) if field["name"] in names]
    return _gate(
        definition,
        "retained_owner_fields",
        len(fields),
        0,
        path=path.as_posix(),
        fields=fields,
    )


def _is_dock_client_worker_field(name: str) -> bool:
    return name in {
        "_refresh_state",
        "_last_client_status_refresh_completed_msec",
    } or name.startswith(
        (
            "_client_status_refresh_",
            "_orphaned_client_status_refresh_",
            "_client_action_",
            "_orphaned_client_action_",
        )
    )


def _dock_client_worker_fields(root: Path) -> dict[str, Any]:
    fields = [
        field
        for field in _gdscript_fields(_read(root, DOCK_PATH))
        if _is_dock_client_worker_field(field["name"])
    ]
    return _gate(
        "Dock fields holding client worker, phase, generation, cancellation, "
        "timing, or orphan state",
        "dock_owned_fields",
        len(fields),
        0,
        path=DOCK_PATH.as_posix(),
        static_store_count=sum(field["static"] for field in fields),
        fields=fields,
    )


def _non_owner_client_thread_spawns(root: Path) -> dict[str, Any]:
    spawns: list[dict[str, Any]] = []
    for path in (DOCK_PATH, CLIENT_HANDLER_PATH):
        code = _gdscript_code(_read(root, path))
        for match in re.finditer(r"\bThread\.new\s*\(", code):
            spawns.append(
                {"path": path.as_posix(), "line": _line_number(code, match.start())}
            )
    return _gate(
        "client-work Thread creation outside the one ClientJobOwner",
        "non_owner_thread_spawns",
        len(spawns),
        0,
        spawns=spawns,
    )


def _self_field(target: ast.expr) -> str | None:
    if (
        isinstance(target, ast.Attribute)
        and isinstance(target.value, ast.Name)
        and target.value.id == "self"
    ):
        return target.attr
    return None


def _class_membership_maps(source: str, *, class_name: str, path: Path) -> list[dict[str, Any]]:
    tree = ast.parse(source, filename=path.as_posix())
    class_node = next(
        (node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == class_name),
        None,
    )
    if class_node is None:
        return []

    found: dict[str, dict[str, Any]] = {}
    for node in ast.walk(class_node):
        if not isinstance(node, ast.AnnAssign):
            continue
        name = _self_field(node.target)
        if name is None or (name != "_entries" and _MEMBERSHIP_NAME_RE.search(name) is None):
            continue
        annotation = node.annotation
        if not (
            isinstance(annotation, ast.Subscript)
            and isinstance(annotation.value, ast.Name)
            and annotation.value.id in {"dict", "Dict"}
        ):
            continue
        found[name] = {
            "class": class_name,
            "field": name,
            "line": node.lineno,
            "path": path.as_posix(),
        }
    return sorted(found.values(), key=lambda item: (item["path"], item["class"], item["field"]))


def _python_membership_maps(root: Path) -> dict[str, Any]:
    maps = [
        *_class_membership_maps(
            _read(root, SESSION_REGISTRY_PATH),
            class_name="SessionRegistry",
            path=SESSION_REGISTRY_PATH,
        ),
        *_class_membership_maps(
            _read(root, WEBSOCKET_PATH),
            class_name="GodotWebSocketServer",
            path=WEBSOCKET_PATH,
        ),
    ]
    maps.sort(key=lambda item: (item["path"], item["class"], item["field"]))
    return _gate(
        "session/peer membership dictionaries on the two current Python owners",
        "membership_maps",
        len(maps),
        1,
        maps=maps,
    )


def _session_fields(root: Path) -> set[str]:
    tree = ast.parse(_read(root, SESSION_REGISTRY_PATH), filename=SESSION_REGISTRY_PATH.as_posix())
    session = next(
        node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "Session"
    )
    return {
        node.target.id
        for node in session.body
        if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name)
    }


def _outside_session(node: ast.AST):
    for child in ast.iter_child_nodes(node):
        if isinstance(child, ast.ClassDef) and child.name == "Session":
            continue
        yield child
        yield from _outside_session(child)


def _session_member(target: ast.expr, fields: set[str]) -> str | None:
    if not isinstance(target, ast.Attribute) or target.attr not in fields:
        return None
    owner = target.value
    if isinstance(owner, ast.Name) and (owner.id == "session" or owner.id.endswith("_session")):
        return target.attr
    return None


def _session_mutations(source: str, path: Path, fields: set[str]) -> list[dict[str, Any]]:
    found = []
    for node in _outside_session(ast.parse(source, filename=path.as_posix())):
        targets: list[tuple[ast.expr, str]] = []
        if isinstance(node, ast.Assign):
            targets = [(target, "assign") for target in node.targets]
        elif isinstance(node, ast.AnnAssign):
            targets = [(node.target, "assign")]
        elif isinstance(node, ast.AugAssign):
            targets = [(node.target, "augmented_assign")]
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
            owner = node.func.value
            if (
                node.func.attr in _MUTATING_METHODS
                and isinstance(owner, ast.Attribute)
                and _session_member(owner, fields)
            ):
                targets = [(owner, f"method_{node.func.attr}")]
        for target, operation in targets:
            field = _session_member(target, fields)
            if field is not None:
                found.append(
                    {
                        "field": field,
                        "line": node.lineno,
                        "operation": operation,
                        "path": path.as_posix(),
                    }
                )
    return found


def _external_session_mutations(root: Path) -> dict[str, Any]:
    fields = _session_fields(root)
    mutations: list[dict[str, Any]] = []
    source_root = root / "src" / "godot_ai"
    for path in sorted(source_root.rglob("*.py")):
        relative = path.relative_to(root)
        mutations.extend(_session_mutations(path.read_text(encoding="utf-8"), relative, fields))
    mutations.sort(key=lambda item: (item["path"], item["line"], item["field"], item["operation"]))
    return _gate(
        "direct assignments or in-place container mutations of public Session fields "
        "outside Session",
        "external_mutation_sites",
        len(mutations),
        0,
        mutations=mutations,
    )


def _legacy_tokenless_paths(root: Path) -> dict[str, Any]:
    markers = {
        "legacy_handshake_model": (ENVELOPE_PATH, r"^class\s+HandshakeMessage\b"),
        "plugin_tokenless_retry": (CONNECTION_PATH, r'"recovery_action"\s*:\s*"retry_tokenless"'),
        "server_missing_token_bypass": (
            WEBSOCKET_PATH,
            r"if\s+self\._auth_token\s+is\s+not\s+None\s+and\s+handshake\.auth_token\s*:",
        ),
    }
    present: list[dict[str, Any]] = []
    for name, (path, expression) in markers.items():
        source = _read(root, path)
        match = re.search(expression, source, re.MULTILINE)
        if match is not None:
            present.append(
                {"id": name, "line": _line_number(source, match.start()), "path": path.as_posix()}
            )
    return _gate(
        "named v3 handshake parser, tokenless retry, and missing-token acceptance paths",
        "legacy_or_tokenless_paths",
        len(present),
        0,
        paths=present,
    )


def _owner_dependency_cycles(root: Path) -> dict[str, Any]:
    """Scan only the forbidden reverse edges in the approved owner graph."""

    edges: list[dict[str, Any]] = []
    for path, forbidden in _FORBIDDEN_OWNER_FIELDS.items():
        source = _read(root, path)
        for field in _gdscript_fields(source):
            if field["name"] in forbidden:
                edges.append({"path": path.as_posix(), **field})
        if path == UPDATE_MANAGER_PATH:
            for match in re.finditer(
                r"^var\s+([A-Za-z_]\w*)[^\n]*\bCallable\b", source, re.MULTILINE
            ):
                edge = {
                    "path": path.as_posix(),
                    "name": match.group(1),
                    "line": _line_number(source, match.start()),
                    "kind": "retained_callable",
                }
                if not any(
                    item["path"] == edge["path"]
                    and item["name"] == edge["name"]
                    and item["line"] == edge["line"]
                    for item in edges
                ):
                    edges.append(edge)
    edges.sort(key=lambda item: (item["path"], item["line"], item["name"]))
    return _gate(
        "forbidden retained reverse edges in the approved changed-owner graph",
        "owner_cycle_edges",
        len(edges),
        0,
        edges=edges,
    )


def _release_zip_shapes(root: Path) -> dict[str, Any]:
    """Count canonical v4 tree contracts, excluding the temporary v3 capsule."""

    literals: list[dict[str, Any]] = []
    archive_names: set[str] = set()
    for path in (RELEASE_VERIFY_PATH, UPDATE_MANAGER_PATH):
        source = _read(root, path)
        pattern = (
            r'^ASSET_NAME\s*=\s*["\']([^"\']+\.zip)["\']'
            if path == RELEASE_VERIFY_PATH
            else r'^const\s+ASSET_NAME\s*:=\s*["\']([^"\']+\.zip)["\']'
        )
        for match in re.finditer(pattern, source, re.MULTILINE):
            value = match.group(1)
            archive_names.add(value)
            literals.append(
                {
                    "path": path.as_posix(),
                    "line": _line_number(source, match.start(1)),
                    "value": value,
                }
            )
    verifier = _read(root, RELEASE_VERIFY_PATH)
    prefix_match = re.search(r'^PLUGIN_PREFIX\s*=\s*["\']([^"\']+)["\']', verifier, re.MULTILINE)
    prefix = prefix_match.group(1) if prefix_match is not None else "<missing>"
    shapes = {(name, prefix) for name in archive_names}
    if not shapes:
        shapes = {("<missing>", prefix)}
    valid = shapes == {_CANONICAL_RELEASE_SHAPE}
    return _gate(
        "distinct canonical v4 tree ZIP name/root contracts (migration capsule excluded)",
        "release_zip_shapes",
        1 if valid else max(2, len(shapes)),
        1,
        comparison="exact",
        shapes=[{"asset": asset, "prefix": shape_prefix} for asset, shape_prefix in sorted(shapes)],
        expected={"asset": _CANONICAL_RELEASE_SHAPE[0], "prefix": _CANONICAL_RELEASE_SHAPE[1]},
        literals=literals,
    )


def _active_lifecycle_episode_variants(root: Path) -> dict[str, Any]:
    fields = [
        field
        for field in _gdscript_fields(_read(root, LIFECYCLE_PATH))
        if field["name"] in _LIFECYCLE_VARIANT_FIELDS
    ]
    return _gate(
        "retained fields capable of representing independent lifecycle episode variants",
        "lifecycle_variant_fields",
        len(fields),
        1,
        comparison="exact",
        path=LIFECYCLE_PATH.as_posix(),
        fields=fields,
    )


def _production_loc(root: Path) -> dict[str, Any]:
    by_language: dict[str, dict[str, int]] = {}
    for language, extension in (("python", ".py"), ("gdscript", ".gd")):
        files = [
            path
            for production_root in (root / "src", root / "plugin")
            for path in production_root.rglob(f"*{extension}")
            if path.is_file()
        ]
        by_language[language] = {
            "files": len(files),
            "lines": sum(path.read_bytes().count(b"\n") for path in files),
        }
    return _gate(
        "physical newline count for .py/.gd files under src/ and plugin/",
        "physical_lines",
        sum(item["lines"] for item in by_language.values()),
        informational=True,
        languages=by_language,
    )


def collect_report(
    root: Path,
    *,
    source_commit: str,
    source_tree: str,
    production_dirty: bool,
) -> dict[str, Any]:
    root = root.resolve()
    return {
        "schema_version": 1,
        "report": "godot-ai-v4-architecture-simplification-gates",
        "source": {
            "commit": source_commit,
            "production_dirty": production_dirty,
            "production_roots": ["plugin", "src"],
            "tree": source_tree,
        },
        "gates": {
            "active_lifecycle_episode_variants": _active_lifecycle_episode_variants(root),
            "dock_client_worker_static_stores": _dock_client_worker_fields(root),
            "external_mutable_session_assignments": _external_session_mutations(root),
            "legacy_tokenless_transport_branches": _legacy_tokenless_paths(root),
            "lifecycle_generic_host_dependencies": _lifecycle_host_dependencies(root),
            "non_owner_client_thread_spawns": _non_owner_client_thread_spawns(root),
            "owner_dependency_cycles": _owner_dependency_cycles(root),
            "production_python_gdscript_loc": _production_loc(root),
            "python_session_peer_membership_maps": _python_membership_maps(root),
            "v4_release_plugin_zip_shapes": _release_zip_shapes(root),
            "update_manager_plugin_dock_references": _owner_fields(
                root,
                UPDATE_MANAGER_PATH,
                {"_dock", "_plugin"},
                "UpdateManager fields that retain the plugin or Dock owner",
            ),
        },
    }


def _git(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=root, check=True, capture_output=True, text=True
    ).stdout.strip()


def _production_differs_from(root: Path, commit: str) -> bool:
    tracked = subprocess.run(["git", "diff", "--quiet", commit, "--", "src", "plugin"], cwd=root)
    if tracked.returncode not in {0, 1}:
        raise subprocess.CalledProcessError(tracked.returncode, tracked.args)
    untracked = _git(root, "ls-files", "--others", "--exclude-standard", "--", "src", "plugin")
    return tracked.returncode == 1 or bool(untracked)


def _working_tree_report(root: Path, *, source_ref: str | None = None) -> dict[str, Any]:
    commit = _git(root, "rev-parse", f"{source_ref or 'HEAD'}^{{commit}}")
    tree = _git(root, "rev-parse", f"{commit}^{{tree}}")
    production_dirty = _production_differs_from(root, commit)
    if source_ref is not None and production_dirty:
        raise ValueError(f"working src/ and plugin/ differ from requested source commit {commit}")
    return collect_report(
        root, source_commit=commit, source_tree=tree, production_dirty=production_dirty
    )


def target_failures(report: dict[str, Any]) -> list[str]:
    """Return hard-gate regressions; informational measures have no target."""

    failures = []
    for name, gate in sorted(report["gates"].items()):
        if "target" not in gate:
            continue
        actual = int(gate["value"])
        target = int(gate["target"])
        if gate.get("comparison") == "exact":
            if actual != target:
                failures.append(f"{name}: {actual} != target {target}")
        elif actual > target:
            failures.append(f"{name}: {actual} > target {target}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--source-commit", metavar="REF")
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit nonzero when any hard gate exceeds its target",
    )
    args = parser.parse_args()
    try:
        report = _working_tree_report(args.root.resolve(), source_ref=args.source_commit)
    except (OSError, StopIteration, subprocess.CalledProcessError, SyntaxError, ValueError) as exc:
        print(f"architecture gate collection failed: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2, sort_keys=True))
    if args.check:
        failures = target_failures(report)
        if failures:
            print("architecture simplification gates failed:", file=sys.stderr)
            for failure in failures:
                print(f"- {failure}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
