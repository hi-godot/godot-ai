#!/usr/bin/env python3
"""Build Claude's opt-in skill metadata from the shared pstack source."""

import hashlib
import json
import shutil
from pathlib import Path


def build(repo: Path) -> Path:
    source = repo / "plugins/pstack-godot"
    files = sorted(path for path in source.rglob("*") if path.is_file())
    digest = hashlib.sha256(Path(__file__).read_bytes())
    for path in files:
        digest.update(path.relative_to(source).as_posix().encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")

    marketplace = repo / ".pstack-local/claude"
    relative = Path("packages") / digest.hexdigest() / "pstack-godot"
    destination = marketplace / relative
    # Content-addressed output avoids deleting an installed or in-use package.
    shutil.copytree(source, destination, dirs_exist_ok=True)
    for skill in (destination / "skills").glob("*/SKILL.md"):
        text = skill.read_text(encoding="utf-8")
        if not text.startswith("---\n"):
            raise ValueError(f"Missing frontmatter in {skill.relative_to(destination)}")
        skill.write_text(
            text.replace("---\n", "---\ndisable-model-invocation: true\n", 1),
            encoding="utf-8",
        )

    manifest = {
        "name": "godot-ai-local",
        "owner": {"name": "Godot AI contributors"},
        "metadata": {"description": "Local pstack workflows built from the Godot AI repository."},
        "plugins": [
            {
                "name": "pstack-godot",
                "source": "./" + relative.as_posix(),
                "description": "Opt-in pstack workflows adapted for Godot AI.",
            }
        ],
    }
    manifest_path = marketplace / ".claude-plugin/marketplace.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return marketplace


if __name__ == "__main__":
    print(build(Path(__file__).resolve().parent.parent))
