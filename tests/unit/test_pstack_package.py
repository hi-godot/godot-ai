"""Exercise the packaged source and the Claude distribution boundary."""

import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "plugins/pstack-godot"


def test_pstack_upstream_snapshot_and_opt_in_entries() -> None:
    lock = json.loads((PLUGIN / "upstream-lock.json").read_text(encoding="utf-8"))
    upstream = PLUGIN / "upstream/pstack"
    actual = {
        path.relative_to(upstream).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in upstream.rglob("*")
        if path.is_file()
    }
    assert actual == lock["sha256"]
    upstream_skills = {path.parent.name for path in (upstream / "skills").glob("*/SKILL.md")}
    entries = list((PLUGIN / "skills").glob("*/SKILL.md"))
    assert {entry.parent.name for entry in entries} == upstream_skills
    assert "poteto-mode" in upstream_skills
    for entry in entries:
        metadata = yaml.safe_load(entry.read_text(encoding="utf-8").split("---", 2)[1])
        policy = yaml.safe_load((entry.parent / "agents/openai.yaml").read_text(encoding="utf-8"))
        assert metadata["name"] == entry.parent.name
        assert metadata.get("disable-model-invocation", False) is False
        assert policy["policy"]["allow_implicit_invocation"] is False


def test_claude_build_is_repeatable_and_excludes_personal_files(tmp_path: Path) -> None:
    script = tmp_path / "script/build-pstack-claude.py"
    script.parent.mkdir()
    shutil.copyfile(ROOT / "script/build-pstack-claude.py", script)
    source = tmp_path / "plugins/pstack-godot"
    shutil.copytree(PLUGIN, source)
    (tmp_path / ".pstack.local.md").write_text("private-model-preferences", encoding="utf-8")
    private = tmp_path / ".pstack-local/private-transcript.txt"
    private.parent.mkdir()
    private.write_text("private-transcript-sentinel", encoding="utf-8")

    def run_build() -> tuple[dict, Path]:
        subprocess.run([sys.executable, str(script)], check=True, capture_output=True, text=True)
        marketplace = tmp_path / ".pstack-local/claude"
        manifest = json.loads(
            (marketplace / ".claude-plugin/marketplace.json").read_text(encoding="utf-8")
        )
        return manifest, marketplace / manifest["plugins"][0]["source"]

    first_manifest, first_package = run_build()
    first_bytes = {
        path.relative_to(first_package): path.read_bytes()
        for path in first_package.rglob("*")
        if path.is_file()
    }
    second_manifest, second_package = run_build()
    assert first_manifest == second_manifest
    assert first_package == second_package
    assert first_bytes == {
        path.relative_to(second_package): path.read_bytes()
        for path in second_package.rglob("*")
        if path.is_file()
    }
    for entry in (second_package / "skills").glob("*/SKILL.md"):
        metadata = yaml.safe_load(entry.read_text(encoding="utf-8").split("---", 2)[1])
        assert metadata["disable-model-invocation"] is True
        assert entry.read_text(encoding="utf-8").count("disable-model-invocation:") == 1
    assert not (second_package / ".pstack.local.md").exists()
    assert not (second_package / ".pstack-local").exists()
    assert all(b"private-transcript-sentinel" not in data for data in first_bytes.values())
    assert all(b"private-model-preferences" not in data for data in first_bytes.values())
    assert (source / "skills/poteto-mode/SKILL.md").read_bytes() == (
        PLUGIN / "skills/poteto-mode/SKILL.md"
    ).read_bytes()

    (source / "models.md").write_text("Updated shared defaults\n", encoding="utf-8")
    _, updated_package = run_build()
    assert updated_package != first_package
    assert (updated_package / "models.md").read_text(
        encoding="utf-8"
    ) == "Updated shared defaults\n"
    assert (first_package / "models.md").read_bytes() == first_bytes[Path("models.md")]
