"""Pin the release-zip contract enforced by `.github/workflows/release.yml`.

This test exists to keep two invariants from regressing in CI's
`build-plugin-zip` step, both motivated by issue #450:

  1. The zip's second top-level entry is `godot-ai-LICENSE.txt`, not a
     bare `LICENSE`. A bare `LICENSE` lands at `res://LICENSE` on
     AssetLib install and silently overwrites the user's own project
     LICENSE file.

  2. The multi-top-level shape (`addons/` + a sibling file) is preserved.
     A single-top-folder zip lets AssetLib's "Ignore asset root" toggle
     strip the `addons/` prefix and drop `godot_ai/` outside the
     plugin path.

We assert against the workflow YAML text directly so a casual edit (e.g.
"clean up the rename, just call it LICENSE again") trips this test before
shipping a release that would clobber user files.
"""

from __future__ import annotations

from pathlib import Path

import pytest

WORKFLOW = Path(__file__).resolve().parents[2] / ".github" / "workflows" / "release.yml"


@pytest.fixture(scope="module")
def workflow_text() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def test_release_zip_uses_namespaced_license_filename(workflow_text: str) -> None:
    assert "godot-ai-LICENSE.txt" in workflow_text, (
        "release.yml should ship LICENSE under the namespaced name "
        "godot-ai-LICENSE.txt — see issue #450."
    )


def test_release_zip_does_not_pack_bare_license_at_root(workflow_text: str) -> None:
    # The `zip` invocation must not include a bare `LICENSE` argument at
    # the top level. We look for the specific `zip -D -r ... LICENSE`
    # shape the workflow uses; substring-matching `LICENSE` alone would
    # false-positive on the namespaced filename.
    forbidden = "../godot-ai-plugin.zip addons/ LICENSE"
    assert forbidden not in workflow_text, (
        "release.yml must not pack a bare `LICENSE` at zip root — that "
        "clobbers the installing project's own LICENSE file (issue #450)."
    )


def test_release_zip_preserves_multi_top_shape(workflow_text: str) -> None:
    # The whole point of having a sibling file alongside `addons/` is to
    # keep AssetLib from offering the "Ignore asset root" strip option.
    # If a future cleanup drops the sibling entirely, the strip
    # regression returns.
    assert "addons/ godot-ai-LICENSE.txt" in workflow_text, (
        "release.yml must keep the multi-top-level zip shape so "
        "AssetLib doesn't strip the `addons/` prefix on install."
    )
