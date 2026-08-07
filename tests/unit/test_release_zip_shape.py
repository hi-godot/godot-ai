"""Pin the release-zip contract enforced by `.github/workflows/release.yml`.

CI's `build-plugin-zip` step produces two artifacts with deliberately
different shapes; this test keeps both from regressing:

`godot-ai-plugin.zip` (classic AssetLib entry, self-updater, manual
downloads) — invariants motivated by issue #450:

  1. The zip's second top-level entry is `godot-ai-LICENSE.txt`, not a
     bare `LICENSE`. A bare `LICENSE` lands at `res://LICENSE` on
     AssetLib install and silently overwrites the user's own project
     LICENSE file.

  2. The multi-top-level shape (`addons/` + a sibling file) is preserved.
     On Godot <= 4.6 a single-top-folder zip lets AssetLib's autoskipped
     "Ignore asset root" toggle strip the `addons/` prefix and drop
     `godot_ai/` outside the plugin path. (Godot 4.7+ special-cases a
     bare `addons/` root; the sibling can be retired — and the two
     artifacts re-unified — once the supported floor reaches 4.7.)

`godot-ai-plugin-store.zip` (Godot Asset Store upload) — Asset Store
review asked that the zip carry no root-level license duplicate, so it
ships `addons/` only, with the canonical license at
`addons/godot_ai/LICENSE`. Its consumers never hit the <= 4.6 autoskip
default (browser download + manual Import, or the 4.7+ in-editor store).

We assert against the workflow YAML text directly so a casual edit (e.g.
"clean up the rename, just call it LICENSE again" or "add the license
back to the store zip root") trips this test before shipping a release
that would clobber user files or bounce off store review.
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


def test_store_zip_packs_addons_only(workflow_text: str) -> None:
    # The Asset Store upload must contain `addons/` and nothing else at
    # the top level — store review rejects a root-level license
    # duplicate, and any other root sibling is clutter installed into
    # the user's project.
    assert "../godot-ai-plugin-store.zip addons/\n" in workflow_text, (
        "release.yml must build godot-ai-plugin-store.zip from `addons/` "
        "alone — no root-level license or other sibling entries (Asset "
        "Store review feedback)."
    )


def _step_block(workflow_text: str, step_name: str, next_step_name: str) -> str:
    # Slice the text of one workflow step so assertions can't be
    # satisfied by comments or unrelated steps elsewhere in the file.
    start_marker = f"      - name: {step_name}"
    end_marker = f"      - name: {next_step_name}"
    assert start_marker in workflow_text, f"release.yml is missing step {step_name!r}"
    block = workflow_text.split(start_marker, 1)[1]
    assert end_marker in block, (
        f"release.yml is missing step {next_step_name!r} after {step_name!r}"
    )
    return block.split(end_marker, 1)[0]


def test_store_zip_verifies_inner_license_present(workflow_text: str) -> None:
    # Dropping the root license is only valid while the canonical copy
    # ships inside the addon folder; the workflow must keep verifying
    # that premise at build time. Scoped to the verify step: the build
    # step's comments also mention the path, so a whole-file substring
    # match would pass even with the actual check deleted.
    verify_step = _step_block(workflow_text, "Verify zip structure", "Generate SHA-256 checksum")
    assert "grep -qx 'addons/godot_ai/LICENSE'" in verify_step, (
        "release.yml must verify addons/godot_ai/LICENSE exists in the "
        "store zip — it is the only license copy in that artifact."
    )


def test_store_zip_attached_to_release(workflow_text: str) -> None:
    # The store zip is only useful if it ships with the release for the
    # maintainer to upload; building it and forgetting to attach it
    # would silently revert the store to the multi-top zip. Scoped to
    # the release step's files list: the name appears many times in the
    # build/verify steps, so a bare count can't catch a missing entry.
    release_step = _step_block(workflow_text, "Create GitHub Release", "Post changelog to Discord")
    assert "\n            godot-ai-plugin-store.zip\n" in release_step, (
        "release.yml must attach godot-ai-plugin-store.zip to the "
        "GitHub Release."
    )
