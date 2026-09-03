from __future__ import annotations

import hashlib
import os
import re
import stat
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

import pytest

import godot_ai.update_transaction as tx


@dataclass
class Scenario:
    project: Path
    install: Path
    recovery: Path
    stage: Path
    intent: tx.Intent


def _mkdir(path: Path) -> Path:
    path.mkdir(mode=0o700)
    return path


def _tree(root: Path, marker: str) -> None:
    (root / "nested").mkdir(mode=0o700)
    (root / "plugin.cfg").write_text(f"version={marker}\n")
    (root / "nested" / "code.gd").write_text(f"extends Node\n# {marker}\n")


def _stage_fixture(_archive, _manifest, _signature, _expected, destination):
    destination.mkdir(mode=0o700)
    plugin = _mkdir(_mkdir(destination / "addons") / "godot_ai")
    _tree(plugin, "new")
    inventory = []
    for path in sorted(plugin.rglob("*")):
        if path.is_file():
            data = path.read_bytes()
            inventory.append(
                {
                    "path": tx.PLUGIN_PREFIX + path.relative_to(plugin).as_posix(),
                    "size": len(data),
                    "sha256": tx.hashlib.sha256(data).hexdigest(),
                }
            )
    return plugin, "b" * 64, {"inventory": inventory}


def _scenario(
    tmp_path: Path,
    suffix: str = "0123456789abcdef",
    *,
    from_version: str = "4.0.0",
    editor: tx.ProcessIdentity | None = None,
) -> Scenario:
    project = _mkdir(tmp_path / f"project-{suffix}")
    addons = _mkdir(project / "addons")
    install = _mkdir(addons / "godot_ai")
    _tree(install, "old")
    recovery = tx.recovery_root(project, install, create=True)
    stages = _mkdir(recovery / "stages")
    stage = _mkdir(_mkdir(_mkdir(stages / suffix) / "addons") / "godot_ai")
    _tree(stage, "new")
    fingerprint = tx.process_start_fingerprint(os.getpid()) or "test-process"
    if editor is None:
        editor = tx.ProcessIdentity(os.getpid(), fingerprint, f"editor-{suffix}")
    runner = tx.ProcessIdentity(os.getpid(), fingerprint, f"runner-{suffix}")
    intent = tx.Intent.create(
        transaction=suffix,
        project_root=project,
        install_root=install,
        recovery=recovery,
        stage_root=stage,
        from_version=from_version,
        to_version="4.0.1",
        manifest_sha256="a" * 64,
        editor=editor,
        runner=runner,
    )
    paths = tx.TransactionPaths.for_transaction(recovery, suffix, create=True)
    tx.publish_record(
        paths.directory / "prepare-claim.json",
        tx._prepare_claim_record(
            transaction=suffix,
            project=project,
            install=install,
            recovery=recovery,
            stage=stage,
            old_tree=intent.old_tree,
            editor=editor,
        ),
    )
    tx.publish_record(paths.prepared, tx._prepared_from_intent(intent))
    return Scenario(project, install, recovery, stage, intent)


def _paths(scenario: Scenario) -> tx.TransactionPaths:
    directory = scenario.recovery / "transactions" / scenario.intent.transaction
    return tx.TransactionPaths(
        scenario.recovery,
        directory,
        directory / "prepared.json",
        directory / "intent.json",
        directory / "journal.json",
        directory / "readiness.json",
        directory / "result.json",
        directory / "claim.json",
        directory / "migration-complete.json",
    )


def _wait_until(predicate: Any, timeout: float = 90.0) -> None:
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            pytest.fail("timed out waiting for transaction state")
        time.sleep(0.01)


def _wait_for_phase(scenario: Scenario, actor: Actor, phase: str) -> None:
    _wait_until(lambda: actor.error is not None or _phase(scenario) == phase)
    if actor.error is not None:
        raise actor.error


def _manual_marker(project: Path) -> tuple[Path, dict[str, Any]]:
    state = project / ".godot"
    state.mkdir(mode=0o700, exist_ok=True)
    if os.name != "nt":
        state.chmod(0o700)
    marker = state / "godot-ai-v4-migration.json"
    row = {
        "from_version": "3.2.4",
        "kind": "pre_v4_migration",
        "schema_version": 1,
        "source_commit": "a" * 40,
        "to_version": tx.PACKAGE_VERSION,
    }
    marker.write_bytes(tx.canonical_json(row))
    if os.name != "nt":
        marker.chmod(0o600)
    return marker, row


class Actor:
    def __init__(self, intent: tx.Intent, **kwargs: Any):
        self.result: dict[str, Any] | None = None
        self.error: BaseException | None = None

        def target() -> None:
            try:
                self.result = tx.run_activation(intent, **kwargs)
            except BaseException as exc:
                self.error = exc

        self.thread = threading.Thread(target=target, daemon=True)
        self.thread.start()

    def finish(self) -> dict[str, Any]:
        self.thread.join(30)
        assert not self.thread.is_alive()
        if self.error:
            raise self.error
        assert self.result is not None
        return self.result


def _claim_success_without_migration(scenario: Scenario) -> dict[str, Any]:
    actor = Actor(scenario.intent, readiness_timeout=2, claim_timeout=2)
    _wait_for_phase(scenario, actor, "stage_live")
    tx.write_readiness(scenario.intent)
    _wait_until(lambda: os.path.lexists(_paths(scenario).result))
    tx.claim_result(scenario.intent)
    return actor.finish()


def _complete_success(scenario: Scenario) -> dict[str, Any]:
    terminal = _claim_success_without_migration(scenario)
    leases = tx.EditorLeases(scenario.recovery, scenario.project, scenario.install)
    lease_path = scenario.recovery / "editor-leases" / f"{scenario.intent.editor.nonce}.json"
    acquired_here = not os.path.lexists(lease_path)
    leases.acquire(scenario.intent.editor)
    tx.complete_migration(
        scenario.project,
        scenario.install,
        scenario.recovery,
        scenario.intent.transaction,
        scenario.intent.editor,
    )
    if acquired_here:
        leases.release(scenario.intent.editor)
    return terminal


def _phase(scenario: Scenario) -> str | None:
    paths = _paths(scenario)
    if not os.path.lexists(paths.journal):
        return None
    try:
        return tx.load_journal(paths, scenario.intent)["phase"]
    except tx.TransactionError as exc:
        # This is a bounded phase poll, not admission of a journal. A replace
        # can retire the inode between stat/open (including its final link).
        # Require a later fully validated read; durable rejection still times
        # out, and the production reader never accepts the rejected record.
        if str(exc).endswith(
            ("record changed before reading", "record has an unexpected hard link")
        ):
            return None
        raise


@pytest.mark.parametrize(
    "message", ["record changed before reading", "record has an unexpected hard link"]
)
def test_phase_poll_requires_valid_read_after_transient_replacement(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    message: str,
) -> None:
    scenario = _scenario(tmp_path)
    tx.publish_record(_paths(scenario).journal, tx._journal_record(scenario.intent, "prepared", 0))
    original = tx.load_journal

    def transient(*args):
        monkeypatch.setattr(tx, "load_journal", original)
        raise tx.TransactionError(message)

    monkeypatch.setattr(tx, "load_journal", transient)
    assert _phase(scenario) is None
    assert _phase(scenario) == "prepared"


def test_phase_poll_does_not_admit_persistent_or_unrelated_rejection(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    scenario = _scenario(tmp_path)
    tx.publish_record(_paths(scenario).journal, tx._journal_record(scenario.intent, "prepared", 0))

    def reject(*args):
        raise tx.TransactionError("record has an unexpected hard link")

    monkeypatch.setattr(tx, "load_journal", reject)
    with pytest.raises(pytest.fail.Exception, match="timed out waiting"):
        _wait_until(lambda: _phase(scenario) == "prepared", timeout=0.01)

    def malformed(*args):
        raise tx.TransactionError("invalid journal schema")

    monkeypatch.setattr(tx, "load_journal", malformed)
    with pytest.raises(tx.TransactionError, match="invalid journal schema"):
        _phase(scenario)


def test_tree_identity_parse_round_trips_its_exact_record() -> None:
    identity = tx.TreeIdentity("a" * 64, 2, 17)
    assert tx.TreeIdentity.parse(identity.record(), name="test tree") == identity


def test_actor_response_always_binds_protocol_and_package_version() -> None:
    assert tx.actor_response({"status": "none"}) == {
        "package_version": tx.PACKAGE_VERSION,
        "protocol_version": tx.PROTOCOL_VERSION,
        "status": "none",
    }
    with pytest.raises(tx.TransactionError, match="may not replace"):
        tx.actor_response({"protocol_version": 2})


def test_post_update_client_repin_is_broad_only_across_the_v4_boundary(
    tmp_path: Path,
) -> None:
    intent = _scenario(tmp_path).intent
    terminal = {"outcome": "success"}
    assert tx._post_outcome(intent, terminal)["replace_owned_mismatches"] is False
    assert (
        tx._post_outcome(replace(intent, from_version="3.2.4"), terminal)[
            "replace_owned_mismatches"
        ]
        is True
    )


@pytest.mark.parametrize("predecessor_state", ["dead", "reused"])
def test_editor_lease_transfers_only_after_nonce_bound_predecessor_is_gone(
    tmp_path: Path,
    predecessor_state: str,
) -> None:
    scenario = _scenario(tmp_path)
    leases = tx.EditorLeases(scenario.recovery, scenario.project, scenario.install)
    previous = scenario.intent.editor
    current = tx.ProcessIdentity(
        previous.pid + 1,
        "restarted-editor-fingerprint",
        previous.nonce,
    )
    leases.acquire(previous)

    with pytest.raises(tx.LockBusy, match="cannot prove its predecessor closed"):
        leases.transfer_restart(
            previous,
            current,
            timeout=1,
            process_probe=lambda _identity: "unknown",
        )
    leases.transfer_restart(
        previous,
        current,
        timeout=1,
        process_probe=lambda _identity: predecessor_state,
    )

    leases.validate(current)
    with pytest.raises(tx.TransactionError, match="current editor lease"):
        leases.validate(previous)


@pytest.mark.parametrize("states", [
    ["alive", "unknown", "dead"],
    ["unknown", "reused"],
    ["unknown", "alive", "dead"],
])
def test_restart_waits_through_transient_unknown_without_transferring_early(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, states: list[str],
) -> None:
    scenario = _scenario(tmp_path)
    leases = tx.EditorLeases(scenario.recovery, scenario.project, scenario.install)
    previous = scenario.intent.editor
    current = tx.ProcessIdentity(previous.pid + 1, "new-editor", previous.nonce)
    leases.acquire(previous)
    pending = iter(states)
    observed = []

    def probe(identity):
        assert identity == previous
        leases.validate(previous)
        state = next(pending)
        observed.append(state)
        return state

    monkeypatch.setattr(tx.time, "sleep", lambda _delay: None)
    leases.transfer_restart(previous, current, timeout=1, process_probe=probe)
    assert observed == states
    leases.validate(current)


@pytest.mark.parametrize("state", ["alive", "unknown"])
def test_restart_deadline_preserves_predecessor_lease(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, state: str,
) -> None:
    scenario = _scenario(tmp_path)
    leases = tx.EditorLeases(scenario.recovery, scenario.project, scenario.install)
    previous = scenario.intent.editor
    current = tx.ProcessIdentity(previous.pid + 1, "new-editor", previous.nonce)
    leases.acquire(previous)
    clock = [0.0]
    monkeypatch.setattr(tx.time, "monotonic", lambda: clock[0])
    waits = []

    def sleep(delay):
        waits.append(delay)
        clock[0] += 0.5

    monkeypatch.setattr(tx.time, "sleep", sleep)
    with pytest.raises(tx.LockBusy, match="predecessor"):
        leases.transfer_restart(previous, current, timeout=1, process_probe=lambda _: state)
    assert waits == [tx.POLL_SECONDS, tx.POLL_SECONDS]
    leases.validate(previous)


def test_identity_command_reports_exact_actor_identity_without_inputs(
    capfd: pytest.CaptureFixture[str],
) -> None:
    assert tx.main(["identity"]) == 0
    assert tx.json.loads(capfd.readouterr().out) == {
        "package_version": tx.PACKAGE_VERSION,
        "protocol_version": tx.PROTOCOL_VERSION,
        "status": "identity",
    }


def test_success_swaps_exact_trees_retains_backup_and_requires_claim(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    actor = Actor(scenario.intent, readiness_timeout=5, claim_timeout=5)
    _wait_for_phase(scenario, actor, "stage_live")

    tx.write_readiness(scenario.intent)
    paths = _paths(scenario)
    _wait_until(lambda: os.path.lexists(paths.result))
    assert os.path.lexists(scenario.recovery / "activation.lock")
    terminal = tx.claim_result(scenario.intent)

    assert actor.finish() == terminal
    assert terminal["outcome"] == "success"
    assert tx.hash_tree(scenario.install) == scenario.intent.new_tree
    assert tx.hash_tree(scenario.intent.backup_root) == scenario.intent.old_tree
    assert not os.path.lexists(paths.result)
    assert os.path.lexists(paths.claim)
    assert not os.path.lexists(scenario.recovery / "activation.lock")
    with pytest.raises(tx.LockBusy, match="retained successful backup"):
        tx.ActivationLock(scenario.recovery).acquire(scenario.intent)


def test_initiating_startup_barrier_writes_readiness_and_claims(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    actor = Actor(scenario.intent, readiness_timeout=2, claim_timeout=2)
    _wait_for_phase(scenario, actor, "stage_live")

    outcome = tx.startup_barrier(
        scenario.project,
        scenario.install,
        editor_pid=os.getpid(),
        editor_nonce=scenario.intent.editor.nonce,
        transaction=scenario.intent.transaction,
        timeout=2,
    )

    assert outcome["status"] == "claimed"
    assert outcome["outcome"] == "success"
    assert actor.finish()["outcome"] == "success"
    assert not os.path.lexists(scenario.recovery / "activation.lock")


def test_pre_v4_restart_transfers_lease_then_claims_from_clean_editor(
    tmp_path: Path,
) -> None:
    nonce = "restart-editor-012345"
    previous = tx.ProcessIdentity(987654, "dead-editor-start", nonce)
    scenario = _scenario(
        tmp_path,
        from_version="3.2.4",
        editor=previous,
    )
    leases = tx.EditorLeases(scenario.recovery, scenario.project, scenario.install)
    leases.acquire(previous)
    actor = Actor(scenario.intent, readiness_timeout=2, claim_timeout=2)
    _wait_for_phase(scenario, actor, "stage_live")

    outcome = tx.startup_barrier(
        scenario.project,
        scenario.install,
        editor_pid=os.getpid(),
        editor_nonce=nonce,
        transaction=scenario.intent.transaction,
        timeout=2,
    )

    assert outcome["outcome"] == "success"
    assert outcome["replace_owned_mismatches"] is True
    assert actor.finish()["outcome"] == "success"
    leases.validate(tx.editor_identity(os.getpid(), nonce))


def test_startup_retry_finishes_claim_published_before_lock_release(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    actor = Actor(scenario.intent, readiness_timeout=2, claim_timeout=2)
    _wait_for_phase(scenario, actor, "stage_live")
    tx.write_readiness(scenario.intent)
    _wait_until(lambda: os.path.lexists(_paths(scenario).result))
    with pytest.raises(SimulatedCrash, match="result_to_claim:after"):
        tx.claim_result(
            scenario.intent,
            failpoints=CrashAfter("result_to_claim", "after"),  # type: ignore[arg-type]
        )
    assert os.path.lexists(_paths(scenario).claim)
    assert os.path.lexists(scenario.recovery / "activation.lock")

    outcome = tx.startup_barrier(
        scenario.project,
        scenario.install,
        editor_pid=os.getpid(),
        editor_nonce=scenario.intent.editor.nonce,
        transaction=scenario.intent.transaction,
        timeout=2,
    )
    assert outcome["outcome"] == "success"
    assert not os.path.lexists(scenario.recovery / "activation.lock")
    assert actor.finish()["outcome"] == "success"


def test_second_editor_cannot_cross_post_census_pre_rename_window(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = _scenario(tmp_path)
    reached = threading.Event()
    release = threading.Event()

    class PauseBeforeRename:
        def barrier(self, effect: str, when: str) -> None:
            if (effect, when) == ("live_to_backup", "before"):
                reached.set()
                if not release.wait(30):
                    raise AssertionError("test did not release pre-rename barrier")

    actor = Actor(
        scenario.intent,
        readiness_timeout=2,
        claim_timeout=2,
        failpoints=PauseBeforeRename(),
    )
    assert reached.wait(30)
    other = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(10)"])
    acquired: list[str] = []
    acquire = tx.EditorLeases.acquire

    def record_acquire(leases: tx.EditorLeases, editor: tx.ProcessIdentity) -> None:
        acquire(leases, editor)
        acquired.append(editor.nonce)

    monkeypatch.setattr(tx.EditorLeases, "acquire", record_acquire)
    try:
        with pytest.raises(tx.LockBusy, match="only the initiating coordinator"):
            tx.startup_barrier(
                scenario.project,
                scenario.install,
                editor_pid=other.pid,
                editor_nonce="late-editor-01234567",
                timeout=2,
            )
        with pytest.raises(tx.TransactionError, match="another initiating editor"):
            tx.startup_barrier(
                scenario.project,
                scenario.install,
                editor_pid=other.pid,
                editor_nonce="late-editor-01234567",
                transaction=scenario.intent.transaction,
                timeout=2,
            )
        assert tx.hash_tree(scenario.install) == scenario.intent.old_tree
        assert "late-editor-01234567" not in acquired
        assert not (scenario.recovery / "editor-leases" / "late-editor-01234567.json").exists()

        release.set()
        _wait_for_phase(scenario, actor, "stage_live")
        outcome = tx.startup_barrier(
            scenario.project,
            scenario.install,
            editor_pid=os.getpid(),
            editor_nonce=scenario.intent.editor.nonce,
            transaction=scenario.intent.transaction,
            timeout=2,
        )
        assert outcome["outcome"] == "success"
        assert actor.finish()["outcome"] == "success"
    finally:
        release.set()
        other.terminate()
        other.wait(timeout=3)


def test_startup_barrier_is_inert_without_recovery_state(tmp_path: Path) -> None:
    project = _mkdir(tmp_path / "project")
    install = _mkdir(_mkdir(project / "addons") / "godot_ai")
    _tree(install, "old")
    nonce = "startup-editor-012345"
    assert tx.startup_barrier(
        project,
        install,
        editor_pid=os.getpid(),
        editor_nonce=nonce,
    ) == {"status": "none"}
    root = tx.recovery_root(project, install)
    lease = tx.load_record(root / "editor-leases" / f"{nonce}.json")
    assert tx.ProcessIdentity.parse(lease["editor"], name="lease editor").pid == os.getpid()


def test_manual_migration_has_one_durable_winner_and_actor_owned_completion(
    tmp_path: Path,
) -> None:
    project = _mkdir(tmp_path / "manual-project")
    install = _mkdir(_mkdir(project / "addons") / "godot_ai")
    _tree(install, "v4")
    marker_path, marker = _manual_marker(project)
    holders = [
        subprocess.Popen([sys.executable, "-c", "import time; time.sleep(10)"])
        for _index in range(2)
    ]
    start = threading.Barrier(2)
    outcomes: list[tuple[str, int, str]] = []

    def compete(index: int) -> None:
        nonce = f"manual-editor-{index}-012345"
        start.wait()
        try:
            result = tx.startup_barrier(
                project,
                install,
                editor_pid=holders[index].pid,
                editor_nonce=nonce,
            )
            outcomes.append(("won", index, str(result["transaction"])))
        except tx.LockBusy:
            outcomes.append(("lost", index, nonce))

    threads = [threading.Thread(target=compete, args=(index,)) for index in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(5)
        assert not thread.is_alive()

    try:
        assert sorted(kind for kind, _index, _value in outcomes) == ["lost", "won"]
        winner = next(index for kind, index, _value in outcomes if kind == "won")
        editor = tx.editor_identity(holders[winner].pid, f"manual-editor-{winner}-012345")
        expected_transaction = (
            "manual-" + hashlib.sha256(tx.canonical_json(marker)).hexdigest()[:24]
        )
        assert tx.complete_manual_migration(project, install, editor) == {
            "status": "migration_complete",
            "transaction": expected_transaction,
        }
        assert not marker_path.exists()
        assert not tx.ManualMigrationElection(project, install).path.exists()
    finally:
        for holder in holders:
            holder.terminate()
            holder.wait(timeout=3)


def test_manual_migration_marker_rejects_unicode_equivalent_duplicate_key(
    tmp_path: Path,
) -> None:
    project = _mkdir(tmp_path / "manual-duplicate-project")
    install = _mkdir(_mkdir(project / "addons") / "godot_ai")
    _tree(install, "v4")
    marker_path, marker = _manual_marker(project)
    raw = tx.canonical_json(marker).decode()
    marker_path.write_text(
        raw.replace('"kind":', '"kind":"pre_v4_migration","\\u006bind":'),
        encoding="utf-8",
    )
    if os.name != "nt":
        marker_path.chmod(0o600)
    with pytest.raises(tx.TransactionError, match="duplicate JSON key: kind"):
        tx.startup_barrier(
            project,
            install,
            editor_pid=os.getpid(),
            editor_nonce="manual-duplicate-012345",
        )


def test_successful_claim_replays_m6_across_every_editor_crash_window(
    tmp_path: Path,
) -> None:
    scenario = _scenario(tmp_path)
    actor = Actor(scenario.intent, readiness_timeout=2, claim_timeout=2)
    _wait_for_phase(scenario, actor, "stage_live")
    claimed = tx.startup_barrier(
        scenario.project,
        scenario.install,
        editor_pid=os.getpid(),
        editor_nonce=scenario.intent.editor.nonce,
        transaction=scenario.intent.transaction,
        timeout=2,
    )
    assert claimed["status"] == "claimed"
    assert actor.finish()["outcome"] == "success"
    leases = tx.EditorLeases(scenario.recovery, scenario.project, scenario.install)
    leases.release(scenario.intent.editor)

    # These are the three indistinguishable durable states where the editor can
    # disappear: before repin starts, during repin, and after repin but before
    # owned client configuration is repinned. None may consume M6.
    for nonce in (
        "crash-before-repin-012345",
        "crash-during-repin-012345",
        "crash-before-confirm-012345",
    ):
        pending = tx.startup_barrier(
            scenario.project,
            scenario.install,
            editor_pid=os.getpid(),
            editor_nonce=nonce,
        )
        assert pending["status"] == "migration_pending"
        assert pending["outcome"] == "success"
        assert pending["transaction"] == scenario.intent.transaction
        assert pending["recovery_root"] == str(scenario.recovery)
        leases.release(tx.editor_identity(os.getpid(), nonce))

    completing = tx.editor_identity(os.getpid(), "complete-migration-012345")
    pending = tx.startup_barrier(
        scenario.project,
        scenario.install,
        editor_pid=completing.pid,
        editor_nonce=completing.nonce,
    )
    assert pending["status"] == "migration_pending"
    assert tx.complete_migration(
        scenario.project,
        scenario.install,
        scenario.recovery,
        scenario.intent.transaction,
        completing,
    ) == {
        "status": "migration_complete",
        "transaction": scenario.intent.transaction,
    }
    assert (
        tx.validate_migration_complete(_paths(scenario), scenario.intent)["live_tree"]
        == scenario.intent.new_tree.record()
    )
    leases.release(completing)

    after = "after-completion-012345"
    assert tx.startup_barrier(
        scenario.project,
        scenario.install,
        editor_pid=os.getpid(),
        editor_nonce=after,
    ) == {"status": "none"}
    leases.release(tx.editor_identity(os.getpid(), after))


def test_pending_migration_refuses_a_second_live_editor(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    assert _claim_success_without_migration(scenario)["outcome"] == "success"
    leases = tx.EditorLeases(scenario.recovery, scenario.project, scenario.install)
    holder = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(10)"])
    current_nonce = "pending-current-012345"
    try:
        fingerprint = tx.process_start_fingerprint(holder.pid)
        assert fingerprint is not None
        other_editor = tx.ProcessIdentity(
            holder.pid,
            fingerprint,
            "pending-holder-0123456",
        )
        leases.acquire(other_editor)

        with pytest.raises(tx.LockBusy, match="another live editor"):
            tx.startup_barrier(
                scenario.project,
                scenario.install,
                editor_pid=os.getpid(),
                editor_nonce=current_nonce,
            )

        lease_root = scenario.recovery / "editor-leases"
        assert (lease_root / f"{other_editor.nonce}.json").exists()
        assert not (lease_root / f"{current_nonce}.json").exists()
    finally:
        holder.terminate()
        holder.wait(timeout=3)


def test_simultaneous_post_crash_startups_have_one_durable_m6_winner(
    tmp_path: Path,
) -> None:
    scenario = _scenario(tmp_path)
    assert _claim_success_without_migration(scenario)["outcome"] == "success"
    holders = [
        subprocess.Popen([sys.executable, "-c", "import time; time.sleep(10)"])
        for _index in range(2)
    ]
    start = threading.Barrier(2)
    outcomes: list[tuple[str, str]] = []

    def compete(index: int) -> None:
        nonce = f"simultaneous-editor-{index}-012345"
        start.wait()
        try:
            result = tx.startup_barrier(
                scenario.project,
                scenario.install,
                editor_pid=holders[index].pid,
                editor_nonce=nonce,
            )
            outcomes.append(("won", str(result["transaction"])))
        except tx.LockBusy:
            outcomes.append(("lost", nonce))

    threads = [threading.Thread(target=compete, args=(index,)) for index in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(5)
        assert not thread.is_alive()

    try:
        assert sorted(kind for kind, _value in outcomes) == ["lost", "won"]
        election = tx.MigrationElection(scenario.recovery, scenario.project, scenario.install)
        row, owner = election.owner()
        assert row["transaction"] == scenario.intent.transaction
        assert owner.pid in {holder.pid for holder in holders}
    finally:
        for holder in holders:
            holder.terminate()
            holder.wait(timeout=3)


def test_pending_migration_removes_stale_lease_and_elects_current_editor(
    tmp_path: Path,
) -> None:
    scenario = _scenario(tmp_path)
    assert _claim_success_without_migration(scenario)["outcome"] == "success"
    leases = tx.EditorLeases(scenario.recovery, scenario.project, scenario.install)
    former = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(10)"])
    fingerprint = tx.process_start_fingerprint(former.pid)
    assert fingerprint is not None
    stale_editor = tx.ProcessIdentity(
        former.pid,
        fingerprint,
        "stale-pending-01234567",
    )
    former.terminate()
    former.wait(timeout=3)
    leases.acquire(stale_editor)

    current = tx.editor_identity(os.getpid(), "elected-current-012345")
    pending = tx.startup_barrier(
        scenario.project,
        scenario.install,
        editor_pid=current.pid,
        editor_nonce=current.nonce,
    )

    assert pending["status"] == "migration_pending"
    lease_root = scenario.recovery / "editor-leases"
    assert not (lease_root / f"{stale_editor.nonce}.json").exists()
    assert (lease_root / f"{current.nonce}.json").exists()
    leases.release(current)


def test_completed_ordinary_startup_allows_multiple_live_editor_leases(
    tmp_path: Path,
) -> None:
    scenario = _scenario(tmp_path)
    assert _complete_success(scenario)["outcome"] == "success"
    leases = tx.EditorLeases(scenario.recovery, scenario.project, scenario.install)
    holder = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(10)"])
    current = tx.editor_identity(os.getpid(), "ordinary-current-012345")
    try:
        fingerprint = tx.process_start_fingerprint(holder.pid)
        assert fingerprint is not None
        other_editor = tx.ProcessIdentity(
            holder.pid,
            fingerprint,
            "ordinary-holder-0123456",
        )
        leases.acquire(other_editor)

        assert tx.startup_barrier(
            scenario.project,
            scenario.install,
            editor_pid=current.pid,
            editor_nonce=current.nonce,
        ) == {"status": "none"}
        lease_root = scenario.recovery / "editor-leases"
        assert (lease_root / f"{other_editor.nonce}.json").exists()
        assert (lease_root / f"{current.nonce}.json").exists()
        leases.release(current)
        leases.release(other_editor)
    finally:
        holder.terminate()
        holder.wait(timeout=3)


def test_pending_migration_blocks_preflight_after_backup_archive(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    assert _claim_success_without_migration(scenario)["outcome"] == "success"
    tx.archive_retained_backup(
        scenario.project,
        scenario.install,
        editors_closed=True,
    )
    editor = tx.editor_identity(os.getpid(), "next-update-editor-012345")

    with pytest.raises(tx.LockBusy, match="post-update client migration"):
        tx.preflight_update(scenario.project, scenario.install, editor)

    lease_path = scenario.recovery / "editor-leases" / f"{editor.nonce}.json"
    assert not lease_path.exists()


def test_migration_completion_requires_exact_current_tree_and_editor_lease(
    tmp_path: Path,
) -> None:
    scenario = _scenario(tmp_path)
    _complete_success(scenario)
    paths = _paths(scenario)
    paths.migration_complete.unlink()
    editor = tx.editor_identity(os.getpid(), "unleased-completer-012345")

    with pytest.raises(tx.TransactionError, match="current editor lease"):
        tx.complete_migration(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            editor,
        )

    tx.EditorLeases(scenario.recovery, scenario.project, scenario.install).acquire(editor)
    (scenario.install / "plugin.cfg").write_text("version=tampered\n")
    with pytest.raises(tx.TransactionError, match="live tree differs"):
        tx.complete_migration(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            editor,
        )


def test_complete_migration_cli_returns_the_bound_actor_envelope(
    tmp_path: Path,
    capfd: pytest.CaptureFixture[str],
) -> None:
    scenario = _scenario(tmp_path)
    actor = Actor(scenario.intent, readiness_timeout=2, claim_timeout=2)
    _wait_for_phase(scenario, actor, "stage_live")
    tx.write_readiness(scenario.intent)
    _wait_until(lambda: os.path.lexists(_paths(scenario).result))
    tx.claim_result(scenario.intent)
    assert actor.finish()["outcome"] == "success"
    leases = tx.EditorLeases(scenario.recovery, scenario.project, scenario.install)
    leases.acquire(scenario.intent.editor)

    assert (
        tx.main(
            [
                "complete-migration",
                "--project",
                str(scenario.project),
                "--install",
                str(scenario.install),
                "--recovery-root",
                str(scenario.recovery),
                "--transaction",
                scenario.intent.transaction,
                "--editor-pid",
                str(scenario.intent.editor.pid),
                "--editor-nonce",
                scenario.intent.editor.nonce,
            ]
        )
        == 0
    )
    assert tx.json.loads(capfd.readouterr().out) == {
        "package_version": tx.PACKAGE_VERSION,
        "protocol_version": tx.PROTOCOL_VERSION,
        "status": "migration_complete",
        "transaction": scenario.intent.transaction,
    }


def test_prepare_verifies_into_fixed_recovery_stage_before_activation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _mkdir(tmp_path / "project")
    install = _mkdir(_mkdir(project / "addons") / "godot_ai")
    _tree(install, "old")
    archive, manifest, signature = (tmp_path / name for name in ("a", "m", "s"))
    for path in (archive, manifest, signature):
        path.write_bytes(b"fixture")

    def stage(_archive, _manifest, _signature, expected, destination):
        assert expected == (tx.REPOSITORY, "stable", "v4.1.0", "4.1.0", "a" * 40)
        return _stage_fixture(_archive, _manifest, _signature, expected, destination)

    monkeypatch.setattr(tx, "stage_verified_release", stage)
    prepared = tx.prepare_release(
        archive=archive,
        manifest=manifest,
        signature=signature,
        project=project,
        install=install,
        transaction="prepare-0123456789",
        channel="stable",
        tag="v4.1.0",
        version="4.1.0",
        source="a" * 40,
        editor=tx.editor_identity(os.getpid(), "prepare-editor-012345"),
    )
    assert Path(prepared["stage_root"]).is_relative_to(Path(prepared["recovery_root"]) / "stages")
    assert prepared["manifest_sha256"] == "b" * 64
    paths = tx.TransactionPaths.for_transaction(
        Path(prepared["recovery_root"]), "prepare-0123456789"
    )
    assert (
        tx.load_prepared(paths)["new_tree"] == tx.hash_tree(Path(prepared["stage_root"])).record()
    )


def test_prepare_rejects_transaction_path_syntax_before_creating_recovery(
    tmp_path: Path,
) -> None:
    project = _mkdir(tmp_path / "project")
    install = _mkdir(_mkdir(project / "addons") / "godot_ai")
    _tree(install, "old")
    with pytest.raises(tx.TransactionError, match="transaction has an invalid value"):
        tx.prepare_release(
            archive=tmp_path / "missing.zip",
            manifest=tmp_path / "missing.json",
            signature=tmp_path / "missing.sig",
            project=project,
            install=install,
            transaction="../../escape",
            channel="stable",
            tag="v4.0.1",
            version="4.0.1",
            source="a" * 40,
            editor=tx.editor_identity(os.getpid(), "prepare-editor-012345"),
        )
    assert not (tmp_path / ".godot-ai-recovery").exists()


@pytest.mark.skipif(os.name == "nt", reason="Windows forbids recovery-root overrides")
def test_preflight_rejects_cross_device_recovery_before_creating_install_state(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _mkdir(tmp_path / "project")
    install = _mkdir(_mkdir(project / "addons") / "godot_ai")
    _tree(install, "old")
    recovery_base = _mkdir(tmp_path / "other-device")
    real_device = tx._device

    def cross_device(path: Path) -> int:
        if Path(path) == recovery_base:
            return real_device(install) + 1
        return real_device(path)

    monkeypatch.setattr(tx, "_device", cross_device)
    editor = tx.editor_identity(os.getpid(), "cross-device-editor-012345")
    with pytest.raises(tx.TransactionError, match="same filesystem"):
        tx.preflight_update(project, install, editor, override=recovery_base)

    assert not (recovery_base / tx.install_id(project, install)).exists()


@pytest.mark.parametrize(
    "failure",
    (
        "before_claim",
        "during_stage",
        "after_stage",
        "surrogate_manifest",
        "after_prepared",
    ),
)
def test_handled_prepare_failures_clean_exact_state_and_allow_retry(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, failure: str
) -> None:
    project = _mkdir(tmp_path / "project")
    install = _mkdir(_mkdir(project / "addons") / "godot_ai")
    _tree(install, "old")
    inputs = tuple(tmp_path / name for name in ("archive", "manifest", "signature"))
    for path in inputs:
        path.write_bytes(b"fixture")
    transaction = f"prepare-{failure}-01234567"
    editor = tx.editor_identity(os.getpid(), f"editor-{failure}-01234567")
    original_publish = tx.publish_record

    def publish(path: Path, value: dict[str, Any]) -> None:
        if failure == "before_claim" and path.name == "prepare-claim.json":
            raise OSError("claim write failed")
        original_publish(path, value)
        if failure == "after_prepared" and path.name == "prepared.json":
            raise OSError("prepared sync failed")

    def stage(*args):
        if failure == "during_stage":
            destination = args[-1]
            destination.mkdir(mode=0o700)
            (destination / "partial").write_text("partial")
            raise tx.ReleaseError("fixture verification failed")
        plugin, digest, manifest = _stage_fixture(*args)
        if failure == "after_stage":
            manifest["inventory"][0]["sha256"] = "c" * 64
        if failure == "surrogate_manifest":
            manifest["inventory"][0]["path"] = tx.PLUGIN_PREFIX + "\ud800"
        return plugin, digest, manifest

    monkeypatch.setattr(tx, "publish_record", publish)
    monkeypatch.setattr(tx, "stage_verified_release", stage)
    old_tree = tx.hash_tree(install)
    with pytest.raises((OSError, tx.ReleaseError, tx.TransactionError)):
        tx.prepare_release(
            archive=inputs[0],
            manifest=inputs[1],
            signature=inputs[2],
            project=project,
            install=install,
            transaction=transaction,
            channel="stable",
            tag="v4.1.0",
            version="4.1.0",
            source="a" * 40,
            editor=editor,
        )

    root = tx.recovery_root(project, install)
    assert not os.path.lexists(root / "stages" / transaction)
    assert tx.hash_tree(install) == old_tree
    assert tx.preflight_update(project, install, editor) == root


def test_canonical_json_reports_lone_surrogate_as_transaction_error() -> None:
    with pytest.raises(tx.TransactionError, match="canonical JSON"):
        tx.canonical_json({"value": "\ud800"})


def test_spawn_failure_abort_removes_only_the_prepared_stage(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    paths = _paths(scenario)
    container = scenario.recovery / "stages" / scenario.intent.transaction

    result = tx.abort_prepared(
        scenario.project,
        scenario.install,
        scenario.recovery,
        scenario.intent.transaction,
        scenario.intent.editor,
    )

    assert result == {"status": "aborted", "transaction": scenario.intent.transaction}
    assert not os.path.lexists(container)
    assert tx.load_record(paths.directory / "cleanup.json")["record"] == ("preactivation_cleanup")
    assert (
        tx.abort_prepared(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            scenario.intent.editor,
        )
        == result
    )
    assert tx.hash_tree(scenario.install) == scenario.intent.old_tree


def test_prepared_abort_is_identity_bound_and_loses_to_activation(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    wrong = tx.ProcessIdentity.current("wrong-editor-012345")
    with pytest.raises(tx.TransactionError, match="another editor or install"):
        tx.abort_prepared(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            wrong,
        )

    tx.publish_record(_paths(scenario).intent, scenario.intent.record())
    with pytest.raises(tx.TransactionError, match="explicit intent-only cleanup"):
        tx.abort_prepared(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            scenario.intent.editor,
        )
    assert tx.hash_tree(scenario.stage) == scenario.intent.new_tree


@pytest.mark.parametrize("effect", ["prepare_claim", "prepared_commit"])
def test_dead_editor_takeover_cleans_crash_after_preparation_authority(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    effect: str,
) -> None:
    project = _mkdir(tmp_path / "project")
    install = _mkdir(_mkdir(project / "addons") / "godot_ai")
    _tree(install, "old")
    inputs = tuple(tmp_path / name for name in ("archive", "manifest", "signature"))
    for path in inputs:
        path.write_bytes(b"fixture")
    monkeypatch.setattr(tx, "stage_verified_release", _stage_fixture)
    transaction = f"dead-owner-{effect}-012345"
    editor = tx.ProcessIdentity(987654, "dead-editor-start", f"dead-{effect}-editor")

    with pytest.raises(SimulatedCrash, match=f"{effect}:after"):
        tx.prepare_release(
            archive=inputs[0],
            manifest=inputs[1],
            signature=inputs[2],
            project=project,
            install=install,
            transaction=transaction,
            channel="stable",
            tag="v4.1.0",
            version="4.1.0",
            source="a" * 40,
            editor=editor,
            failpoints=CrashAfter(effect, "after"),  # type: ignore[arg-type]
        )

    root = tx.recovery_root(project, install)
    paths = tx.TransactionPaths.for_transaction(root, transaction)
    repairer = tx.ProcessIdentity.current(f"new-{effect}-repairer")
    assert tx.abort_prepared(
        project,
        install,
        root,
        transaction,
        repairer,
        dead_owner_takeover=True,
        process_probe=lambda identity: "dead" if identity == editor else "alive",
    ) == {"status": "aborted", "transaction": transaction}
    assert not os.path.lexists(root / "stages" / transaction)
    assert tx.load_record(paths.directory / "cleanup.json")["writer"] == "repair"
    assert tx.load_record(paths.directory / "repair-claim.json")["record"] == (
        "preactivation_repair_claim"
    )


def test_dead_owner_takeover_cli_uses_the_current_actor_as_repairer(
    tmp_path: Path, capfd: pytest.CaptureFixture[str]
) -> None:
    scenario = _scenario(tmp_path, "takeover-cli-012345")
    paths = _paths(scenario)
    dead_editor = tx.ProcessIdentity(987654, "dead-cli-editor", "dead-cli-editor-012345")
    owned = tx.Intent.create(
        transaction=scenario.intent.transaction,
        project_root=scenario.project,
        install_root=scenario.install,
        recovery=scenario.recovery,
        stage_root=scenario.stage,
        from_version=scenario.intent.from_version,
        to_version=scenario.intent.to_version,
        manifest_sha256=scenario.intent.manifest_sha256,
        editor=dead_editor,
        runner=scenario.intent.runner,
    )
    tx.replace_record(
        paths.directory / "prepare-claim.json",
        tx._prepare_claim_record(
            transaction=owned.transaction,
            project=owned.project_root,
            install=owned.install_root,
            recovery=owned.recovery_root,
            stage=owned.stage_root,
            old_tree=owned.old_tree,
            editor=owned.editor,
        ),
    )
    tx.replace_record(paths.prepared, tx._prepared_from_intent(owned))

    assert (
        tx.main(
            [
                "abort-prepared",
                "--project",
                str(scenario.project),
                "--install",
                str(scenario.install),
                "--recovery-root",
                str(scenario.recovery),
                "--transaction",
                scenario.intent.transaction,
                "--dead-owner-takeover",
            ]
        )
        == 0
    )
    response = tx.json.loads(capfd.readouterr().out)
    assert response["status"] == "aborted"
    assert response["transaction"] == scenario.intent.transaction
    repairer = tx.ProcessIdentity.parse(
        tx.load_record(paths.directory / "repair-claim.json")["repairer"],
        name="repairer",
    )
    assert repairer.pid == os.getpid()


@pytest.mark.parametrize(
    ("effect", "when"),
    [
        (effect, when)
        for effect in (
            "abort_claim",
            "abort_stage_delete",
            "abort_stage_sync",
            "abort_cleanup_commit",
        )
        for when in ("before", "after")
    ],
)
def test_different_identity_resumes_dead_editor_abort_after_each_durable_barrier(
    tmp_path: Path,
    effect: str,
    when: str,
) -> None:
    scenario = _scenario(tmp_path, f"takeover-{effect}-{when}-012345")
    paths = _paths(scenario)
    with pytest.raises(SimulatedCrash, match=f"{effect}:{when}"):
        tx.abort_prepared(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            scenario.intent.editor,
            failpoints=CrashAfter(effect, when),  # type: ignore[arg-type]
        )

    repairer = tx.ProcessIdentity.current(f"new-{effect}-repairer")
    assert tx.abort_prepared(
        scenario.project,
        scenario.install,
        scenario.recovery,
        scenario.intent.transaction,
        repairer,
        dead_owner_takeover=True,
        process_probe=lambda identity: "dead" if identity == scenario.intent.editor else "alive",
    ) == {"status": "aborted", "transaction": scenario.intent.transaction}
    assert not os.path.lexists(scenario.recovery / "stages" / scenario.intent.transaction)
    cleanup = tx.load_record(paths.directory / "cleanup.json")
    assert cleanup["writer"] == (
        "editor" if (effect, when) == ("abort_cleanup_commit", "after") else "repair"
    )
    assert tx.hash_tree(scenario.install) == scenario.intent.old_tree


@pytest.mark.parametrize("state", ["alive", "unknown"])
def test_prepared_takeover_refuses_editor_not_proven_gone(tmp_path: Path, state: str) -> None:
    scenario = _scenario(tmp_path, f"takeover-refuse-{state}-012345")
    repairer = tx.ProcessIdentity.current(f"takeover-refuse-{state}")
    with pytest.raises(tx.RepairRefused, match=f"editor={state}"):
        tx.abort_prepared(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            repairer,
            dead_owner_takeover=True,
            process_probe=lambda _identity: state,
        )
    assert not os.path.lexists(_paths(scenario).intent)
    assert tx.hash_tree(scenario.stage) == scenario.intent.new_tree


def test_prepared_takeover_refuses_changed_live_tree_before_publishing_claim(
    tmp_path: Path,
) -> None:
    scenario = _scenario(tmp_path, "takeover-changed-live-012345")
    (scenario.install / "plugin.cfg").write_text("version=changed\n")
    repairer = tx.ProcessIdentity.current("takeover-changed-repairer")
    with pytest.raises(tx.TransactionError, match="changed live tree"):
        tx.abort_prepared(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            repairer,
            dead_owner_takeover=True,
            process_probe=lambda _identity: "dead",
        )
    assert not os.path.lexists(_paths(scenario).intent)
    assert tx.hash_tree(scenario.stage) == scenario.intent.new_tree


def test_prepared_takeover_refuses_an_unauthenticated_stage(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path, "takeover-changed-stage-012345")
    (scenario.stage / "plugin.cfg").write_text("version=tampered\n")
    repairer = tx.ProcessIdentity.current("takeover-stage-repairer")
    with pytest.raises(tx.TransactionError, match="signed identity"):
        tx.abort_prepared(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            repairer,
            dead_owner_takeover=True,
            process_probe=lambda _identity: "dead",
        )
    assert os.path.lexists(scenario.stage)
    assert tx.hash_tree(scenario.install) == scenario.intent.old_tree


def test_prepared_takeover_never_crosses_an_activation_lock(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path, "takeover-activation-lock-012345")
    with pytest.raises(SimulatedCrash, match="activation_lock:after"):
        tx.run_activation(
            scenario.intent,
            failpoints=CrashAfter("activation_lock", "after"),  # type: ignore[arg-type]
        )
    repairer = tx.ProcessIdentity.current("takeover-lock-repairer")
    with pytest.raises(tx.TransactionError, match="activation already began"):
        tx.abort_prepared(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            repairer,
            dead_owner_takeover=True,
            process_probe=lambda _identity: "dead",
        )
    assert os.path.lexists(scenario.recovery / "activation.lock")
    assert tx.hash_tree(scenario.install) == scenario.intent.old_tree
    assert tx.hash_tree(scenario.stage) == scenario.intent.new_tree


@pytest.mark.parametrize("when", ["before", "after"])
def test_prepared_takeover_serializes_and_reclaims_only_a_dead_repairer(
    tmp_path: Path, when: str
) -> None:
    scenario = _scenario(tmp_path, f"takeover-repair-claim-{when}-012345")
    paths = _paths(scenario)
    with pytest.raises(SimulatedCrash, match="abort_claim:after"):
        tx.abort_prepared(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            scenario.intent.editor,
            failpoints=CrashAfter("abort_claim", "after"),  # type: ignore[arg-type]
        )

    first = tx.ProcessIdentity.current("first-takeover-repairer")
    with pytest.raises(SimulatedCrash, match=f"preactivation_repair_claim:{when}"):
        tx.abort_prepared(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            first,
            dead_owner_takeover=True,
            process_probe=lambda identity: (
                "dead" if identity == scenario.intent.editor else "alive"
            ),
            failpoints=CrashAfter(  # type: ignore[arg-type]
                "preactivation_repair_claim", when
            ),
        )

    second = tx.ProcessIdentity.current("second-takeover-repairer")

    def active_first(identity: tx.ProcessIdentity) -> str:
        return "alive" if identity == first else "dead"

    if when == "after":
        with pytest.raises(tx.RepairRefused, match="prior preactivation repairer"):
            tx.abort_prepared(
                scenario.project,
                scenario.install,
                scenario.recovery,
                scenario.intent.transaction,
                second,
                dead_owner_takeover=True,
                process_probe=active_first,
            )

    assert (
        tx.abort_prepared(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            second,
            dead_owner_takeover=True,
            process_probe=lambda _identity: "dead",
        )["status"]
        == "aborted"
    )
    assert len(list(paths.directory.glob("repair-claim-*.json"))) == (when == "after")
    assert (
        tx.ProcessIdentity.parse(
            tx.load_record(paths.directory / "repair-claim.json")["repairer"],
            name="repairer",
        )
        == second
    )


def test_abort_claim_atomically_blocks_a_late_activation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = _scenario(tmp_path)
    claimed = threading.Event()
    release = threading.Event()
    real_rmtree = tx.shutil.rmtree

    def pause_after_claim(path: Path) -> None:
        claimed.set()
        assert release.wait(2)
        real_rmtree(path)

    monkeypatch.setattr(tx.shutil, "rmtree", pause_after_claim)
    actor = threading.Thread(
        target=tx.abort_prepared,
        args=(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            scenario.intent.editor,
        ),
    )
    actor.start()
    assert claimed.wait(2)
    with pytest.raises(tx.TransactionError, match="intent already exists"):
        tx.run_activation(scenario.intent)
    release.set()
    actor.join(2)
    assert not actor.is_alive()
    assert tx.hash_tree(scenario.install) == scenario.intent.old_tree


def test_activation_cannot_bless_stage_mutated_after_prepare(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    (scenario.stage / "plugin.cfg").write_text("version=attacker\n")
    rebuilt = tx.Intent.create(
        transaction=scenario.intent.transaction,
        project_root=scenario.project,
        install_root=scenario.install,
        recovery=scenario.recovery,
        stage_root=scenario.stage,
        from_version=scenario.intent.from_version,
        to_version=scenario.intent.to_version,
        manifest_sha256=scenario.intent.manifest_sha256,
        editor=scenario.intent.editor,
        runner=scenario.intent.runner,
    )

    with pytest.raises(tx.TransactionError, match="signed prepared release"):
        tx.run_activation(rebuilt)
    assert tx.hash_tree(scenario.install) == scenario.intent.old_tree
    assert not os.path.lexists(scenario.recovery / "activation.lock")
    assert not os.path.lexists(_paths(scenario).intent)


def test_preflight_and_actor_refuse_another_live_editor_before_mutation(
    tmp_path: Path,
) -> None:
    scenario = _scenario(tmp_path)
    tx.EditorLeases(scenario.recovery, scenario.project, scenario.install).acquire(
        scenario.intent.editor
    )
    other = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(10)"])
    try:
        fingerprint = tx.process_start_fingerprint(other.pid)
        assert fingerprint is not None
        other_editor = tx.ProcessIdentity(other.pid, fingerprint, "other-editor-0123456")
        tx.EditorLeases(scenario.recovery, scenario.project, scenario.install).acquire(other_editor)

        paths = _paths(scenario)
        prepared = tx.load_prepared(paths)
        prepare_claim = tx.load_prepare_claim(paths)
        tx.shutil.rmtree(paths.directory)
        container = scenario.recovery / "stages" / scenario.intent.transaction
        parked = scenario.recovery / "parked-stage"
        os.rename(container, parked)
        with pytest.raises(tx.LockBusy, match="another live editor"):
            tx.preflight_update(
                scenario.project,
                scenario.install,
                scenario.intent.editor,
            )
        assert tx.hash_tree(scenario.install) == scenario.intent.old_tree
        assert tx.hash_tree(parked / "addons" / "godot_ai") == scenario.intent.new_tree
        os.rename(parked, container)

        paths = tx.TransactionPaths.for_transaction(
            scenario.recovery, scenario.intent.transaction, create=True
        )
        tx.publish_record(paths.directory / "prepare-claim.json", prepare_claim)
        tx.publish_record(paths.prepared, prepared)
        with pytest.raises(tx.LockBusy, match="another live editor"):
            tx.run_activation(scenario.intent)
        assert tx.hash_tree(scenario.install) == scenario.intent.old_tree
        assert not os.path.lexists(scenario.intent.backup_root)
    finally:
        other.terminate()
        other.wait(timeout=3)


def test_retained_backup_blocks_preflight_before_staging(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    _mkdir(scenario.intent.backup_root)
    with pytest.raises(tx.LockBusy, match="blocks the next update"):
        tx.preflight_update(
            scenario.project,
            scenario.install,
            scenario.intent.editor,
        )


def test_explicit_closed_editor_archive_allows_a_second_update(tmp_path: Path) -> None:
    first = _scenario(tmp_path)
    assert _complete_success(first)["outcome"] == "success"
    with pytest.raises(tx.TransactionError, match="editors-closed"):
        tx.archive_retained_backup(first.project, first.install, editors_closed=False)

    archived = tx.archive_retained_backup(
        first.project,
        first.install,
        editors_closed=True,
    )
    archive = Path(archived["archive"])
    assert tx.hash_tree(archive) == first.intent.old_tree
    assert not os.path.lexists(first.intent.backup_root)

    suffix = "second-update-012345"
    editor = tx.ProcessIdentity.current("second-editor-012345")
    tx.preflight_update(first.project, first.install, editor)
    stage = _mkdir(first.recovery / "stages" / suffix)
    _tree(stage, "newer")
    second_intent = tx.Intent.create(
        transaction=suffix,
        project_root=first.project,
        install_root=first.install,
        recovery=first.recovery,
        stage_root=stage,
        from_version="4.0.1",
        to_version="4.0.2",
        manifest_sha256="b" * 64,
        editor=editor,
        runner=tx.ProcessIdentity.current("second-runner-012345"),
    )
    paths = tx.TransactionPaths.for_transaction(first.recovery, suffix, create=True)
    tx.publish_record(
        paths.directory / "prepare-claim.json",
        tx._prepare_claim_record(
            transaction=suffix,
            project=first.project,
            install=first.install,
            recovery=first.recovery,
            stage=stage,
            old_tree=second_intent.old_tree,
            editor=editor,
        ),
    )
    tx.publish_record(paths.prepared, tx._prepared_from_intent(second_intent))
    second = Scenario(first.project, first.install, first.recovery, stage, second_intent)

    assert _complete_success(second)["outcome"] == "success"
    assert tx.hash_tree(second_intent.backup_root) == first.intent.new_tree
    assert tx.hash_tree(archive) == first.intent.old_tree
    with pytest.raises(tx.LockBusy, match="not proven closed"):
        tx.archive_retained_backup(first.project, first.install, editors_closed=True)


def test_cli_uses_exact_root_for_archive_and_base_for_next_preflight(
    tmp_path: Path, capfd: pytest.CaptureFixture[str]
) -> None:
    scenario = _scenario(tmp_path)
    assert _complete_success(scenario)["outcome"] == "success"
    common = ["--project", str(scenario.project), "--install", str(scenario.install)]

    assert (
        tx.main(
            [
                "archive-backup",
                *common,
                "--recovery-root",
                str(scenario.recovery),
                "--editors-closed",
            ]
        )
        == 0
    )
    archived = tx.json.loads(capfd.readouterr().out)
    assert archived["protocol_version"] == tx.PROTOCOL_VERSION

    preflight = [
        "lease",
        "preflight",
        *common,
        "--editor-pid",
        str(os.getpid()),
        "--editor-nonce",
        "second-cli-editor-012345",
    ]
    if os.name != "nt":
        preflight.extend(["--recovery-base", str(scenario.recovery.parent)])
    assert tx.main(preflight) == 0
    preflight = tx.json.loads(capfd.readouterr().out)
    assert preflight["recovery_root"] == str(scenario.recovery)


def test_preflight_cleans_bounded_stale_downloads_then_allocates_one_private_directory(
    tmp_path: Path, capfd: pytest.CaptureFixture[str]
) -> None:
    project = _mkdir(tmp_path / "project")
    install = _mkdir(_mkdir(project / "addons") / "godot_ai")
    _tree(install, "old")
    root = tx.recovery_root(project, install, create=True)
    stale = _mkdir(_mkdir(root / "downloads") / "stale-download-012345")
    for name in tx.DOWNLOAD_LIMITS:
        (stale / name).write_bytes(b"partial")
    download_id = "download-0123456789abcdef"
    assert (
        tx.main(
            [
                "lease",
                "preflight",
                "--project",
                str(project),
                "--install",
                str(install),
                "--editor-pid",
                str(os.getpid()),
                "--editor-nonce",
                "download-editor-01234567",
                "--download-id",
                download_id,
            ]
        )
        == 0
    )
    response = tx.json.loads(capfd.readouterr().out)
    download = Path(response["download_root"])
    assert download == root / "downloads" / download_id
    assert list(download.iterdir()) == []
    assert not stale.exists()
    if os.name != "nt":
        assert stat.S_IMODE(download.stat().st_mode) == 0o700


@pytest.mark.parametrize("kind", ["unexpected", "oversized"])
def test_preflight_stale_download_gc_fails_closed_without_partial_cleanup(
    tmp_path: Path, capfd: pytest.CaptureFixture[str], kind: str
) -> None:
    project = _mkdir(tmp_path / "project")
    install = _mkdir(_mkdir(project / "addons") / "godot_ai")
    _tree(install, "old")
    root = tx.recovery_root(project, install, create=True)
    downloads = _mkdir(root / "downloads")
    valid = _mkdir(downloads / "a-valid-download-012345")
    (valid / tx.MANIFEST_NAME).write_bytes(b"partial")
    invalid = _mkdir(downloads / "z-invalid-download-012345")
    path = invalid / ("unexpected.bin" if kind == "unexpected" else tx.SIGNATURE_NAME)
    path.write_bytes(b"x")
    if kind == "oversized":
        with path.open("r+b") as stream:
            stream.truncate(tx.DOWNLOAD_LIMITS[tx.SIGNATURE_NAME] + 1)

    result = tx.main(
        [
            "lease",
            "preflight",
            "--project",
            str(project),
            "--install",
            str(install),
            "--editor-pid",
            str(os.getpid()),
            "--editor-nonce",
            "stale-download-editor-012345",
            "--download-id",
            "new-download-0123456789",
        ]
    )

    assert result == 2
    assert "unexpected stale download entry" in capfd.readouterr().err
    assert (valid / tx.MANIFEST_NAME).read_bytes() == b"partial"
    assert path.exists()
    assert not (downloads / "new-download-0123456789").exists()


@pytest.mark.skipif(os.name == "nt", reason="POSIX symlink fixture")
def test_preflight_stale_download_gc_rejects_linked_child(tmp_path: Path) -> None:
    project = _mkdir(tmp_path / "project")
    install = _mkdir(_mkdir(project / "addons") / "godot_ai")
    _tree(install, "old")
    root = tx.recovery_root(project, install, create=True)
    downloads = _mkdir(root / "downloads")
    outside = _mkdir(tmp_path / "outside-stale")
    (downloads / "linked-download-012345").symlink_to(outside, target_is_directory=True)

    with pytest.raises(tx.TransactionError, match="links and reparse points"):
        tx.clean_stale_downloads(root)
    assert list(outside.iterdir()) == []


@pytest.mark.skipif(os.name == "nt", reason="POSIX symlink fixture")
def test_download_allocation_rejects_linked_parent(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    outside = _mkdir(tmp_path / "outside")
    (scenario.recovery / "downloads").symlink_to(outside, target_is_directory=True)

    with pytest.raises(tx.TransactionError, match="links and reparse points"):
        tx.allocate_download_root(scenario.recovery, "linked-download-012345")
    assert list(outside.iterdir()) == []


def test_concurrent_download_allocation_has_exactly_one_winner(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    _mkdir(scenario.recovery / "downloads")
    barrier = threading.Barrier(8)
    winners: list[Path] = []
    failures: list[BaseException] = []

    def allocate() -> None:
        barrier.wait()
        try:
            winners.append(tx.allocate_download_root(scenario.recovery, "race-download-01234567"))
        except BaseException as exc:
            failures.append(exc)

    workers = [threading.Thread(target=allocate) for _index in range(8)]
    for worker in workers:
        worker.start()
    for worker in workers:
        worker.join(2)

    assert all(not worker.is_alive() for worker in workers)
    assert len(winners) == 1
    assert len(failures) == 7
    assert all(isinstance(error, tx.TransactionError) for error in failures)
    assert list(winners[0].iterdir()) == []


def test_repeated_tree_backup_archives_use_distinct_immutable_names(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    backup = scenario.intent.backup_root
    tx.shutil.copytree(scenario.install, backup)
    first = tx.archive_retained_backup(scenario.project, scenario.install, editors_closed=True)
    tx.shutil.copytree(scenario.install, backup)
    second = tx.archive_retained_backup(scenario.project, scenario.install, editors_closed=True)

    first_path = Path(first["archive"])
    second_path = Path(second["archive"])
    assert first_path != second_path
    assert second_path.name.startswith(first_path.name + "-")
    assert tx.hash_tree(first_path) == tx.hash_tree(second_path) == scenario.intent.old_tree


def test_paused_scan_timeout_retains_live_tree_until_explicit_repair(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    actor = Actor(scenario.intent, readiness_timeout=0.05, claim_timeout=0.05)
    paths = _paths(scenario)
    _wait_until(lambda: os.path.lexists(paths.result))
    terminal = tx.validate_terminal(paths.result, scenario.intent)

    assert terminal["outcome"] == "repair_required"
    assert tx.hash_tree(scenario.install) == scenario.intent.new_tree
    assert tx.hash_tree(scenario.intent.backup_root) == scenario.intent.old_tree
    assert not os.path.lexists(scenario.intent.quarantine_root)
    assert os.path.lexists(scenario.recovery / "activation.lock")
    actor.thread.join(2)
    assert isinstance(actor.error, tx.TransactionError)

    repaired = tx.repair_transaction(
        scenario.recovery,
        scenario.intent.transaction,
        repairer=tx.ProcessIdentity.current("paused-scan-repairer-012345"),
        process_probe=lambda _identity: "dead",
    )
    assert repaired["outcome"] == "rolled_back"
    assert tx.hash_tree(scenario.install) == scenario.intent.old_tree
    assert tx.hash_tree(scenario.intent.quarantine_root) == scenario.intent.new_tree
    assert not os.path.lexists(scenario.recovery / "activation.lock")


def test_same_install_lock_has_one_winner_and_is_never_stolen(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    lock = tx.ActivationLock(scenario.recovery)
    lock.acquire(scenario.intent)
    with pytest.raises(tx.LockBusy, match="already exists"):
        tx.ActivationLock(scenario.recovery).acquire(scenario.intent)
    assert tx.ActivationLock(scenario.recovery).owner()["runner"] == scenario.intent.runner.record()
    lock.release(scenario.intent)


class SimulatedCrash(BaseException):
    pass


class CrashAfter:
    def __init__(self, effect: str, when: str):
        self.effect = effect
        self.when = when

    def barrier(self, effect: str, when: str) -> None:
        if (effect, when) == (self.effect, self.when):
            raise SimulatedCrash(f"{effect}:{when}")


class CrashDuringRollback(CrashAfter):
    """Enter handled rollback after the live swap, then crash at its target."""

    def __init__(self, effect: str, when: str):
        super().__init__(effect, when)
        self.rollback_started = False

    def barrier(self, effect: str, when: str) -> None:
        if not self.rollback_started and (effect, when) == ("stage_to_live", "after"):
            self.rollback_started = True
            raise tx.TransactionError("injected error enters normal rollback")
        if self.rollback_started:
            super().barrier(effect, when)


class CrashAfterStageLiveCommit:
    def __init__(self) -> None:
        self.journal_commits = 0

    def barrier(self, effect: str, when: str) -> None:
        if (effect, when) == ("journal_commit", "after"):
            self.journal_commits += 1
            if self.journal_commits == 2:
                raise SimulatedCrash("stage_live journal_commit:after")


@pytest.mark.parametrize("when", ["before", "after"])
def test_migration_completion_publication_crash_is_fail_closed_and_recoverable(
    tmp_path: Path,
    when: str,
) -> None:
    scenario = _scenario(tmp_path, f"migration-complete-{when}-012345")
    actor = Actor(scenario.intent, readiness_timeout=2, claim_timeout=2)
    _wait_for_phase(scenario, actor, "stage_live")
    tx.write_readiness(scenario.intent)
    _wait_until(lambda: os.path.lexists(_paths(scenario).result))
    tx.claim_result(scenario.intent)
    assert actor.finish()["outcome"] == "success"
    leases = tx.EditorLeases(scenario.recovery, scenario.project, scenario.install)
    leases.acquire(scenario.intent.editor)

    with pytest.raises(SimulatedCrash, match=f"migration_complete:{when}"):
        tx.complete_migration(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            scenario.intent.editor,
            failpoints=CrashAfter("migration_complete", when),  # type: ignore[arg-type]
        )
    leases.release(scenario.intent.editor)

    restart_nonce = f"migration-restart-{when}-012345"
    outcome = tx.startup_barrier(
        scenario.project,
        scenario.install,
        editor_pid=os.getpid(),
        editor_nonce=restart_nonce,
    )
    if when == "before":
        assert outcome["status"] == "migration_pending"
    else:
        assert outcome == {"status": "none"}


@pytest.mark.parametrize(
    ("effect", "when"),
    [
        (effect, when)
        for effect in (
            "prepare_transaction",
            "prepare_claim",
            "prepare_stage",
            "prepared_commit",
        )
        for when in ("before", "after")
    ],
)
def test_prepare_crash_states_are_explicitly_abortable(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    effect: str,
    when: str,
) -> None:
    project = _mkdir(tmp_path / "project")
    install = _mkdir(_mkdir(project / "addons") / "godot_ai")
    _tree(install, "old")
    inputs = tuple(tmp_path / name for name in ("archive", "manifest", "signature"))
    for path in inputs:
        path.write_bytes(b"fixture")
    monkeypatch.setattr(tx, "stage_verified_release", _stage_fixture)
    transaction = f"prepare-{effect}-{when}-012345"
    editor = tx.editor_identity(os.getpid(), f"editor-{effect}-{when}-012345")

    with pytest.raises(SimulatedCrash, match=f"{effect}:{when}"):
        tx.prepare_release(
            archive=inputs[0],
            manifest=inputs[1],
            signature=inputs[2],
            project=project,
            install=install,
            transaction=transaction,
            channel="stable",
            tag="v4.1.0",
            version="4.1.0",
            source="a" * 40,
            editor=editor,
            failpoints=CrashAfter(effect, when),  # type: ignore[arg-type]
        )

    root = tx.recovery_root(project, install)
    directory = root / "transactions" / transaction
    if os.path.lexists(directory):
        tx.abort_prepared(project, install, root, transaction, editor)
    assert not os.path.lexists(root / "stages" / transaction)
    assert tx.preflight_update(project, install, editor) == root


@pytest.mark.parametrize(
    ("effect", "when"),
    [
        (effect, when)
        for effect in (
            "abort_claim",
            "abort_stage_delete",
            "abort_stage_sync",
            "abort_cleanup_commit",
        )
        for when in ("before", "after")
    ],
)
def test_prepared_abort_resumes_across_every_cleanup_barrier(
    tmp_path: Path, effect: str, when: str
) -> None:
    scenario = _scenario(tmp_path, f"{effect}-{when}-abort")
    with pytest.raises(SimulatedCrash, match=f"{effect}:{when}"):
        tx.abort_prepared(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            scenario.intent.editor,
            failpoints=CrashAfter(effect, when),  # type: ignore[arg-type]
        )
    assert (
        tx.abort_prepared(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            scenario.intent.editor,
        )["status"]
        == "aborted"
    )
    assert tx.hash_tree(scenario.install) == scenario.intent.old_tree
    assert (
        tx.preflight_update(scenario.project, scenario.install, scenario.intent.editor)
        == scenario.recovery
    )


@pytest.mark.parametrize(
    ("effect", "when"),
    [
        (effect, when)
        for effect in ("abort_empty_delete", "abort_empty_sync")
        for when in ("before", "after")
    ],
)
def test_empty_prepare_directory_cleanup_is_resumable(
    tmp_path: Path, effect: str, when: str
) -> None:
    project = _mkdir(tmp_path / "project")
    install = _mkdir(_mkdir(project / "addons") / "godot_ai")
    _tree(install, "old")
    editor = tx.editor_identity(os.getpid(), "empty-cleaner-012345")
    root = tx.recovery_root(project, install, create=True)
    transaction = "empty-prepare-012345"
    tx.TransactionPaths.for_transaction(root, transaction, create=True)

    with pytest.raises(SimulatedCrash, match=f"{effect}:{when}"):
        tx.abort_prepared(
            project,
            install,
            root,
            transaction,
            editor,
            failpoints=CrashAfter(effect, when),  # type: ignore[arg-type]
        )
    assert tx.abort_prepared(project, install, root, transaction, editor)["status"] == (
        "aborted_empty"
    )
    assert tx.preflight_update(project, install, editor) == root


_MUTATION_EFFECTS = (
    "intent_commit",
    "activation_lock",
    "journal_commit",
    "live_to_backup",
    "stage_to_live",
    "readiness_commit",
    "result_commit",
    "result_to_claim",
    "activation_lock_release",
    "quarantine_live",
    "backup_to_live",
    "repair_claim",
)


@pytest.mark.parametrize(
    ("effect", "when"),
    [(effect, when) for effect in _MUTATION_EFFECTS for when in ("before", "after")],
)
def test_every_mutation_barrier_leaves_an_exact_repairable_tree(
    tmp_path: Path, effect: str, when: str
) -> None:
    """One compact matrix freezes both sides of every durable namespace effect."""

    scenario = _scenario(tmp_path, f"{effect}-{when}-fixture")
    barrier = CrashAfter(effect, when)
    actor: Actor | None = None
    paths = _paths(scenario)

    if effect in {
        "readiness_commit",
        "result_commit",
        "result_to_claim",
        "activation_lock_release",
    }:
        actor = Actor(
            scenario.intent,
            readiness_timeout=5,
            claim_timeout=5,
            failpoints=barrier if effect == "result_commit" else None,
        )
        _wait_for_phase(scenario, actor, "stage_live")
        try:
            tx.write_readiness(
                scenario.intent,
                failpoints=barrier if effect == "readiness_commit" else None,  # type: ignore[arg-type]
            )
        except SimulatedCrash:
            pass
        if effect in {"result_to_claim", "activation_lock_release"}:
            _wait_until(lambda: os.path.lexists(paths.result))
            with pytest.raises(SimulatedCrash):
                tx.claim_result(scenario.intent, failpoints=barrier)  # type: ignore[arg-type]
        elif effect == "result_commit":
            _wait_until(lambda: actor.error is not None)
        else:
            _wait_until(
                lambda: os.path.lexists(paths.result) or actor.error is not None,
                timeout=10,
            )
    elif effect in {"quarantine_live", "backup_to_live"}:
        actor = Actor(
            scenario.intent,
            claim_timeout=2,
            failpoints=CrashDuringRollback(effect, when),  # type: ignore[arg-type]
        )
        _wait_until(lambda: actor.error is not None)
    elif effect == "repair_claim":
        with pytest.raises(SimulatedCrash):
            tx.run_activation(
                scenario.intent,
                failpoints=CrashAfter("stage_to_live", "after"),  # type: ignore[arg-type]
            )
        with pytest.raises(SimulatedCrash):
            tx.repair_transaction(
                scenario.recovery,
                scenario.intent.transaction,
                repairer=tx.ProcessIdentity.current("matrix-repairer-012345"),
                process_probe=lambda _identity: "dead",
                failpoints=barrier,  # type: ignore[arg-type]
            )
    else:
        with pytest.raises(SimulatedCrash):
            tx.run_activation(scenario.intent, failpoints=barrier)  # type: ignore[arg-type]

    if os.path.lexists(scenario.recovery / "activation.lock"):
        tx.repair_transaction(
            scenario.recovery,
            scenario.intent.transaction,
            repairer=tx.ProcessIdentity.current("matrix-final-repair-012345"),
            process_probe=lambda _identity: "dead",
        )
    assert tx.hash_tree(scenario.install) in {scenario.intent.old_tree, scenario.intent.new_tree}
    assert not os.path.lexists(scenario.recovery / "activation.lock")
    if actor is not None:
        actor.thread.join(2)
        assert not actor.thread.is_alive()


def test_intent_only_crash_blocks_preflight_until_explicit_dead_runner_cleanup(
    tmp_path: Path,
) -> None:
    scenario = _scenario(tmp_path)
    paths = _paths(scenario)

    with pytest.raises(SimulatedCrash, match="intent_commit:after"):
        tx.run_activation(
            scenario.intent,
            failpoints=CrashAfter("intent_commit", "after"),  # type: ignore[arg-type]
        )

    assert os.path.lexists(paths.intent)
    assert not os.path.lexists(paths.journal)
    assert not os.path.lexists(scenario.recovery / "activation.lock")
    assert tx.hash_tree(scenario.install) == scenario.intent.old_tree
    with pytest.raises(tx.LockBusy, match="unresolved update transaction"):
        tx.preflight_update(
            scenario.project,
            scenario.install,
            scenario.intent.editor,
        )
    with pytest.raises(tx.TransactionError, match="explicit intent-only cleanup"):
        tx.abort_prepared(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            scenario.intent.editor,
        )

    repairer = tx.ProcessIdentity.current("intent-cleaner-012345")
    assert tx.abort_prepared(
        scenario.project,
        scenario.install,
        scenario.recovery,
        scenario.intent.transaction,
        repairer,
        intent_only=True,
        process_probe=lambda identity: (
            "dead" if identity in {scenario.intent.runner, scenario.intent.editor} else "alive"
        ),
    ) == {"status": "aborted_intent", "transaction": scenario.intent.transaction}
    assert tx.load_record(paths.directory / "cleanup.json")["writer"] == "repair"
    assert (
        tx.preflight_update(
            scenario.project,
            scenario.install,
            repairer,
        )
        == scenario.recovery
    )


def test_intent_only_cleanup_serializes_competing_repairers(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = _scenario(tmp_path)
    with pytest.raises(SimulatedCrash):
        tx.run_activation(
            scenario.intent,
            failpoints=CrashAfter("intent_commit", "after"),  # type: ignore[arg-type]
        )
    repairer = tx.ProcessIdentity.current("intent-cleaner-012345")
    reached = threading.Event()
    release = threading.Event()
    real_rmtree = tx.shutil.rmtree
    container = scenario.recovery / "stages" / scenario.intent.transaction

    def pause_stage_cleanup(path: Path) -> None:
        if path == container:
            reached.set()
            assert release.wait(2)
        real_rmtree(path)

    def probe(identity: tx.ProcessIdentity) -> str:
        return "dead" if identity in {scenario.intent.runner, scenario.intent.editor} else "alive"

    monkeypatch.setattr(tx.shutil, "rmtree", pause_stage_cleanup)
    errors: list[BaseException] = []

    def clean() -> None:
        try:
            tx.abort_prepared(
                scenario.project,
                scenario.install,
                scenario.recovery,
                scenario.intent.transaction,
                repairer,
                intent_only=True,
                process_probe=probe,
            )
        except BaseException as exc:
            errors.append(exc)

    worker = threading.Thread(target=clean)
    worker.start()
    assert reached.wait(2)
    with pytest.raises(tx.RepairRefused, match="prior repair runner"):
        tx.abort_prepared(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            repairer,
            intent_only=True,
            process_probe=probe,
        )
    release.set()
    worker.join(2)
    assert not worker.is_alive()
    assert errors == []


def test_intent_only_cleanup_uses_a_new_repairer_after_real_owners_die(
    tmp_path: Path,
) -> None:
    scenario = _scenario(tmp_path)
    children = [
        subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        for _index in range(2)
    ]
    try:
        identities = [
            tx.ProcessIdentity(
                child.pid,
                tx.process_start_fingerprint(child.pid) or pytest.fail("missing fingerprint"),
                nonce,
            )
            for child, nonce in zip(
                children,
                ("dead-editor-012345", "dead-runner-012345"),
                strict=True,
            )
        ]
        intent = tx.Intent.create(
            transaction=scenario.intent.transaction,
            project_root=scenario.project,
            install_root=scenario.install,
            recovery=scenario.recovery,
            stage_root=scenario.stage,
            from_version=scenario.intent.from_version,
            to_version=scenario.intent.to_version,
            manifest_sha256=scenario.intent.manifest_sha256,
            editor=identities[0],
            runner=identities[1],
        )
        paths = _paths(scenario)
        tx.replace_record(
            paths.directory / "prepare-claim.json",
            tx._prepare_claim_record(
                transaction=intent.transaction,
                project=intent.project_root,
                install=intent.install_root,
                recovery=intent.recovery_root,
                stage=intent.stage_root,
                old_tree=intent.old_tree,
                editor=intent.editor,
            ),
        )
        tx.replace_record(paths.prepared, tx._prepared_from_intent(intent))
        with pytest.raises(SimulatedCrash, match="intent_commit:after"):
            tx.run_activation(
                intent,
                failpoints=CrashAfter("intent_commit", "after"),  # type: ignore[arg-type]
            )
    finally:
        for child in children:
            child.terminate()
        for child in children:
            child.wait(timeout=3)

    repairer = tx.ProcessIdentity.current("new-repairer-012345")
    assert (
        tx.abort_prepared(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            repairer,
            intent_only=True,
        )["status"]
        == "aborted_intent"
    )
    assert (
        tx.preflight_update(
            scenario.project,
            scenario.install,
            repairer,
        )
        == scenario.recovery
    )


def test_explicit_repair_restores_crash_between_rename_and_journal(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    with pytest.raises(SimulatedCrash, match="stage_to_live:after"):
        tx.run_activation(
            scenario.intent,
            failpoints=CrashAfter("stage_to_live", "after"),  # type: ignore[arg-type]
        )
    assert _phase(scenario) == "prepared"
    assert tx.hash_tree(scenario.install) == scenario.intent.new_tree
    assert os.path.lexists(scenario.recovery / "activation.lock")

    terminal = tx.repair_transaction(
        scenario.recovery,
        scenario.intent.transaction,
        repairer=tx.ProcessIdentity(os.getpid(), "repair-test", "repairer-0123456789"),
        process_probe=lambda _identity: "dead",
    )
    assert terminal["outcome"] == "rolled_back"
    assert terminal["writer"] == "repair"
    assert tx.hash_tree(scenario.install) == scenario.intent.old_tree
    assert tx.hash_tree(scenario.intent.quarantine_root) == scenario.intent.new_tree
    assert os.path.lexists(_paths(scenario).directory / "repair-claim.json")
    assert not os.path.lexists(scenario.recovery / "activation.lock")


def test_explicit_repair_is_the_only_rollback_after_scan_authority_is_published(
    tmp_path: Path,
) -> None:
    scenario = _scenario(tmp_path)
    with pytest.raises(SimulatedCrash, match="stage_live journal_commit:after"):
        tx.run_activation(
            scenario.intent,
            failpoints=CrashAfterStageLiveCommit(),  # type: ignore[arg-type]
        )

    assert _phase(scenario) == "stage_live"
    assert tx.hash_tree(scenario.install) == scenario.intent.new_tree
    assert tx.hash_tree(scenario.intent.backup_root) == scenario.intent.old_tree
    assert os.path.lexists(scenario.recovery / "activation.lock")
    terminal = tx.repair_transaction(
        scenario.recovery,
        scenario.intent.transaction,
        repairer=tx.ProcessIdentity.current("scan-authority-repairer-012345"),
        process_probe=lambda _identity: "dead",
    )
    assert terminal["outcome"] == "rolled_back"
    assert tx.hash_tree(scenario.install) == scenario.intent.old_tree
    assert not os.path.lexists(scenario.recovery / "activation.lock")


def test_published_journal_sync_error_keeps_repair_authority(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = _scenario(tmp_path)
    paths = _paths(scenario)
    real_sync = tx._sync_dir
    failed = False

    def fail_first_published_journal_sync(path: Path) -> None:
        nonlocal failed
        if not failed and path == paths.directory and os.path.lexists(paths.journal):
            failed = True
            raise OSError("injected journal directory sync failure")
        real_sync(path)

    monkeypatch.setattr(tx, "_sync_dir", fail_first_published_journal_sync)
    with pytest.raises(tx.TransactionError, match="timed out"):
        tx.run_activation(scenario.intent, claim_timeout=0.02)

    assert failed
    assert os.path.lexists(scenario.recovery / "activation.lock")
    assert tx.load_journal(paths, scenario.intent)["phase"] == "rolled_back"
    terminal = tx.repair_transaction(
        scenario.recovery,
        scenario.intent.transaction,
        repairer=tx.ProcessIdentity.current("journal-sync-repairer-012345"),
        process_probe=lambda _identity: "dead",
    )
    assert terminal["outcome"] == "rolled_back"
    assert not os.path.lexists(scenario.recovery / "activation.lock")
    assert (
        tx.preflight_update(
            scenario.project,
            scenario.install,
            scenario.intent.editor,
        )
        == scenario.recovery
    )


def test_repair_finishes_success_after_claim_rename_crash(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    actor = Actor(scenario.intent, readiness_timeout=2, claim_timeout=1)
    _wait_for_phase(scenario, actor, "stage_live")
    tx.write_readiness(scenario.intent)
    paths = _paths(scenario)
    _wait_until(lambda: os.path.lexists(paths.result))

    with pytest.raises(SimulatedCrash, match="result_to_claim:after"):
        tx.claim_result(
            scenario.intent,
            failpoints=CrashAfter("result_to_claim", "after"),  # type: ignore[arg-type]
        )
    assert os.path.lexists(paths.claim)
    assert os.path.lexists(scenario.recovery / "activation.lock")

    terminal = tx.repair_transaction(
        scenario.recovery,
        scenario.intent.transaction,
        repairer=tx.ProcessIdentity(os.getpid(), "repair-test", "repairer-0123456789"),
        process_probe=lambda _identity: "dead",
    )
    assert terminal["outcome"] == "success"
    assert not os.path.lexists(paths.result)
    assert not os.path.lexists(scenario.recovery / "activation.lock")
    actor.thread.join(2)
    assert actor.error is None
    assert actor.result == terminal


def test_repair_takeover_requires_dead_prior_repairer_and_preserves_claim(
    tmp_path: Path,
) -> None:
    scenario = _scenario(tmp_path)
    with pytest.raises(SimulatedCrash):
        tx.run_activation(
            scenario.intent,
            failpoints=CrashAfter("stage_to_live", "after"),  # type: ignore[arg-type]
        )
    first = tx.ProcessIdentity(os.getpid(), "first-repair", "first-repairer-012345")
    with pytest.raises(SimulatedCrash, match="repair_claim:after"):
        tx.repair_transaction(
            scenario.recovery,
            scenario.intent.transaction,
            repairer=first,
            process_probe=lambda _identity: "dead",
            failpoints=CrashAfter("repair_claim", "after"),  # type: ignore[arg-type]
        )

    with pytest.raises(tx.RepairRefused, match="prior repair runner"):
        tx.repair_transaction(
            scenario.recovery,
            scenario.intent.transaction,
            repairer=tx.ProcessIdentity(os.getpid(), "second-repair", "second-repairer-01234"),
            process_probe=lambda identity: "alive" if identity == first else "dead",
        )

    terminal = tx.repair_transaction(
        scenario.recovery,
        scenario.intent.transaction,
        repairer=tx.ProcessIdentity(os.getpid(), "second-repair", "second-repairer-01234"),
        process_probe=lambda _identity: "dead",
    )
    assert terminal["outcome"] == "rolled_back"
    directory = _paths(scenario).directory
    assert os.path.lexists(directory / "repair-claim.json")
    assert len(list(directory.glob("repair-claim-*.json"))) == 1


@pytest.mark.parametrize("state", ["alive", "unknown"])
def test_repair_refuses_process_identities_not_proven_gone(tmp_path: Path, state: str) -> None:
    scenario = _scenario(tmp_path, f"{state:0<16}")
    with pytest.raises(SimulatedCrash):
        tx.run_activation(
            scenario.intent,
            failpoints=CrashAfter("activation_lock", "after"),  # type: ignore[arg-type]
        )
    with pytest.raises(tx.RepairRefused, match=f"runner={state}"):
        tx.repair_transaction(
            scenario.recovery,
            scenario.intent.transaction,
            process_probe=lambda identity: state if identity == scenario.intent.runner else "dead",
        )
    assert os.path.lexists(scenario.recovery / "activation.lock")


def test_repair_accepts_dead_editor_and_reused_runner_fingerprint(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    editor_process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    try:
        editor = tx.ProcessIdentity(
            editor_process.pid,
            tx.process_start_fingerprint(editor_process.pid)
            or pytest.fail("missing editor fingerprint"),
            "short-lived-editor-012345",
        )
        runner = tx.ProcessIdentity(
            os.getpid(),
            "deliberately-reused-start-fingerprint",
            "reused-runner-012345",
        )
        intent = tx.Intent.create(
            transaction=scenario.intent.transaction,
            project_root=scenario.project,
            install_root=scenario.install,
            recovery=scenario.recovery,
            stage_root=scenario.stage,
            from_version=scenario.intent.from_version,
            to_version=scenario.intent.to_version,
            manifest_sha256=scenario.intent.manifest_sha256,
            editor=editor,
            runner=runner,
        )
        paths = _paths(scenario)
        tx.replace_record(
            paths.directory / "prepare-claim.json",
            tx._prepare_claim_record(
                transaction=intent.transaction,
                project=intent.project_root,
                install=intent.install_root,
                recovery=intent.recovery_root,
                stage=intent.stage_root,
                old_tree=intent.old_tree,
                editor=intent.editor,
            ),
        )
        tx.replace_record(paths.prepared, tx._prepared_from_intent(intent))
        with pytest.raises(SimulatedCrash):
            tx.run_activation(
                intent,
                failpoints=CrashAfter("stage_to_live", "after"),  # type: ignore[arg-type]
            )
    finally:
        editor_process.terminate()
        editor_process.wait(timeout=3)

    assert tx.probe_process(editor) == "dead"
    assert tx.probe_process(runner) == "reused"
    terminal = tx.repair_transaction(
        scenario.recovery,
        scenario.intent.transaction,
        repairer=tx.ProcessIdentity.current("reused-repairer-012345"),
    )
    assert terminal["outcome"] == "rolled_back"
    assert tx.hash_tree(scenario.install) == intent.old_tree


def test_second_repair_can_archive_prior_terminal_and_finish_transient_rollback(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = _scenario(tmp_path)
    with pytest.raises(SimulatedCrash, match="stage_to_live:after"):
        tx.run_activation(
            scenario.intent,
            failpoints=CrashAfter("stage_to_live", "after"),  # type: ignore[arg-type]
        )
    real_rename = tx._rename_tree
    failed = False

    def fail_backup_once(source: Path, target: Path) -> None:
        nonlocal failed
        if source == scenario.intent.backup_root and not failed:
            failed = True
            raise OSError("transient restore failure")
        real_rename(source, target)

    monkeypatch.setattr(tx, "_rename_tree", fail_backup_once)
    with pytest.raises(tx.RepairRefused, match="could not restore"):
        tx.repair_transaction(
            scenario.recovery,
            scenario.intent.transaction,
            repairer=tx.ProcessIdentity.current("first-repairer-012345"),
            process_probe=lambda _identity: "dead",
        )

    terminal = tx.repair_transaction(
        scenario.recovery,
        scenario.intent.transaction,
        repairer=tx.ProcessIdentity.current("second-repairer-012345"),
        process_probe=lambda _identity: "dead",
    )
    assert terminal["outcome"] == "rolled_back"
    assert tx.hash_tree(scenario.install) == scenario.intent.old_tree
    assert len(list(_paths(scenario).directory.glob("pre-repair-terminal-*.json"))) == 1


def test_real_failpoint_requires_capability_and_authenticated_decision(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    token = b"qualification-only-secret-token-32"
    capability = tx.write_failpoint_capability(
        scenario.intent,
        effect="stage_to_live",
        when="after",
        token=token,
    )
    controls = tx.Failpoints(capability, token, scenario.intent, timeout=2)
    actor = Actor(
        scenario.intent,
        readiness_timeout=2,
        claim_timeout=2,
        failpoints=controls,
    )
    barrier = scenario.recovery / "failpoint-barrier.json"
    _wait_until(lambda: os.path.lexists(barrier))
    assert token not in capability.read_bytes()
    assert token not in barrier.read_bytes()
    with pytest.raises(tx.TransactionError, match="token does not match"):
        tx.write_failpoint_decision(
            scenario.recovery, token=b"wrong-token-that-is-at-least-32-bytes", action="fail"
        )
    tx.write_failpoint_decision(scenario.recovery, token=token, action="fail")

    paths = _paths(scenario)
    _wait_until(lambda: os.path.lexists(paths.result))
    assert tx.validate_terminal(paths.result, scenario.intent)["outcome"] == "rolled_back"
    tx.claim_result(scenario.intent)
    assert actor.finish()["outcome"] == "rolled_back"
    assert not os.path.lexists(capability)


@pytest.mark.parametrize("occurrence", [1, 2, 3])
def test_real_failpoint_is_one_shot_and_cleans_handled_capability(
    tmp_path: Path, occurrence: int
) -> None:
    scenario = _scenario(tmp_path)
    token = bytes.fromhex("31" * 32)
    capability = tx.write_failpoint_capability(
        scenario.intent,
        effect="journal_commit",
        when="after",
        token=token,
        occurrence=occurrence,
    )
    controls = tx.Failpoints(capability, token, scenario.intent, timeout=2)
    for _ in range(occurrence - 1):
        controls.barrier("journal_commit", "before")
        controls.barrier("intent_commit", "after")
        controls.barrier("journal_commit", "after")
        assert not os.path.lexists(scenario.recovery / "failpoint-barrier.json")
    errors: list[BaseException] = []

    def cross_twice() -> None:
        try:
            controls.barrier("journal_commit", "after")
            controls.barrier("journal_commit", "after")
        except BaseException as exc:
            errors.append(exc)

    worker = threading.Thread(target=cross_twice, daemon=True)
    worker.start()
    barrier = scenario.recovery / "failpoint-barrier.json"
    _wait_until(lambda: os.path.lexists(barrier))
    assert tx.load_record(barrier)["sequence"] == occurrence
    tx.write_failpoint_decision(scenario.recovery, token=token, action="continue")
    worker.join(2)

    assert not worker.is_alive()
    assert errors == []
    assert controls.sequence == occurrence
    assert controls.spent
    assert not os.path.lexists(capability)
    assert not os.path.lexists(barrier)
    assert not os.path.lexists(scenario.recovery / "failpoint-decision.json")


def test_real_failpoint_timeout_is_bounded_and_cleans_handled_files(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    token = bytes.fromhex("31" * 32)
    capability = tx.write_failpoint_capability(
        scenario.intent,
        effect="intent_commit",
        when="after",
        token=token,
    )
    controls = tx.Failpoints(capability, token, scenario.intent, timeout=0.02)

    with pytest.raises(tx.TransactionError, match="timed out"):
        controls.barrier("intent_commit", "after")

    assert not os.path.lexists(capability)
    assert not os.path.lexists(scenario.recovery / "failpoint-barrier.json")
    with pytest.raises(tx.TransactionError, match="between 0 and 300s"):
        tx.Failpoints(capability, token, scenario.intent, timeout=float("inf"))


@pytest.mark.parametrize("stale_decision", [False, True])
def test_real_failpoint_refusal_preserves_preexisting_fixed_name_evidence(
    tmp_path: Path, stale_decision: bool
) -> None:
    scenario = _scenario(tmp_path)
    token = bytes.fromhex("31" * 32)
    capability = tx.write_failpoint_capability(
        scenario.intent,
        effect="intent_commit",
        when="after",
        token=token,
    )
    controls = tx.Failpoints(capability, token, scenario.intent, timeout=2)
    barrier = scenario.recovery / "failpoint-barrier.json"
    decision = scenario.recovery / "failpoint-decision.json"
    tx.publish_record(barrier, {"stale": "barrier"})
    if stale_decision:
        tx.publish_record(decision, {"stale": "decision"})
    before = {path: path.read_bytes() for path in (barrier, decision) if path.exists()}

    with pytest.raises(tx.TransactionError, match="already exists"):
        controls.barrier("intent_commit", "after")

    assert {path: path.read_bytes() for path in before} == before
    assert not os.path.lexists(capability)


def test_real_failpoint_cleans_invalid_response_to_its_published_barrier(
    tmp_path: Path,
) -> None:
    scenario = _scenario(tmp_path)
    token = bytes.fromhex("31" * 32)
    capability = tx.write_failpoint_capability(
        scenario.intent,
        effect="intent_commit",
        when="after",
        token=token,
    )
    controls = tx.Failpoints(capability, token, scenario.intent, timeout=2)
    errors: list[BaseException] = []

    def cross() -> None:
        try:
            controls.barrier("intent_commit", "after")
        except BaseException as exc:
            errors.append(exc)

    worker = threading.Thread(target=cross, daemon=True)
    worker.start()
    barrier = scenario.recovery / "failpoint-barrier.json"
    decision = scenario.recovery / "failpoint-decision.json"
    _wait_until(lambda: os.path.lexists(barrier))
    tx.publish_record(decision, {"invalid": "response"})
    worker.join(2)

    assert not worker.is_alive()
    assert len(errors) == 1
    assert isinstance(errors[0], tx.TransactionError)
    assert all(not os.path.lexists(path) for path in (capability, barrier, decision))


def _qualification_environment(
    token_hex: str = "31" * 32,
    *,
    effect: str = "intent_commit",
    when: str = "after",
    timeout: str = "2.5",
) -> dict[str, str]:
    return {
        tx.QUALIFICATION_FAILPOINT_TOKEN_ENV: token_hex,
        tx.QUALIFICATION_FAILPOINT_EFFECT_ENV: effect,
        tx.QUALIFICATION_FAILPOINT_WHEN_ENV: when,
        tx.QUALIFICATION_FAILPOINT_TIMEOUT_ENV: timeout,
    }


def _activate_arguments(scenario: Scenario) -> list[str]:
    return [
        "activate",
        "--project",
        str(scenario.project),
        "--install",
        str(scenario.install),
        "--recovery-root",
        str(scenario.recovery),
        "--stage",
        str(scenario.stage),
        "--transaction",
        scenario.intent.transaction,
        "--from-version",
        scenario.intent.from_version,
        "--to-version",
        scenario.intent.to_version,
        "--manifest-sha256",
        scenario.intent.manifest_sha256,
        "--editor-pid",
        str(scenario.intent.editor.pid),
        "--editor-nonce",
        scenario.intent.editor.nonce,
        "--readiness-timeout",
        "5",
        "--claim-timeout",
        "5",
    ]


def _migration_arguments(scenario: Scenario) -> list[str]:
    return [
        "complete-migration",
        "--project",
        str(scenario.project),
        "--install",
        str(scenario.install),
        "--recovery-root",
        str(scenario.recovery),
        "--transaction",
        scenario.intent.transaction,
        "--editor-pid",
        str(scenario.intent.editor.pid),
        "--editor-nonce",
        scenario.intent.editor.nonce,
    ]


@pytest.mark.parametrize("effect", sorted(tx.MIGRATION_FAILPOINT_EFFECTS))
@pytest.mark.parametrize("when", ["before", "after"])
@pytest.mark.parametrize("action", ["continue", "fail", "kill"])
def test_complete_migration_cli_external_barrier_preserves_authority_and_retries(
    tmp_path: Path,
    effect: str,
    when: str,
    action: str,
) -> None:
    scenario = _scenario(tmp_path)
    assert _claim_success_without_migration(scenario)["outcome"] == "success"
    tx.EditorLeases(scenario.recovery, scenario.project, scenario.install).acquire(
        scenario.intent.editor
    )
    paths = _paths(scenario)
    authoritative = {
        path: path.read_bytes()
        for path in (paths.intent, paths.journal, paths.claim, paths.readiness)
    }
    token_hex = "37" * 32
    token = bytes.fromhex(token_hex)
    command = [sys.executable, "-m", "godot_ai.update_transaction", *_migration_arguments(scenario)]
    assert token_hex not in command
    environment = {
        **{
            key: value
            for key, value in os.environ.items()
            if key not in tx.QUALIFICATION_FAILPOINT_ENV
        },
        **_qualification_environment(token_hex, effect=effect, when=when, timeout="30"),
        "PYTHONPATH": str(Path(__file__).parents[2] / "src"),
    }
    process = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment
    )
    barrier = scenario.recovery / "failpoint-barrier.json"
    capability = scenario.recovery / "qualification-capability.json"
    committed = effect == "migration_complete" and when == "after"
    try:
        _wait_until(lambda: barrier.exists() or process.poll() is not None, timeout=30)
        assert barrier.exists(), process.communicate(timeout=5)
        row = tx.load_record(barrier)
        assert (row["effect"], row["when"], row["sequence"]) == (effect, when, 1)
        assert row["intent_sha256"] == tx._intent_sha(scenario.intent)
        assert row["project_root"] == str(scenario.project)
        assert row["install_root"] == str(scenario.install)
        assert row["recovery_root"] == str(scenario.recovery)
        assert paths.migration_complete.exists() == committed
        temporaries = list(paths.directory.glob(".record-*.tmp"))
        assert len(temporaries) == (
            1 if effect.endswith("temporary_write") and when == "after" else 0
        )
        if temporaries:
            assert tx.load_record(temporaries[0]) == tx._migration_complete_record(
                scenario.intent,
                tx.validate_terminal(paths.claim, scenario.intent),
                scenario.intent.editor,
            )
        if action == "kill":
            process.kill()
        else:
            with pytest.raises(tx.TransactionError, match="token does not match"):
                tx.write_failpoint_decision(
                    scenario.recovery, token=bytes.fromhex("38" * 32), action=action
                )
            assert not (scenario.recovery / "failpoint-decision.json").exists()
            tx.write_failpoint_decision(scenario.recovery, token=token, action=action)
        stdout, stderr = process.communicate(timeout=30)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

    if action == "continue":
        assert process.returncode == 0, stderr
        assert tx.json.loads(stdout)["status"] == "migration_complete"
        assert stderr == b""
    elif action == "fail":
        assert process.returncode == 2
        assert f"qualification failpoint: {effect}:{when}".encode() in stderr
        assert stdout == b""
    else:
        assert process.returncode != 0
    assert paths.migration_complete.exists() == (committed or action == "continue")
    assert capability.exists() == (action == "kill")
    assert barrier.exists() == (action == "kill")
    retained = {
        path: path.read_bytes() for path in (capability, barrier, *temporaries) if path.exists()
    }
    assert len(list(paths.directory.glob(".record-*.tmp"))) == (
        len(temporaries) if action == "kill" else 0
    )
    startup = tx.startup_barrier(
        scenario.project,
        scenario.install,
        editor_pid=scenario.intent.editor.pid,
        editor_nonce=scenario.intent.editor.nonce,
    )
    if committed or action == "continue":
        assert startup == {"status": "none"}
    else:
        assert startup["status"] == "migration_pending"
        assert startup["transaction"] == scenario.intent.transaction

    # Retry without qualification controls. Neither an orphan temp nor the
    # killed controller's retained records can impersonate completion.
    for name in tx.QUALIFICATION_FAILPOINT_ENV:
        environment.pop(name, None)
    retry = subprocess.run(command, capture_output=True, env=environment, timeout=30)
    assert retry.returncode == 0, retry.stderr
    assert tx.json.loads(retry.stdout)["status"] == "migration_complete"
    tx.validate_migration_complete(paths, scenario.intent)
    for path, data in {**authoritative, **retained}.items():
        assert path.read_bytes() == data
    assert tx.hash_tree(scenario.install) == scenario.intent.new_tree
    assert tx.hash_tree(scenario.intent.backup_root) == scenario.intent.old_tree
    assert not tx.ActivationLock(scenario.recovery).path.exists()
    assert not paths.result.exists()
    assert tx.startup_barrier(
        scenario.project,
        scenario.install,
        editor_pid=scenario.intent.editor.pid,
        editor_nonce=scenario.intent.editor.nonce,
    ) == {"status": "none"}
    output = stdout + stderr + retry.stdout + retry.stderr
    assert token not in output and token_hex.encode() not in output
    for path in scenario.recovery.rglob("*"):
        if path.is_file():
            data = path.read_bytes()
            assert token not in data and token_hex.encode() not in data, path


@pytest.mark.parametrize("state", ["unleased", "tampered", "already_complete", "unreachable"])
def test_complete_migration_cli_never_arms_before_validation_or_after_completion(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capfd: pytest.CaptureFixture[str],
    state: str,
) -> None:
    scenario = _scenario(tmp_path)
    assert _claim_success_without_migration(scenario)["outcome"] == "success"
    if state != "unleased":
        tx.EditorLeases(scenario.recovery, scenario.project, scenario.install).acquire(
            scenario.intent.editor
        )
    if state == "already_complete":
        assert tx.main(_migration_arguments(scenario)) == 0
    if state == "tampered":
        (scenario.install / "plugin.cfg").write_text("version=tampered\n")
    token_hex = "39" * 32
    for name, value in _qualification_environment(
        token_hex,
        effect="intent_commit" if state == "unreachable" else "migration_complete",
    ).items():
        monkeypatch.setenv(name, value)
    assert tx.main(_migration_arguments(scenario)) == (
        0 if state in {"already_complete", "unreachable"} else 2
    )
    output = capfd.readouterr()
    assert token_hex not in output.out + output.err
    assert all(name not in os.environ for name in tx.QUALIFICATION_FAILPOINT_ENV)
    assert not (scenario.recovery / "qualification-capability.json").exists()
    assert not (scenario.recovery / "failpoint-barrier.json").exists()


def test_complete_migration_library_is_environment_inert_and_rejects_two_controllers(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    scenario = _scenario(tmp_path)
    _claim_success_without_migration(scenario)
    tx.EditorLeases(scenario.recovery, scenario.project, scenario.install).acquire(
        scenario.intent.editor
    )
    for name, value in _qualification_environment(effect="migration_complete").items():
        monkeypatch.setenv(name, value)
    with pytest.raises(tx.TransactionError, match="only one failpoint controller"):
        tx.complete_migration(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            scenario.intent.editor,
            failpoints=CrashAfter("migration_complete", "after"),
            qualification_factory=lambda intent: tx.command_failpoints(
                intent, tx.MIGRATION_FAILPOINT_EFFECTS
            ),
        )
    assert (
        tx.complete_migration(
            scenario.project,
            scenario.install,
            scenario.recovery,
            scenario.intent.transaction,
            scenario.intent.editor,
        )["status"]
        == "migration_complete"
    )
    assert os.environ[tx.QUALIFICATION_FAILPOINT_EFFECT_ENV] == "migration_complete"
    assert not (scenario.recovery / "qualification-capability.json").exists()


def test_activate_consumes_but_does_not_arm_migration_effects(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    scenario = _scenario(tmp_path)
    for effect in tx.MIGRATION_FAILPOINT_EFFECTS | tx.REPAIR_FAILPOINT_EFFECTS:
        for name, value in _qualification_environment(effect=effect).items():
            monkeypatch.setenv(name, value)
        assert tx.activate_failpoints_from_environment(scenario.intent) is None
        assert all(name not in os.environ for name in tx.QUALIFICATION_FAILPOINT_ENV)
        assert not (scenario.recovery / "qualification-capability.json").exists()


@pytest.mark.parametrize("mode", ["incomplete", "timeout", "unreached_occurrence"])
def test_migration_cli_cleans_failed_or_unspent_environment_capability(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capfd: pytest.CaptureFixture[str],
    mode: str,
) -> None:
    scenario = _scenario(tmp_path)
    _claim_success_without_migration(scenario)
    tx.EditorLeases(scenario.recovery, scenario.project, scenario.install).acquire(
        scenario.intent.editor
    )
    for name in tx.QUALIFICATION_FAILPOINT_ENV:
        monkeypatch.delenv(name, raising=False)
    environment = _qualification_environment(
        effect="migration_complete", when="before", timeout="0.01"
    )
    if mode == "incomplete":
        del environment[tx.QUALIFICATION_FAILPOINT_TIMEOUT_ENV]
    if mode == "unreached_occurrence":
        environment[tx.QUALIFICATION_FAILPOINT_OCCURRENCE_ENV] = "2"
    for name, value in environment.items():
        monkeypatch.setenv(name, value)
    assert tx.main(_migration_arguments(scenario)) == (0 if mode == "unreached_occurrence" else 2)
    assert _paths(scenario).migration_complete.exists() == (mode == "unreached_occurrence")
    assert all(name not in os.environ for name in tx.QUALIFICATION_FAILPOINT_ENV)
    for name in (
        "qualification-capability.json",
        "failpoint-barrier.json",
        "failpoint-decision.json",
    ):
        assert not (scenario.recovery / name).exists()
    captured = capfd.readouterr()
    assert environment[tx.QUALIFICATION_FAILPOINT_TOKEN_ENV] not in captured.out + captured.err
    if mode == "incomplete":
        assert "environment is incomplete" in captured.err
    if mode == "timeout":
        assert "external failpoint decision" in captured.err


def test_python_and_gdscript_qualification_vocabulary_is_exactly_synchronized() -> None:
    path = (
        Path(__file__).parents[2]
        / "plugin"
        / "addons"
        / "godot_ai"
        / "utils"
        / "update_qualification_barrier.gd"
    )
    source = path.read_text(encoding="utf-8")

    def string_set(name: str) -> set[str]:
        match = re.search(rf"const {name} := \[(.*?)\]", source, re.DOTALL)
        assert match is not None
        return set(re.findall(r'"([a-z][a-z0-9_]*)"', match.group(1)))

    coordinator = string_set("COORDINATOR_EFFECTS")
    known = string_set("KNOWN_EFFECTS") | coordinator
    assert coordinator == tx.COORDINATOR_FAILPOINT_EFFECTS
    assert known == tx.ACTOR_FAILPOINT_EFFECTS | tx.COORDINATOR_FAILPOINT_EFFECTS

    timeout_match = re.search(r'^const TIMEOUT_PATTERN := "(.*)"$', source, re.MULTILINE)
    maximum_match = re.search(r"^const MAX_TIMEOUT_SECONDS := ([0-9.]+)$", source, re.MULTILINE)
    assert timeout_match is not None and maximum_match is not None
    gdscript_pattern = tx.json.loads(f'"{timeout_match.group(1)}"')
    assert gdscript_pattern == f"^{tx.QUALIFICATION_TIMEOUT.pattern}$"
    assert float(maximum_match.group(1)) == tx.MAX_QUALIFICATION_TIMEOUT


def test_activate_failpoint_environment_is_complete_consumed_and_production_inert(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = _scenario(tmp_path)
    for name in tx.QUALIFICATION_FAILPOINT_ENV:
        monkeypatch.delenv(name, raising=False)

    assert tx.activate_failpoints_from_environment(scenario.intent) is None
    assert not os.path.lexists(scenario.recovery / "qualification-capability.json")

    monkeypatch.setenv(tx.QUALIFICATION_FAILPOINT_TOKEN_ENV, "31" * 32)
    with pytest.raises(tx.TransactionError, match="environment is incomplete") as caught:
        tx.activate_failpoints_from_environment(scenario.intent)
    assert "31" * 32 not in str(caught.value)
    assert all(name not in os.environ for name in tx.QUALIFICATION_FAILPOINT_ENV)
    assert not os.path.lexists(scenario.recovery / "qualification-capability.json")


def test_activate_cli_scrubs_qualification_environment_when_intent_creation_refuses(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capfd: pytest.CaptureFixture[str],
) -> None:
    scenario = _scenario(tmp_path)
    token_hex = "31" * 32
    for name, value in _qualification_environment(token_hex).items():
        monkeypatch.setenv(name, value)
    arguments = _activate_arguments(scenario)
    arguments[arguments.index("--stage") + 1] = str(tmp_path / "missing-stage")

    assert tx.main(arguments) == 2

    captured = capfd.readouterr()
    assert "path does not exist" in captured.err
    assert token_hex not in captured.out + captured.err
    assert all(name not in os.environ for name in tx.QUALIFICATION_FAILPOINT_ENV)
    assert not os.path.lexists(scenario.recovery / "qualification-capability.json")
    assert not os.path.lexists(_paths(scenario).intent)


def test_direct_actor_capability_writer_rejects_unknown_and_coordinator_effects(
    tmp_path: Path,
) -> None:
    scenario = _scenario(tmp_path)
    for effect in ("intent_commti", "coordinator_enable"):
        with pytest.raises(tx.TransactionError, match="not reachable from an actor command"):
            tx.write_failpoint_capability(
                scenario.intent,
                effect=effect,
                when="after",
                token=bytes.fromhex("31" * 32),
            )
    assert not os.path.lexists(scenario.recovery / "qualification-capability.json")


@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        (tx.QUALIFICATION_FAILPOINT_TOKEN_ENV, "AB" * 32, "lowercase hexadecimal"),
        (tx.QUALIFICATION_FAILPOINT_EFFECT_ENV, "intent_commti", "effect is unknown"),
        (tx.QUALIFICATION_FAILPOINT_WHEN_ENV, "during", "before or after"),
        (tx.QUALIFICATION_FAILPOINT_TIMEOUT_ENV, "0", "between 0 and 300s"),
        (tx.QUALIFICATION_FAILPOINT_TIMEOUT_ENV, "1e3", "positive decimal"),
        (tx.QUALIFICATION_FAILPOINT_TIMEOUT_ENV, "301", "between 0 and 300s"),
        (tx.QUALIFICATION_FAILPOINT_TIMEOUT_ENV, "9" * 400, "between 0 and 300s"),
        *[
            (tx.QUALIFICATION_FAILPOINT_OCCURRENCE_ENV, value, "occurrence")
            for value in ("", "0", "-1", "01", "1.0", "10000", "9" * 400)
        ],
    ],
)
def test_activate_failpoint_environment_rejects_invalid_values_without_arming(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    field: str,
    value: str,
    message: str,
) -> None:
    scenario = _scenario(tmp_path)
    environment = _qualification_environment()
    environment[field] = value
    for name, configured in environment.items():
        monkeypatch.setenv(name, configured)

    with pytest.raises(tx.TransactionError, match=message):
        tx.activate_failpoints_from_environment(scenario.intent)

    assert all(name not in os.environ for name in tx.QUALIFICATION_FAILPOINT_ENV)
    assert not os.path.lexists(scenario.recovery / "qualification-capability.json")


def test_activate_environment_arms_actor_effect_and_consumes_coordinator_effect(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    actor_scenario = _scenario(tmp_path, "actor-effect-012345")
    token_hex = "31" * 32
    for name, value in _qualification_environment(token_hex).items():
        monkeypatch.setenv(name, value)

    controls = tx.activate_failpoints_from_environment(actor_scenario.intent)

    assert isinstance(controls, tx.Failpoints)
    capability = actor_scenario.recovery / "qualification-capability.json"
    assert tx.load_record(capability)["effect"] == "intent_commit"
    assert token_hex.encode("ascii") not in capability.read_bytes()
    assert all(name not in os.environ for name in tx.QUALIFICATION_FAILPOINT_ENV)

    coordinator_scenario = _scenario(tmp_path, "coordinator-effect-01")
    environment = _qualification_environment(effect="coordinator_enable")
    for name, value in environment.items():
        monkeypatch.setenv(name, value)

    assert tx.activate_failpoints_from_environment(coordinator_scenario.intent) is None
    assert not os.path.lexists(coordinator_scenario.recovery / "qualification-capability.json")
    assert all(name not in os.environ for name in tx.QUALIFICATION_FAILPOINT_ENV)


def test_coordinator_failpoint_decision_is_bound_and_authenticated(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    token = bytes.fromhex("4a" * 32)
    barrier_path = scenario.recovery / "coordinator-failpoint-barrier.json"
    decision_path = scenario.recovery / "coordinator-failpoint-decision.json"
    barrier = {
        "effect": "coordinator_disable_verified",
        "install_root": str(scenario.install),
        "project_root": str(scenario.project),
        "record": "coordinator_failpoint_barrier",
        "recovery_root": str(scenario.recovery),
        "schema_version": 1,
        "sequence": 7,
        "token_sha256": tx.hashlib.sha256(token).hexdigest(),
        "transaction": scenario.intent.transaction,
        "when": "after",
    }
    barrier_path.write_bytes(tx.json.dumps(barrier, separators=(",", ":")).encode("utf-8"))
    if os.name != "nt":
        barrier_path.chmod(0o600)
    assert barrier_path.read_bytes() != tx.canonical_json(barrier)

    with pytest.raises(tx.TransactionError, match="token does not match"):
        tx.write_coordinator_failpoint_decision(
            scenario.recovery, token=bytes.fromhex("5b" * 32), action="fail"
        )
    assert not os.path.lexists(decision_path)
    with pytest.raises(tx.TransactionError, match="continue or fail"):
        tx.write_coordinator_failpoint_decision(scenario.recovery, token=token, action="proceed")
    assert not os.path.lexists(decision_path)

    tx.write_coordinator_failpoint_decision(scenario.recovery, token=token, action="continue")

    decision = tx.load_record(decision_path)
    message = (
        "godot-ai-coordinator-failpoint-v1\n"
        f"{scenario.intent.transaction}\n{scenario.project}\n{scenario.install}\n"
        f"{scenario.recovery}\ncoordinator_disable_verified\nafter\n7\ncontinue\n"
    ).encode("utf-8")
    assert decision == {
        **barrier,
        "action": "continue",
        "mac": tx.hmac.new(token, message, tx.hashlib.sha256).hexdigest(),
        "record": "coordinator_failpoint_decision",
    }
    raw = decision_path.read_bytes()
    assert token not in raw
    assert token.hex().encode("ascii") not in raw


def test_coordinator_failpoint_decision_rejects_unknown_effect_and_unbound_root(
    tmp_path: Path,
) -> None:
    scenario = _scenario(tmp_path)
    token = bytes.fromhex("4a" * 32)
    barrier_path = scenario.recovery / "coordinator-failpoint-barrier.json"
    barrier = {
        "effect": "coordinator_typo",
        "install_root": str(scenario.install),
        "project_root": str(scenario.project),
        "record": "coordinator_failpoint_barrier",
        "recovery_root": str(scenario.recovery),
        "schema_version": 1,
        "sequence": 1,
        "token_sha256": tx.hashlib.sha256(token).hexdigest(),
        "transaction": scenario.intent.transaction,
        "when": "before",
    }
    tx.publish_record(barrier_path, barrier)
    with pytest.raises(tx.TransactionError, match="effect is unknown"):
        tx.write_coordinator_failpoint_decision(scenario.recovery, token=token, action="fail")

    barrier["effect"] = "coordinator_enable"
    barrier["recovery_root"] = str(tmp_path / "other-recovery")
    tx.replace_record(barrier_path, barrier)
    with pytest.raises(tx.TransactionError, match="roots are not canonical and bound"):
        tx.write_coordinator_failpoint_decision(scenario.recovery, token=token, action="fail")


def test_activate_cli_cleans_capability_when_prepared_state_rejects_intent(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capfd: pytest.CaptureFixture[str],
) -> None:
    scenario = _scenario(tmp_path)
    token_hex = "31" * 32
    for name, value in _qualification_environment(token_hex).items():
        monkeypatch.setenv(name, value)
    arguments = _activate_arguments(scenario)
    arguments[arguments.index("--to-version") + 1] = "4.0.2"

    assert tx.main(arguments) == 2

    captured = capfd.readouterr()
    assert "signed prepared release" in captured.err
    assert token_hex not in captured.out + captured.err
    assert all(name not in os.environ for name in tx.QUALIFICATION_FAILPOINT_ENV)
    assert not os.path.lexists(scenario.recovery / "qualification-capability.json")
    assert not os.path.lexists(_paths(scenario).intent)
    assert tx.hash_tree(scenario.install) == scenario.intent.old_tree


@pytest.mark.parametrize(
    ("effect", "expect_barrier", "occurrence", "when"),
    [
        (effect, True, occurrence, when)
        for effect, occurrences in (
            ("intent_commit", (1,)),
            ("intent_temporary_write", (1,)),
            ("activation_lock", (1,)),
            ("journal_commit", (1, 2, 3)),
            ("journal_temporary_write", (1, 2, 3)),
            ("live_to_backup", (1,)),
            ("stage_to_live", (1,)),
            ("result_commit", (1,)),
            ("terminal_temporary_write", (1,)),
        )
        for occurrence in occurrences
        for when in ("before", "after")
    ] + [("quarantine_live", False, 1, "after")],
)
def test_activate_cli_uses_authenticated_environment_failpoint_without_secret_leak(
    tmp_path: Path,
    effect: str,
    expect_barrier: bool,
    occurrence: int,
    when: str,
) -> None:
    scenario = _scenario(tmp_path)
    token_hex = "31" * 32
    token = bytes.fromhex(token_hex)
    command = [
        sys.executable,
        "-m",
        "godot_ai.update_transaction",
        *_activate_arguments(scenario),
    ]
    assert token_hex not in command
    environment = {
        **os.environ,
        **_qualification_environment(token_hex, effect=effect, when=when, timeout="30"),
        tx.QUALIFICATION_FAILPOINT_OCCURRENCE_ENV: str(occurrence),
        "PYTHONPATH": str(Path(__file__).parents[2] / "src"),
    }
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    try:
        barrier = scenario.recovery / "failpoint-barrier.json"
        capability = scenario.recovery / "qualification-capability.json"
        _wait_until(lambda: os.path.lexists(capability), timeout=30)
        assert token_hex.encode("ascii") not in capability.read_bytes()
        terminal_barrier = effect in {"result_commit", "terminal_temporary_write"} or (
            effect in {"journal_commit", "journal_temporary_write"} and occurrence == 3
        )
        if expect_barrier and not terminal_barrier:
            _wait_until(lambda: os.path.lexists(barrier), timeout=30)
            observed = tx.load_record(barrier)
            assert (observed["sequence"], observed["effect"], observed["when"]) == (
                occurrence, effect, when
            )
            assert token not in barrier.read_bytes()
            tx.write_failpoint_decision(scenario.recovery, token=token, action="continue")
        else:
            assert not os.path.lexists(barrier)

        paths = _paths(scenario)
        _wait_until(lambda: os.path.lexists(paths.intent), timeout=30)

        def stage_is_live() -> bool:
            if not os.path.lexists(paths.journal):
                return False
            try:
                return tx.load_record(paths.journal)["phase"] == "stage_live"
            except PermissionError:
                # Windows can briefly deny a read while the actor atomically
                # replaces the journal. Poll through that sharing window; a
                # durable denial still fails at the enclosing deadline.
                return False
            except tx.TransactionError as exc:
                # This is only the phase poll. Full validation below still
                # rejects a durable or malicious hard link.
                if str(exc).endswith(
                    (
                        "record changed before reading",
                        "record has an unexpected hard link",
                    )
                ):
                    return False
                raise

        _wait_until(stage_is_live, timeout=30)
        # Intent parsing checks filesystem identity. Wait until the actor has
        # finished both renames, then validate the intent and journal together.
        actual_intent = tx.load_intent(paths)
        assert tx.load_journal(paths, actual_intent)["phase"] == "stage_live"
        tx.write_readiness(actual_intent)
        if terminal_barrier:
            _wait_until(lambda: os.path.lexists(barrier), timeout=30)
            observed = tx.load_record(barrier)
            assert (observed["sequence"], observed["effect"], observed["when"]) == (
                occurrence, effect, when
            )
            success_committed = effect not in {"journal_commit", "journal_temporary_write"} or (
                effect == "journal_commit" and when == "after"
            )
            assert tx.load_journal(paths, actual_intent)["phase"] == (
                "success" if success_committed else "stage_live"
            )
            assert paths.result.exists() == (effect == "result_commit" and when == "after")
            if effect == "terminal_temporary_write":
                temporaries = list(paths.directory.glob(".record-*.tmp"))
                assert len(temporaries) == (1 if when == "after" else 0)
                if temporaries:
                    assert tx.load_record(temporaries[0]) == tx._terminal_record(
                        actual_intent, outcome="success", writer="normal"
                    )
            tx.write_failpoint_decision(scenario.recovery, token=token, action="continue")
        _wait_until(lambda: os.path.lexists(paths.result), timeout=30)
        claimed = tx.claim_result(actual_intent)
        stdout, stderr = process.communicate(timeout=30)
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    assert process.returncode == 0
    assert stderr == b""
    assert tx.json.loads(stdout) == tx.actor_response(claimed)
    assert claimed["outcome"] == "success"
    assert tx.load_journal(paths, actual_intent)["phase"] == "success"
    assert tx.hash_tree(actual_intent.install_root) == actual_intent.new_tree
    assert tx.hash_tree(actual_intent.backup_root) == actual_intent.old_tree
    assert not actual_intent.stage_root.exists()
    assert not paths.result.exists()
    assert tx.validate_terminal(paths.claim, actual_intent) == claimed
    assert not paths.migration_complete.exists()
    assert not tx.ActivationLock(actual_intent.recovery_root).path.exists()
    assert token not in stdout + stderr
    assert token_hex.encode("ascii") not in stdout + stderr
    assert not os.path.lexists(scenario.recovery / "qualification-capability.json")
    assert not os.path.lexists(scenario.recovery / "failpoint-barrier.json")
    for path in scenario.recovery.rglob("*"):
        if path.is_file():
            data = path.read_bytes()
            assert token not in data, path
            assert token_hex.encode("ascii") not in data, path


@pytest.mark.parametrize(
    ("effect", "when", "occurrence", "live", "stage", "backup", "phase"),
    [
        ("activation_lock", "after", 1, "old", True, False, None),
        ("journal_commit", "before", 1, "old", True, False, None),
        ("journal_commit", "after", 1, "old", True, False, "prepared"),
        ("live_to_backup", "before", 1, "old", True, False, "prepared"),
        ("live_to_backup", "after", 1, None, True, True, "prepared"),
        ("stage_to_live", "before", 1, None, True, True, "prepared"),
        ("stage_to_live", "after", 1, "new", False, True, "prepared"),
        ("journal_commit", "before", 2, "new", False, True, "prepared"),
        ("journal_commit", "after", 2, "new", False, True, "stage_live"),
        ("journal_temporary_write", "before", 1, "old", True, False, None),
        ("journal_temporary_write", "after", 1, "old", True, False, None),
        ("journal_temporary_write", "before", 2, "new", False, True, "prepared"),
        ("journal_temporary_write", "after", 2, "new", False, True, "prepared"),
        ("journal_commit", "before", 3, "new", False, True, "stage_live"),
        ("journal_commit", "after", 3, "new", False, True, "success"),
        ("journal_temporary_write", "before", 3, "new", False, True, "stage_live"),
        ("journal_temporary_write", "after", 3, "new", False, True, "stage_live"),
        ("result_commit", "before", 1, "new", False, True, "success"),
        ("result_commit", "after", 1, "new", False, True, "success"),
        ("terminal_temporary_write", "before", 1, "new", False, True, "success"),
        ("terminal_temporary_write", "after", 1, "new", False, True, "success"),
    ],
)
def test_killed_cli_actor_requires_closed_editor_and_explicit_repair(
    tmp_path: Path,
    effect: str,
    when: str,
    occurrence: int,
    live: str | None,
    stage: bool,
    backup: bool,
    phase: str | None,
) -> None:
    """Kill the real CLI at an external barrier, not an in-process exception.

    The editor identity is a separate real Python process. This tests actor
    crash recovery, not Godot composition or the unchanged-candidate matrix.
    """
    editor = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"])
    actor = None
    token_hex = "47" * 32
    environment = {**os.environ, "PYTHONPATH": str(Path(__file__).parents[2] / "src")}
    for name in tx.QUALIFICATION_FAILPOINT_ENV:
        environment.pop(name, None)
    try:
        _wait_until(lambda: tx.process_start_fingerprint(editor.pid) is not None, timeout=10)
        identity = tx.ProcessIdentity(
            editor.pid, tx.process_start_fingerprint(editor.pid), "crash-matrix-editor"
        )
        scenario = _scenario(tmp_path, editor=identity)
        paths = _paths(scenario)
        actor = subprocess.Popen(
            [sys.executable, "-m", "godot_ai.update_transaction", *_activate_arguments(scenario)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env={
                **environment,
                **_qualification_environment(token_hex, effect=effect, when=when, timeout="60"),
                tx.QUALIFICATION_FAILPOINT_OCCURRENCE_ENV: str(occurrence),
            },
        )
        barrier_path = scenario.recovery / "failpoint-barrier.json"
        after_readiness = effect in {"result_commit", "terminal_temporary_write"} or (
            effect in {"journal_commit", "journal_temporary_write"} and occurrence == 3
        )
        if after_readiness:
            def ready_to_acknowledge() -> bool:
                if not paths.journal.exists():
                    return False
                try:
                    return tx.load_record(paths.journal)["phase"] == "stage_live"
                except PermissionError:
                    # Windows atomic publication may briefly deny the phase poll.
                    return False
                except tx.TransactionError as error:
                    if str(error).endswith((
                        "record changed before reading", "record has an unexpected hard link"
                    )):
                        return False
                    raise

            _wait_until(ready_to_acknowledge, timeout=30)
            tx.write_readiness(tx.load_intent(paths))
        _wait_until(lambda: barrier_path.exists() or actor.poll() is not None, timeout=30)
        assert actor.poll() is None, "actor exited before its external barrier"
        barrier = tx.load_record(barrier_path)
        assert (barrier["effect"], barrier["when"], barrier["sequence"]) == (
            effect,
            when,
            occurrence,
        )
        actual_intent = tx.load_intent(paths)
        assert barrier["intent_sha256"] == tx._intent_sha(actual_intent)
        assert barrier["transaction"] == scenario.intent.transaction
        assert barrier["project_root"] == str(scenario.project.resolve())
        assert barrier["install_root"] == str(scenario.install.resolve())
        assert barrier["recovery_root"] == str(scenario.recovery)
        assert actual_intent.runner.pid == actor.pid
        assert actual_intent.editor == identity

        # The record is the synchronization boundary. Never infer it from logs
        # or sleep an estimated time before killing the actor we launched.
        actor.kill()
        stdout, stderr = actor.communicate(timeout=10)
        assert actor.returncode != 0
        assert token_hex.encode() not in stdout + stderr
        assert tx.probe_process(actual_intent.runner) in {"dead", "reused"}
        assert tx.probe_process(identity) == "alive"
        assert scenario.install.exists() == (live is not None)
        if live is not None:
            expected = actual_intent.old_tree if live == "old" else actual_intent.new_tree
            assert tx.hash_tree(scenario.install) == expected
        assert scenario.stage.exists() == stage
        if stage:
            assert tx.hash_tree(scenario.stage) == actual_intent.new_tree
        assert actual_intent.backup_root.exists() == backup
        if backup:
            assert tx.hash_tree(actual_intent.backup_root) == actual_intent.old_tree
        assert not actual_intent.quarantine_root.exists()
        assert paths.journal.exists() == (phase is not None)
        if phase is not None:
            assert tx.load_journal(paths, actual_intent)["phase"] == phase
        temporaries = list(paths.directory.glob(".record-*.tmp"))
        if effect in {"journal_temporary_write", "terminal_temporary_write"} and when == "after":
            assert len(temporaries) == 1
            temporary = temporaries[0]
            if effect == "journal_temporary_write":
                pending_phase = {1: "prepared", 2: "stage_live", 3: "success"}[occurrence]
                expected_temporary = tx._journal_record(
                    actual_intent, pending_phase, occurrence - 1
                )
            else:
                expected_temporary = tx._terminal_record(
                    actual_intent, outcome="success", writer="normal"
                )
            assert tx.load_record(temporary) == expected_temporary
            temporary_bytes = temporary.read_bytes()
        else:
            assert temporaries == []
        assert paths.readiness.exists() == after_readiness
        result_published = effect == "result_commit" and when == "after"
        assert paths.result.exists() == result_published
        assert not paths.claim.exists() and not paths.migration_complete.exists()
        if after_readiness:
            tx.validate_readiness(paths, actual_intent)
            readiness_bytes = paths.readiness.read_bytes()
        if result_published:
            assert tx.validate_terminal(paths.result, actual_intent)["outcome"] == "success"
        lock = tx.ActivationLock(scenario.recovery)
        assert lock.validate(actual_intent)["runner"] == actual_intent.runner.record()

        def recovery_snapshot():
            return {
                path.relative_to(scenario.recovery).as_posix(): (
                    hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else "directory"
                )
                for path in scenario.recovery.rglob("*")
            }

        frozen = recovery_snapshot()
        startup = subprocess.run(
            [
                sys.executable,
                "-m",
                "godot_ai.update_transaction",
                "startup",
                "--project",
                str(scenario.project),
                "--install",
                str(scenario.install),
                "--editor-pid",
                str(os.getpid()),
                "--editor-nonce",
                "other-editor",
            ],
            env=environment,
            capture_output=True,
            timeout=30,
            check=False,
        )
        assert startup.returncode == 2
        assert startup.stdout == b""
        assert recovery_snapshot() == frozen
        repair_command = [
            sys.executable,
            "-m",
            "godot_ai.update_transaction",
            "repair",
            "--project",
            str(scenario.project),
            "--install",
            str(scenario.install),
            "--recovery-root",
            str(scenario.recovery),
            "--transaction",
            actual_intent.transaction,
        ]
        refused = subprocess.run(
            repair_command, env=environment, capture_output=True, timeout=30, check=False
        )
        assert refused.returncode == 2
        assert b"repair requires runner and initiating editor identities gone" in refused.stderr
        assert recovery_snapshot() == frozen

        editor.terminate()
        editor.wait(timeout=10)
        assert tx.probe_process(identity) in {"dead", "reused"}
        # Death by itself grants no takeover and changes no durable records.
        assert recovery_snapshot() == frozen
        repaired = subprocess.run(
            repair_command, env=environment, capture_output=True, timeout=30, check=False
        )
        assert repaired.returncode == 0, repaired.stderr.decode()
        claim = tx.validate_terminal(paths.claim, actual_intent)
        assert tx.json.loads(repaired.stdout) == tx.actor_response(claim)
        preserve_success = phase == "success"
        expected_outcome = "success" if preserve_success else "rolled_back"
        assert claim["outcome"] == expected_outcome
        assert claim["writer"] == ("normal" if result_published else "repair")
        assert tx.hash_tree(scenario.install) == (
            actual_intent.new_tree if preserve_success else actual_intent.old_tree
        )
        assert actual_intent.backup_root.exists() == preserve_success
        if preserve_success:
            assert tx.hash_tree(actual_intent.backup_root) == actual_intent.old_tree
        assert not lock.path.exists()
        assert not paths.result.exists()
        assert paths.readiness.exists() == after_readiness
        if after_readiness:
            # Readiness is retained evidence, not authority to override the
            # committed journal or to claim the quarantined tree is still live.
            assert paths.readiness.read_bytes() == readiness_bytes
        assert not paths.migration_complete.exists()
        assert tx.load_journal(paths, actual_intent)["phase"] == expected_outcome
        assert scenario.stage.exists() == stage
        if stage:
            assert tx.hash_tree(scenario.stage) == actual_intent.new_tree
        quarantined = live == "new" and not preserve_success
        assert actual_intent.quarantine_root.exists() == quarantined
        if quarantined:
            assert tx.hash_tree(actual_intent.quarantine_root) == actual_intent.new_tree
        # Crash evidence survives; no secret is written into any record.
        assert tx.load_record(barrier_path) == barrier
        # A killed writer's uncommitted bytes are evidence, never authority:
        # repair follows the committed journal and retains the orphan temp.
        if temporaries:
            assert temporary.read_bytes() == temporary_bytes
            assert list(paths.directory.glob(".record-*.tmp")) == temporaries
        for path in scenario.recovery.rglob("*"):
            if path.is_file():
                assert token_hex.encode() not in path.read_bytes()
    finally:
        for process in (actor, editor):
            if process is not None and process.poll() is None:
                process.kill()
                process.wait(timeout=10)


@pytest.fixture
def repair_process_fixture(tmp_path: Path):
    """Prepared crash fixture with two real, independently probed owner PIDs.

    Initial activation is an in-process crash fixture, not a Godot/candidate
    qualification run. The repair command and its crash boundary are real.
    """
    owners = [subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"])
              for _ in range(2)]
    try:
        for process in owners:
            _wait_until(lambda: tx.process_start_fingerprint(process.pid) is not None, timeout=10)
        editor, runner = [tx.ProcessIdentity(
            process.pid, tx.process_start_fingerprint(process.pid), f"repair-owner-{index:016d}"
        ) for index, process in enumerate(owners)]
        scenario = _scenario(tmp_path, editor=editor)
        scenario.intent = replace(scenario.intent, runner=runner)
        with pytest.raises(SimulatedCrash, match="stage_to_live:after"):
            tx.run_activation(scenario.intent, failpoints=CrashAfter("stage_to_live", "after"))
        assert tx.hash_tree(scenario.install) == scenario.intent.new_tree
        assert tx.hash_tree(scenario.intent.backup_root) == scenario.intent.old_tree
        assert tx.load_journal(_paths(scenario), scenario.intent)["phase"] == "prepared"
        yield scenario, owners
    finally:
        for process in owners:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)


def _repair_arguments(scenario: Scenario) -> list[str]:
    return ["repair", "--project", str(scenario.project), "--install", str(scenario.install),
            "--recovery-root", str(scenario.recovery), "--transaction", scenario.intent.transaction]


@pytest.mark.parametrize("when", ["before", "after"])
@pytest.mark.parametrize("action", ["continue", "fail", "kill"])
def test_repair_cli_external_claim_barrier_preserves_crash_and_retry(repair_process_fixture,
                                                                   when, action):
    scenario, owners = repair_process_fixture
    paths = _paths(scenario)
    for process in owners:
        process.terminate()
        process.wait(timeout=10)
    assert tx.probe_process(scenario.intent.editor) in {"dead", "reused"}
    assert tx.probe_process(scenario.intent.runner) in {"dead", "reused"}
    token_hex = "63" * 32
    clean_environment = {key: value for key, value in os.environ.items()
                         if key not in tx.QUALIFICATION_FAILPOINT_ENV}
    clean_environment["PYTHONPATH"] = str(Path(__file__).parents[2] / "src")
    command = [sys.executable, "-m", "godot_ai.update_transaction", *_repair_arguments(scenario)]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={
        **clean_environment,
        **_qualification_environment(token_hex, effect="repair_claim", when=when, timeout="30"),
    })
    barrier_path = scenario.recovery / "failpoint-barrier.json"
    capability = scenario.recovery / "qualification-capability.json"
    repair_claim = paths.directory / "repair-claim.json"
    intent_bytes = paths.intent.read_bytes()
    try:
        _wait_until(lambda: barrier_path.exists() or process.poll() is not None, timeout=30)
        assert barrier_path.exists(), process.communicate(timeout=5)
        barrier = tx.load_record(barrier_path)
        assert (barrier["effect"], barrier["when"], barrier["sequence"]) == (
            "repair_claim", when, 1)
        assert barrier["intent_sha256"] == tx._intent_sha(scenario.intent)
        assert barrier["project_root"] == str(scenario.project)
        assert barrier["install_root"] == str(scenario.install)
        assert barrier["recovery_root"] == str(scenario.recovery)
        assert repair_claim.exists() == (when == "after")
        if repair_claim.exists():
            claim_row = tx.load_record(repair_claim)
            assert claim_row["prior_runner"] == scenario.intent.runner.record()
            assert claim_row["repairer"]["pid"] == process.pid
        assert tx.hash_tree(scenario.install) == scenario.intent.new_tree
        assert tx.hash_tree(scenario.intent.backup_root) == scenario.intent.old_tree
        assert not scenario.stage.exists() and not scenario.intent.quarantine_root.exists()
        assert tx.load_journal(paths, scenario.intent)["phase"] == "prepared"
        assert not paths.result.exists() and not paths.claim.exists()
        assert not paths.readiness.exists() and not paths.migration_complete.exists()
        assert tx.ActivationLock(scenario.recovery).validate(scenario.intent)
        if action == "kill":
            process.kill()
        else:
            with pytest.raises(tx.TransactionError, match="token does not match"):
                tx.write_failpoint_decision(scenario.recovery, token=b"x" * 32, action=action)
            assert not (scenario.recovery / "failpoint-decision.json").exists()
            tx.write_failpoint_decision(scenario.recovery,
                                       token=bytes.fromhex(token_hex), action=action)
        stdout, stderr = process.communicate(timeout=30)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)
    assert process.returncode == 0 if action == "continue" else process.returncode != 0
    if action == "fail":
        assert process.returncode == 2 and b"qualification failpoint: repair_claim:" in stderr
    assert capability.exists() == barrier_path.exists() == (action == "kill")
    retained = {path: path.read_bytes() for path in (capability, barrier_path) if path.exists()}
    if action != "continue":
        assert tx.hash_tree(scenario.install) == scenario.intent.new_tree
        assert tx.hash_tree(scenario.intent.backup_root) == scenario.intent.old_tree
        assert tx.load_journal(paths, scenario.intent)["phase"] == "prepared"
        assert not paths.result.exists() and not paths.claim.exists()
        assert tx.ActivationLock(scenario.recovery).validate(scenario.intent)
        def recovery_snapshot():
            return {path.relative_to(scenario.recovery).as_posix(): (
                path.read_bytes() if path.is_file() else None
            ) for path in scenario.recovery.rglob("*")}

        frozen = recovery_snapshot()
        startup = subprocess.run([
            sys.executable, "-m", "godot_ai.update_transaction", "startup",
            "--project", str(scenario.project), "--install", str(scenario.install),
            "--editor-pid", str(os.getpid()), "--editor-nonce", "repair-other-editor",
        ], capture_output=True, env=clean_environment, timeout=30)
        assert startup.returncode == 2 and startup.stdout == b""
        assert recovery_snapshot() == frozen
        retry = subprocess.run(command, capture_output=True, env=clean_environment, timeout=30)
        assert retry.returncode == 0, retry.stderr
        stdout += retry.stdout
        stderr += retry.stderr
        assert len(list(paths.directory.glob("repair-claim-*.json"))) == (when == "after")
    terminal = tx.validate_terminal(paths.claim, scenario.intent)
    assert terminal["outcome"] == "rolled_back" and terminal["writer"] == "repair"
    assert tx.hash_tree(scenario.install) == scenario.intent.old_tree
    assert tx.hash_tree(scenario.intent.quarantine_root) == scenario.intent.new_tree
    assert not scenario.intent.backup_root.exists() and not scenario.stage.exists()
    assert tx.load_journal(paths, scenario.intent)["phase"] == "rolled_back"
    assert not tx.ActivationLock(scenario.recovery).path.exists()
    assert not paths.result.exists() and not paths.migration_complete.exists()
    assert paths.intent.read_bytes() == intent_bytes
    for path, data in retained.items():
        assert path.read_bytes() == data
    assert token_hex.encode() not in stdout + stderr
    for path in scenario.recovery.rglob("*"):
        if path.is_file():
            assert token_hex.encode() not in path.read_bytes(), path


@pytest.mark.parametrize("mode", [
    "owners-alive", "prior-alive", "wrong-root", "bad-token", "unreachable",
    "timeout", "unreached-occurrence", "library",
])
def test_repair_cli_claim_control_refusal_cleanup_and_library_inertness(
    repair_process_fixture, monkeypatch, capfd, mode,
):
    scenario, owners = repair_process_fixture
    if mode != "owners-alive":
        for process in owners:
            process.terminate()
            process.wait(timeout=10)
    if mode == "prior-alive":
        tx._claim_repair(_paths(scenario), scenario.intent, scenario.intent.runner,
                         tx.ProcessIdentity.current(), tx.probe_process, None)
    environment = _qualification_environment(effect="repair_claim", when="before", timeout="0.01")
    if mode == "bad-token":
        environment[tx.QUALIFICATION_FAILPOINT_TOKEN_ENV] = "not-a-token"
    if mode == "unreachable":
        environment[tx.QUALIFICATION_FAILPOINT_EFFECT_ENV] = "migration_complete"
    if mode == "unreached-occurrence":
        environment[tx.QUALIFICATION_FAILPOINT_OCCURRENCE_ENV] = "2"
    for name in tx.QUALIFICATION_FAILPOINT_ENV:
        monkeypatch.delenv(name, raising=False)
    for name, value in environment.items():
        monkeypatch.setenv(name, value)
    if mode == "library":
        assert tx.repair_transaction(scenario.recovery, scenario.intent.transaction)[
            "outcome"] == "rolled_back"
        assert os.environ[tx.QUALIFICATION_FAILPOINT_EFFECT_ENV] == "repair_claim"
    else:
        arguments = _repair_arguments(scenario)
        if mode == "wrong-root":
            arguments[arguments.index("--recovery-root") + 1] = str(scenario.recovery.parent)
        assert tx.main(arguments) == (0 if mode in {"unreachable", "unreached-occurrence"} else 2)
        assert all(name not in os.environ for name in tx.QUALIFICATION_FAILPOINT_ENV)
    for name in ("qualification-capability.json", "failpoint-barrier.json",
                 "failpoint-decision.json"):
        assert not (scenario.recovery / name).exists()
    if mode in {"owners-alive", "prior-alive", "wrong-root", "bad-token", "timeout"}:
        assert (_paths(scenario).directory / "repair-claim.json").exists() == (
            mode == "prior-alive")
        assert tx.hash_tree(scenario.install) == scenario.intent.new_tree
        assert tx.hash_tree(scenario.intent.backup_root) == scenario.intent.old_tree
        assert tx.load_journal(_paths(scenario), scenario.intent)["phase"] == "prepared"
        assert tx.ActivationLock(scenario.recovery).validate(scenario.intent)
    output = capfd.readouterr()
    assert environment[tx.QUALIFICATION_FAILPOINT_TOKEN_ENV] not in output.out + output.err


def test_repair_rejects_two_failpoint_controllers(tmp_path):
    with pytest.raises(tx.TransactionError, match="only one failpoint controller"):
        tx.repair_transaction(tmp_path, "0123456789abcdef", failpoints=object(),
                              qualification_factory=lambda intent: None)


def test_write_readiness_rejects_changed_live_tree(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    reached = threading.Event()
    release = threading.Event()

    class PauseAfterStageLiveJournal:
        journal_commits = 0

        def barrier(self, effect: str, when: str) -> None:
            if (effect, when) != ("journal_commit", "after"):
                return
            self.journal_commits += 1
            if self.journal_commits == 2:
                reached.set()
                if not release.wait(2):
                    raise AssertionError("test did not release stage-live journal barrier")

    actor = Actor(
        scenario.intent,
        readiness_timeout=0.1,
        claim_timeout=0.05,
        failpoints=PauseAfterStageLiveJournal(),
    )
    assert reached.wait(2)
    try:
        assert _phase(scenario) == "stage_live"
        (scenario.install / "plugin.cfg").write_text("tampered\n")
        with pytest.raises(tx.TransactionError, match="live-tree hash"):
            tx.write_readiness(scenario.intent)
    finally:
        release.set()
    paths = _paths(scenario)
    _wait_until(lambda: os.path.lexists(paths.result))
    assert tx.validate_terminal(paths.result, scenario.intent)["outcome"] == "repair_required"
    assert os.path.lexists(scenario.recovery / "activation.lock")
    actor.thread.join(2)
    assert isinstance(actor.error, tx.TransactionError)
    terminal = tx.repair_transaction(
        scenario.recovery,
        scenario.intent.transaction,
        repairer=tx.ProcessIdentity.current("changed-live-repairer-012345"),
        process_probe=lambda _identity: "dead",
    )
    assert terminal["outcome"] == "rolled_back"
    assert tx.hash_tree(scenario.install) == scenario.intent.old_tree


@pytest.mark.parametrize(
    "raw, message",
    [
        (b'{"a":1,"a":2}\n', "duplicate JSON key"),
        (b'{"a":NaN}\n', "non-finite JSON"),
        (b'{"b":1,"a":2}\n', "not canonical"),
    ],
)
def test_records_reject_duplicates_nonfinite_and_noncanonical(
    tmp_path: Path, raw: bytes, message: str
) -> None:
    directory = _mkdir(tmp_path / "private")
    path = directory / "record.json"
    path.write_bytes(raw)
    path.chmod(0o600)
    with pytest.raises(tx.TransactionError, match=message):
        tx.load_record(path)


def test_unknown_and_impossible_record_fields_fail_closed(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    paths = tx.TransactionPaths.for_transaction(
        scenario.recovery, scenario.intent.transaction, create=True
    )
    intent_row = scenario.intent.record()
    intent_row["surprise"] = True
    tx.publish_record(paths.intent, intent_row)
    with pytest.raises(tx.TransactionError, match="unknown=.*surprise"):
        tx.load_intent(paths)

    paths.intent.unlink()
    tx.publish_record(paths.intent, scenario.intent.record())
    journal = tx._journal_record(scenario.intent, "prepared", 0)
    journal["phase"] = "impossible"
    tx.replace_record(paths.journal, journal)
    with pytest.raises(tx.TransactionError, match="impossible phase"):
        tx.load_journal(paths, scenario.intent)

    journal = tx._journal_record(scenario.intent, "success", 0)
    tx.replace_record(paths.journal, journal)
    with pytest.raises(tx.TransactionError, match="phase/sequence"):
        tx.load_journal(paths, scenario.intent)


@pytest.mark.skipif(os.name == "nt", reason="POSIX permission contract")
def test_records_and_recovery_directories_must_be_owner_private(tmp_path: Path) -> None:
    directory = _mkdir(tmp_path / "private")
    path = directory / "record.json"
    path.write_text("{}\n")
    path.chmod(0o644)
    with pytest.raises(tx.TransactionError, match="group or other"):
        tx.load_record(path)

    scenario = _scenario(tmp_path, "fedcba9876543210")
    scenario.recovery.chmod(0o755)
    with pytest.raises(tx.TransactionError, match="group or other"):
        tx.recovery_root(scenario.project, scenario.install)


def test_root_is_external_deterministic_and_windows_override_is_forbidden(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = _scenario(tmp_path)
    assert scenario.project not in scenario.recovery.parents
    assert tx.recovery_root(scenario.project, scenario.install) == scenario.recovery
    monkeypatch.setattr(tx, "_windows", lambda: True)
    with pytest.raises(tx.TransactionError, match="Windows.*overrides"):
        tx.recovery_root(
            scenario.project,
            scenario.install,
            override=tmp_path / "elsewhere",
        )


@pytest.mark.skipif(sys.platform != "darwin", reason="Darwin case-alias contract")
def test_case_insensitive_aliases_converge_on_one_recovery_identity(tmp_path: Path) -> None:
    project = _mkdir(tmp_path / "MixedCaseProject")
    install = _mkdir(_mkdir(project / "AddOns") / "Godot_AI")
    _tree(install, "old")
    project_alias = tmp_path / "mixedcaseproject"
    install_alias = project_alias / "addons" / "godot_ai"
    if not project_alias.exists() or not install_alias.exists():
        pytest.skip("test filesystem is case-sensitive")

    canonical = tx.recovery_root(project, install, create=True)
    assert tx.recovery_root(project_alias, install_alias) == canonical
    assert tx._canonical_path(project_alias, must_exist=True) == project
    assert tx._canonical_path(install_alias, must_exist=True) == install


@pytest.mark.skipif(os.name == "nt", reason="POSIX recovery namespace contract")
def test_posix_ancestor_policy_allows_only_root_owned_sticky_writable_dirs() -> None:
    directory = stat.S_IFDIR
    current = os.getuid()
    other = current + 1

    assert tx._safe_posix_ancestor(0, directory | 0o1777)
    assert tx._safe_posix_ancestor(current, directory | 0o700)
    assert not tx._safe_posix_ancestor(0, directory | 0o777)
    if current != 0:
        assert not tx._safe_posix_ancestor(current, directory | 0o1777)
    assert not tx._safe_posix_ancestor(other, directory | 0o700)


@pytest.mark.skipif(os.name == "nt", reason="POSIX recovery namespace contract")
def test_recovery_refuses_mutable_ancestor_before_creation(tmp_path: Path) -> None:
    project = _mkdir(tmp_path / "project")
    install = _mkdir(_mkdir(project / "addons") / "godot_ai")
    unsafe = _mkdir(tmp_path / "unsafe")
    unsafe.chmod(0o777)
    target = unsafe / "not-created"
    try:
        with pytest.raises(tx.TransactionError, match="unsafe ancestor"):
            tx.recovery_root(project, install, override=target, create=True)
        assert not target.exists()
    finally:
        unsafe.chmod(0o700)


@pytest.mark.skipif(os.name == "nt", reason="POSIX recovery namespace contract")
def test_private_dir_revalidates_ancestor_after_creation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    parent = _mkdir(tmp_path / "parent")
    child = parent / "child"
    original = tx._private_ancestors
    calls = 0

    def mutate_after_first_check(path: Path) -> None:
        nonlocal calls
        calls += 1
        original(path)
        if calls == 1:
            parent.chmod(0o777)

    monkeypatch.setattr(tx, "_private_ancestors", mutate_after_first_check)
    try:
        with pytest.raises(tx.TransactionError, match="unsafe ancestor"):
            tx._private_dir(child, create=True)
    finally:
        parent.chmod(0o700)


def test_repair_can_find_fixed_root_while_live_install_is_between_swaps(
    tmp_path: Path,
) -> None:
    scenario = _scenario(tmp_path)
    os.rename(scenario.install, scenario.intent.backup_root)
    with pytest.raises(tx.TransactionError, match="does not exist"):
        tx.recovery_root(scenario.project, scenario.install)
    assert (
        tx.recovery_root(
            scenario.project,
            scenario.install,
            _allow_missing_install=True,
        )
        == scenario.recovery
    )


def test_path_and_tree_links_are_rejected(tmp_path: Path) -> None:
    scenario = _scenario(tmp_path)
    linked = scenario.project / "linked-install"
    try:
        linked.symlink_to(scenario.install, target_is_directory=True)
    except OSError as exc:
        pytest.skip(f"symlinks unavailable: {exc}")
    with pytest.raises(tx.TransactionError, match="links and reparse"):
        tx.recovery_root(scenario.project, linked)

    (scenario.install / "linked-file").symlink_to("plugin.cfg")
    with pytest.raises(tx.TransactionError, match="links and reparse"):
        tx.hash_tree(scenario.install)


@pytest.mark.skipif(os.name == "nt", reason="POSIX exact-tree link contract")
def test_exact_tree_rejects_empty_directories_and_hardlinks(tmp_path: Path) -> None:
    root = _mkdir(tmp_path / "tree")
    source = root / "source"
    source.write_text("bytes")
    os.link(source, root / "alias")
    with pytest.raises(tx.TransactionError, match="hard-linked"):
        tx.hash_tree(root)
    (root / "alias").unlink()
    _mkdir(root / "empty")
    with pytest.raises(tx.TransactionError, match="empty directories"):
        tx.hash_tree(root)


@pytest.mark.parametrize("kind", ["intent", "journal", "terminal"])
@pytest.mark.parametrize("when", ["before", "after"])
@pytest.mark.parametrize("action", ["continue", "fail"])
def test_record_temporary_write_has_authenticated_external_barriers(
    tmp_path: Path, kind: str, when: str, action: str
) -> None:
    scenario = _scenario(tmp_path)
    paths = _paths(scenario)
    row = {
        "intent": scenario.intent.record(),
        "journal": tx._journal_record(scenario.intent, "stage_live", 1),
        "terminal": tx._terminal_record(scenario.intent, outcome="success", writer="normal"),
    }[kind]
    path = {"intent": paths.intent, "journal": paths.journal, "terminal": paths.result}[kind]
    previous = tx._journal_record(scenario.intent, "prepared", 0) if kind == "journal" else None
    if previous is not None:
        tx.publish_record(path, previous)
    token = bytes.fromhex("53" * 32)
    effect = f"{kind}_temporary_write"
    capability = tx.write_failpoint_capability(
        scenario.intent, effect=effect, when=when, token=token
    )
    controls = tx.Failpoints(capability, token, scenario.intent, timeout=10)
    errors: list[BaseException] = []

    def write() -> None:
        try:
            store = tx.replace_record if kind == "journal" else tx.publish_record
            store(path, row, failpoints=controls)
        except BaseException as error:
            errors.append(error)

    worker = threading.Thread(target=write, daemon=True)
    worker.start()
    barrier_path = scenario.recovery / "failpoint-barrier.json"
    try:
        _wait_until(lambda: barrier_path.exists() or errors, timeout=5)
        assert errors == []
        barrier = tx.load_record(barrier_path)
        assert (barrier["effect"], barrier["when"], barrier["sequence"]) == (effect, when, 1)
        assert barrier["intent_sha256"] == tx._intent_sha(scenario.intent)
        assert path.exists() == (previous is not None)
        if previous is not None:
            assert tx.load_record(path) == previous
        temporaries = list(paths.directory.glob(".record-*.tmp"))
        assert len(temporaries) == (1 if when == "after" else 0)
        if temporaries:
            assert temporaries[0].read_bytes() == tx.canonical_json(row)
            assert tx.load_record(temporaries[0]) == row
            if os.name != "nt":
                assert stat.S_IMODE(temporaries[0].stat().st_mode) == 0o600
        tx.write_failpoint_decision(scenario.recovery, token=token, action=action)
    finally:
        worker.join(12)
    assert not worker.is_alive()
    if action == "fail":
        assert len(errors) == 1 and isinstance(errors[0], tx.InjectedFailure)
        assert path.exists() == (previous is not None)
        if previous is not None:
            assert tx.load_record(path) == previous
    else:
        assert errors == []
        assert tx.load_record(path) == row
    assert not list(paths.directory.glob(".record-*.tmp"))
    assert not capability.exists()
    assert not barrier_path.exists()
    assert not (scenario.recovery / "failpoint-decision.json").exists()
    for retained in scenario.recovery.rglob("*"):
        if retained.is_file():
            assert token.hex().encode() not in retained.read_bytes()


def test_temporary_write_io_failure_preserves_prior_record_and_original_error(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    directory = _mkdir(tmp_path / "private")
    path = directory / "journal.json"
    previous = {"record": "journal", "value": "old"}
    tx.publish_record(path, previous)
    observed = []

    class Observe:
        def barrier(self, effect: str, when: str) -> None:
            observed.append((effect, when))

    def fail_write(_parent, _data):
        raise OSError("temporary write fixture failure")

    monkeypatch.setattr(tx, "_write_temp", fail_write)
    with pytest.raises(OSError, match="temporary write fixture failure"):
        tx.replace_record(
            path, {"record": "journal", "value": "new"},
            failpoints=Observe(),  # type: ignore[arg-type]
        )
    assert tx.load_record(path) == previous
    assert observed == [("journal_temporary_write", "before")]
    assert not list(directory.glob(".record-*.tmp"))


def test_publish_is_immutable_and_journal_replace_is_atomic(tmp_path: Path) -> None:
    directory = _mkdir(tmp_path / "private")
    path = directory / "record.json"
    tx.publish_record(path, {"value": 1})
    with pytest.raises(tx.TransactionError, match="already exists"):
        tx.publish_record(path, {"value": 2})
    assert tx.load_record(path) == {"value": 1}
    tx.replace_record(path, {"value": 3})
    assert tx.load_record(path) == {"value": 3}
    assert not list(directory.glob(".record-*.tmp"))


@pytest.mark.skipif(os.name == "nt", reason="POSIX immutable-publication link window")
def test_record_reader_waits_for_a_descheduled_publish_unlink(tmp_path: Path) -> None:
    directory = _mkdir(tmp_path / "private")
    path = directory / "record.json"
    path.write_bytes(tx.canonical_json({"value": 1}))
    path.chmod(0o600)
    temporary = directory / ".record-delayed.tmp"
    os.link(path, temporary)

    def finish_publication() -> None:
        time.sleep(0.05)
        temporary.unlink()

    publisher = threading.Thread(target=finish_publication)
    publisher.start()
    try:
        assert tx.load_record(path) == {"value": 1}
    finally:
        publisher.join(1)
        temporary.unlink(missing_ok=True)
    assert not publisher.is_alive()


@pytest.mark.skipif(os.name == "nt", reason="POSIX exact-record link contract")
def test_record_reader_rejects_a_persistent_hard_link(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    directory = _mkdir(tmp_path / "private")
    path = directory / "record.json"
    path.write_bytes(tx.canonical_json({"value": 1}))
    path.chmod(0o600)
    os.link(path, directory / "persistent-alias.json")
    monkeypatch.setattr(tx, "HARD_LINK_SETTLE_SECONDS", 0.01)

    with pytest.raises(tx.TransactionError, match="unexpected hard link"):
        tx.load_record(path)


def test_windows_record_read_retries_a_transient_replace_sharing_denial(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    path = tmp_path / "record.json"
    path.write_bytes(tx.canonical_json({"value": 1}))
    path.chmod(0o600)
    real_open = tx.os.open
    attempts = 0

    def flaky_open(target: Any, flags: int, mode: int = 0o777) -> int:
        nonlocal attempts
        if Path(target) == path and attempts == 0:
            attempts += 1
            raise PermissionError("simulated Windows ReplaceFile sharing window")
        return real_open(target, flags, mode)

    monkeypatch.setattr(tx, "_windows", lambda: True)
    monkeypatch.setattr(tx.os, "open", flaky_open)
    assert tx.load_record(path) == {"value": 1}
    assert attempts == 1


def test_windows_record_replace_retries_a_transient_reader_sharing_denial(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    directory = _mkdir(tmp_path / "private")
    path = directory / "record.json"
    tx.publish_record(path, {"value": 1})
    real_replace = tx.os.replace
    attempts = 0

    def flaky_replace(source: Any, target: Any) -> None:
        nonlocal attempts
        if Path(target) == path and attempts == 0:
            attempts += 1
            raise PermissionError("simulated Windows reader sharing window")
        real_replace(source, target)

    monkeypatch.setattr(tx, "_windows", lambda: True)
    monkeypatch.setattr(tx.os, "replace", flaky_replace)
    tx.replace_record(path, {"value": 2})
    assert tx.load_record(path) == {"value": 2}
    assert attempts == 1


def test_process_fingerprint_distinguishes_alive_from_pid_reuse() -> None:
    current = tx.ProcessIdentity.current("current-process-0123456789")
    assert tx.probe_process(current) == "alive"
    reused = tx.ProcessIdentity(current.pid, "definitely-not-the-same-start", current.nonce)
    assert tx.probe_process(reused) == "reused"


@pytest.mark.skipif(os.name != "nt", reason="Windows process-query regression")
def test_windows_probe_never_terminates_the_process_it_inspects(tmp_path: Path) -> None:
    started = tmp_path / "started"
    survived = tmp_path / "survived"
    child = subprocess.Popen(
        [
            sys.executable,
            "-c",
            (
                "import pathlib,sys,time; "
                "pathlib.Path(sys.argv[1]).write_text('started'); "
                "time.sleep(1); pathlib.Path(sys.argv[2]).write_text('survived'); "
                "time.sleep(30)"
            ),
            str(started),
            str(survived),
        ]
    )
    try:
        _wait_until(started.exists)
        fingerprint = tx.process_start_fingerprint(child.pid)
        assert fingerprint is not None
        identity = tx.ProcessIdentity(child.pid, fingerprint, "windows-sentinel-012345")
        assert tx.probe_process(identity) == "alive"
        _wait_until(survived.exists, timeout=3)
        assert child.poll() is None
    finally:
        child.terminate()
        child.wait(timeout=5)


def test_module_has_a_direct_repair_cli() -> None:
    help_result = subprocess.run(
        [sys.executable, "-m", "godot_ai.update_transaction", "--help"],
        check=False,
        capture_output=True,
        text=True,
        env={**os.environ, "PYTHONPATH": str(Path(__file__).parents[2] / "src")},
    )
    assert help_result.returncode == 0
    assert "explicitly repair" in help_result.stdout
    assert "archive-backup" in help_result.stdout
