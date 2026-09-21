"""Bind supplemental release validation rows to one qualified candidate."""

from __future__ import annotations

import argparse
from pathlib import Path

from script import release_support as support


def file_metadata(value: dict) -> dict:
    support.require(
        isinstance(value, dict)
        and type(value.get("size")) is int
        and 0 < value["size"] <= support.MAX_FILE_BYTES
        and isinstance(value.get("sha256"), str)
        and support.DIGEST.fullmatch(value["sha256"]),
        "invalid validation file metadata",
    )
    return {key: value[key] for key in ("size", "sha256")}


def public_files(files: dict, expected: dict, hosts: set[str]) -> None:
    from script import release_promotion as promotion

    support.require(
        isinstance(files, dict) and files.keys() == expected.keys(), "public inventory mismatch"
    )
    for name, metadata in files.items():
        support.require(
            file_metadata(metadata) == expected[name], "public file differs from candidate"
        )
        promotion.validate_public_url(metadata.get("url", ""), hosts)


def public_evidence(row: dict, record: dict) -> None:
    from script import release_promotion as promotion

    for key, prefix, hosts in (
        ("pypi", "dist/", {"files.pythonhosted.org"}),
        ("github", "release/", {"github.com", "release-assets.githubusercontent.com"}),
    ):
        expected = {
            name.removeprefix(prefix): value
            for name, value in record["files"].items()
            if name.startswith(prefix)
        }
        public_files(row.get(key), expected, hosts)
    resolutions = row.get("resolutions")
    support.require(
        isinstance(resolutions, dict) and resolutions.keys() == {"wheel", "sdist", "build"},
        "public resolutions are incomplete",
    )
    for kind, entries in resolutions.items():
        support.require(isinstance(entries, list) and entries, "empty public resolution")
        names = set()
        releases = []
        for entry in entries:
            file_metadata(entry)
            name, version = entry.get("name"), entry.get("version")
            support.require(
                isinstance(name, str) and name and isinstance(version, str) and version,
                "invalid resolved package",
            )
            normalized = name.lower().replace("_", "-").replace(".", "-")
            support.require(normalized not in names, "duplicate resolved package")
            names.add(normalized)
            promotion.validate_public_url(entry.get("url", ""), {"files.pythonhosted.org"})
            if normalized == "godot-ai":
                releases.append(entry)
        if kind != "build":
            filename = f"godot_ai-{record['version']}" + (
                "-py3-none-any.whl" if kind == "wheel" else ".tar.gz"
            )
            support.require(
                len(releases) == 1
                and releases[0]["version"] == record["version"]
                and file_metadata(releases[0]) == record["files"]["dist/" + filename],
                "resolved release differs from candidate format",
            )


def predecessor_evidence(row: dict, path: Path, candidate: Path, record: dict) -> dict:
    from script import qualification_engine as engine
    from script import release_predecessor as predecessor

    inventory = support.inventory(path.parent)
    inventory.pop("row.json")
    support.require(row.get("files") == inventory, "predecessor retained files changed")
    previous = row.get("predecessor", {})
    version = previous.get("version", "")
    support.require(
        row.get("previous_version") == version
        and previous.get("tag") == "v" + version
        and support.SHA.fullmatch(str(previous.get("source", ""))),
        "invalid predecessor identity",
    )
    old, new = support.version_tuple(version), support.version_tuple(record["version"])
    support.require(
        old[0] == new[0] == 4
        and old < new
        and previous.get("spki_sha256") == record["spki_sha256"],
        "invalid predecessor release",
    )
    expected_names = {"release/" + name for name in support.RELEASE_NAMES} | {
        "dist/" + name for name in support.distribution_names(version)
    }
    files = previous.get("files", {})
    support.require(files.keys() == expected_names, "incomplete predecessor public inventory")
    for name, metadata in files.items():
        public_files(
            {name: metadata},
            {name: file_metadata(metadata)},
            {"files.pythonhosted.org"} if name.startswith("dist/") else predecessor.GITHUB_HOSTS,
        )
    support.require(
        row.get("required_skips") == 0
        and row.get("run_id") == record["run_id"]
        and row.get("run_attempt") == record["run_attempt"],
        "predecessor qualification binding mismatch",
    )
    cases = row.get("cases", [])
    support.require(len(cases) == 1, "missing predecessor native case")
    case = cases[0]
    support.require(row.get("godot_version") == "4.7.0", "unexpected predecessor Godot row")
    engine.validate_identity(case.get("godot"), row["godot_version"], row["os"])
    support.require(
        case.get("id") == predecessor.CASE_ID
        and case.get("status") == "passed"
        and case.get("backend_stopped") is True
        and case.get("from_version") == version
        and case.get("to_version") == record["version"],
        "predecessor native case did not pass",
    )
    result, bridge = case.get("runtime_result", {}), case.get("attached_bridge", {})
    support.require(
        result.get("status") == "passed"
        and result.get("attached_bridge_served_b") is True
        and result.get("from_version") == version
        and result.get("to_version") == record["version"]
        and bridge.get("pin") == version
        and type(bridge.get("ok_before_update")) is int
        and bridge["ok_before_update"] >= 1
        and bridge.get("served_b") is True
        and not bridge.get("fault"),
        "predecessor attached bridge evidence missing",
    )
    manifest = support.read_json(candidate / "release" / predecessor.MANIFEST)
    tree = {
        item["path"].removeprefix("addons/godot_ai/"): {
            key: item[key] for key in ("size", "sha256")
        }
        for item in manifest["inventory"]
    }
    tree_hash = support.verifier().inventory_tree_hash(manifest)
    support.require(
        case.get("live_tree") == tree and case.get("live_tree_sha256") == tree_hash,
        "predecessor live tree differs from candidate",
    )
    expected_state = {
        "status": "success",
        "clients_migrated": True,
        "from_version": version,
        "to_version": record["version"],
        "manifest_sha256": support.fingerprint(candidate / "release" / predecessor.MANIFEST)[
            "sha256"
        ],
        "expected_tree_sha256": tree_hash,
    }
    support.require(
        case.get("update_state") == expected_state,
        "predecessor update state differs from candidate",
    )
    file_metadata(case.get("update_marker"))
    backup = case.get("backup_tree")
    support.require(isinstance(backup, dict) and backup, "missing predecessor backup")
    backup_manifest = {
        "inventory": [
            {"path": "addons/godot_ai/" + name, **file_metadata(value)}
            for name, value in backup.items()
        ]
    }
    support.require(
        case.get("backup_tree_sha256") == support.verifier().inventory_tree_hash(backup_manifest),
        "predecessor backup evidence differs",
    )
    return previous


def check_publication_run(run_id: str, candidate: Path) -> dict:
    from script import release_promotion as promotion

    support.require(run_id.isdecimal(), "invalid publication run ID")
    record = support.verify_candidate(candidate, "a")
    run = promotion.gh(f"repos/{support.REPOSITORY}/actions/runs/{run_id}")
    support.require(
        run.get("id") == int(run_id)
        and run.get("repository", {}).get("full_name") == support.REPOSITORY
        and run.get("path") == ".github/workflows/release.yml"
        and run.get("event") == "workflow_dispatch"
        and run.get("head_branch") == "main"
        and run.get("head_sha") == record["source"]
        and run.get("conclusion") == "success",
        "publication run provenance mismatch",
    )
    return run


def complete(
    candidate: Path, rows: Path, output: Path, kind: str, publication: Path | None = None
) -> None:
    support.require(kind in {"predecessor", "public"}, "unknown validation kind")
    record = support.verify_candidate(candidate, "a")
    binding = support.fingerprint(candidate / "evidence.json")
    required = {(os_label, python) for os_label in support.PLATFORMS for python in ("3.11", "3.14")}
    found = set()
    previous = None
    for path in rows.glob("*/row.json"):
        row = support.read_json(path)
        key = (row.get("os"), row.get("python"))
        support.require(
            key in required and key not in found, "unexpected or duplicate validation row"
        )
        support.require(
            row.get("schema") == 1 and row.get("status") == "passed" and row.get("kind") == kind,
            "validation row did not pass",
        )
        support.require(
            row.get("candidate") == binding
            and row.get("version") == record["version"]
            and row.get("source") == record["source"],
            "validation candidate mismatch",
        )
        if kind == "predecessor":
            identity = predecessor_evidence(row, path, candidate, record)
            support.require(
                previous is None or previous == identity, "validation predecessors differ"
            )
            previous = identity
        else:
            public_evidence(row, record)
        found.add(key)
    support.require(found == required, "required validation rows are missing")
    result = {
        "schema": 1,
        "kind": kind,
        "status": "passed",
        "candidate": binding,
        "version": record["version"],
        "source": record["source"],
        "files": support.inventory(rows),
    }
    if kind == "public":
        support.require(publication is not None, "public attestation requires publication receipt")
        receipt = support.read_json(publication)
        for key in (
            "version",
            "tag",
            "source",
            "workflow_sha",
            "run_id",
            "run_attempt",
            "spki_sha256",
            "files",
        ):
            support.require(
                support.canonical(receipt.get(key)) == support.canonical(record[key]),
                "publication receipt differs from qualified candidate",
            )
        result["publication"] = {"receipt": receipt, "digest": support.fingerprint(publication)}
    output.write_bytes(support.canonical(result))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--rows", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--kind", choices=("predecessor", "public"), required=True)
    parser.add_argument("--publication", type=Path)
    args = parser.parse_args()
    complete(args.candidate, args.rows, args.output, args.kind, args.publication)


if __name__ == "__main__":
    main()
