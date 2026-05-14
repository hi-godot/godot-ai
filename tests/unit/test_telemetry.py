"""Unit tests for ``godot_ai.telemetry``.

Covers:
* ``TelemetryConfig`` opt-out + endpoint validation
* ``TelemetryCollector`` queue + worker behavior
* ``hash_session_id`` shape and stability
* customer_uuid persistence
* milestone idempotence + on-disk persistence
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from unittest.mock import patch

import pytest

from godot_ai import telemetry as tel

## ``isolated_data_dir`` comes from ``tests/unit/conftest.py``.


@pytest.fixture
def clean_env(monkeypatch) -> None:
    for name in (
        "GODOT_AI_DISABLE_TELEMETRY",
        "DISABLE_TELEMETRY",
        "GODOT_AI_TELEMETRY_ENDPOINT",
        "GODOT_AI_TELEMETRY_TIMEOUT",
        "GODOT_AI_TELEMETRY_ALLOW_LOOPBACK",
    ):
        monkeypatch.delenv(name, raising=False)


# --- hash_session_id -----------------------------------------------------


class TestHashSessionId:
    def test_empty_returns_empty(self) -> None:
        assert tel.hash_session_id("") == ""
        assert tel.hash_session_id(None) == ""

    def test_keeps_4hex_suffix_when_present(self) -> None:
        result = tel.hash_session_id("my-secret-game@a3f2")
        assert result.endswith("@a3f2")

    def test_hashes_slug_to_8_hex_chars(self) -> None:
        result = tel.hash_session_id("my-secret-game@a3f2")
        head, sep, tail = result.partition("@")
        assert sep == "@"
        assert len(head) == 8
        int(head, 16)  # must be valid hex

    def test_stable_for_same_input(self) -> None:
        a = tel.hash_session_id("godot-ai@1234")
        b = tel.hash_session_id("godot-ai@1234")
        assert a == b

    def test_different_slugs_hash_differently(self) -> None:
        a = tel.hash_session_id("project-a@1111")
        b = tel.hash_session_id("project-b@1111")
        assert a != b

    def test_no_at_falls_back_to_full_hash(self) -> None:
        result = tel.hash_session_id("legacy-session")
        assert "@" not in result
        assert len(result) == 8


# --- TelemetryConfig -----------------------------------------------------


class TestTelemetryConfig:
    def test_default_enabled_uses_baked_in_endpoint(
        self, clean_env, isolated_data_dir
    ) -> None:
        """A fresh install with no env overrides should resolve to the
        baked-in production endpoint so the binary actually reports.
        Regression test for "telemetry on by default" — empty default
        endpoint used to mean zero traffic even when enabled."""
        config = tel.TelemetryConfig()
        assert config.enabled is True
        assert config.endpoint == tel.TelemetryConfig.DEFAULT_ENDPOINT
        ## The bake-in must be a real https URL, not the empty string.
        assert config.endpoint.startswith("https://")

    @pytest.mark.parametrize("var", ["GODOT_AI_DISABLE_TELEMETRY", "DISABLE_TELEMETRY"])
    def test_opt_out_via_env(self, monkeypatch, clean_env, isolated_data_dir, var: str) -> None:
        monkeypatch.setenv(var, "true")
        assert tel.TelemetryConfig().enabled is False

    @pytest.mark.parametrize("value", ["1", "true", "TRUE", "YES", "On"])
    def test_truthy_variants(self, monkeypatch, clean_env, isolated_data_dir, value: str) -> None:
        monkeypatch.setenv("GODOT_AI_DISABLE_TELEMETRY", value)
        assert tel.TelemetryConfig().enabled is False

    @pytest.mark.parametrize("value", ["", "0", "false", "no", "anything-else"])
    def test_falsy_variants_keep_enabled(
        self, monkeypatch, clean_env, isolated_data_dir, value: str
    ) -> None:
        monkeypatch.setenv("GODOT_AI_DISABLE_TELEMETRY", value)
        assert tel.TelemetryConfig().enabled is True

    def test_accepts_https_endpoint(self, monkeypatch, clean_env, isolated_data_dir) -> None:
        monkeypatch.setenv("GODOT_AI_TELEMETRY_ENDPOINT", "https://example.com/x")
        assert tel.TelemetryConfig().endpoint == "https://example.com/x"

    def test_rejects_unsupported_scheme(self, monkeypatch, clean_env, isolated_data_dir) -> None:
        monkeypatch.setenv("GODOT_AI_TELEMETRY_ENDPOINT", "ftp://example.com/")
        assert tel.TelemetryConfig().endpoint == ""

    def test_rejects_localhost_by_default(self, monkeypatch, clean_env, isolated_data_dir) -> None:
        monkeypatch.setenv("GODOT_AI_TELEMETRY_ENDPOINT", "http://127.0.0.1:7777")
        assert tel.TelemetryConfig().endpoint == ""

    def test_allows_loopback_when_opted_in(self, monkeypatch, clean_env, isolated_data_dir) -> None:
        monkeypatch.setenv("GODOT_AI_TELEMETRY_ENDPOINT", "http://127.0.0.1:7777")
        monkeypatch.setenv("GODOT_AI_TELEMETRY_ALLOW_LOOPBACK", "1")
        assert tel.TelemetryConfig().endpoint == "http://127.0.0.1:7777"

    def test_default_timeout(self, clean_env, isolated_data_dir) -> None:
        assert tel.TelemetryConfig().timeout == tel.TelemetryConfig.DEFAULT_TIMEOUT

    def test_timeout_from_env(self, monkeypatch, clean_env, isolated_data_dir) -> None:
        monkeypatch.setenv("GODOT_AI_TELEMETRY_TIMEOUT", "5.0")
        assert tel.TelemetryConfig().timeout == 5.0

    def test_invalid_timeout_falls_back(self, monkeypatch, clean_env, isolated_data_dir) -> None:
        monkeypatch.setenv("GODOT_AI_TELEMETRY_TIMEOUT", "nope")
        assert tel.TelemetryConfig().timeout == tel.TelemetryConfig.DEFAULT_TIMEOUT


# --- TelemetryCollector --------------------------------------------------


def _drain_to(collector: tel.TelemetryCollector, bucket: list[tel.TelemetryRecord]) -> None:
    """Replace ``_send`` with a list-appender for assertion-friendly capture."""
    collector._send = bucket.append  # type: ignore[method-assign]


class TestTelemetryCollector:
    def test_disabled_collector_drops_records(self, clean_env, isolated_data_dir) -> None:
        with patch.object(tel.TelemetryConfig, "_is_disabled_via_env", return_value=True):
            collector = tel.TelemetryCollector()
        sent: list[tel.TelemetryRecord] = []
        _drain_to(collector, sent)
        collector.record(tel.RecordType.USAGE, {"x": 1})
        time.sleep(0.1)
        assert sent == []
        collector.shutdown()

    def test_record_enqueues_and_worker_drains(self, clean_env, isolated_data_dir) -> None:
        collector = tel.TelemetryCollector()
        sent: list[tel.TelemetryRecord] = []
        _drain_to(collector, sent)

        collector.record(tel.RecordType.USAGE, {"x": 1})
        for _ in range(40):  # up to ~2s
            if sent:
                break
            time.sleep(0.05)

        assert len(sent) == 1
        assert sent[0].record_type is tel.RecordType.USAGE
        assert sent[0].data == {"x": 1}
        collector.shutdown()

    def test_session_id_is_hashed_on_record(self, clean_env, isolated_data_dir) -> None:
        collector = tel.TelemetryCollector()
        sent: list[tel.TelemetryRecord] = []
        _drain_to(collector, sent)

        collector.record(
            tel.RecordType.TOOL_EXECUTION,
            {"tool_name": "node_create"},
            session_id="secret-game@a3f2",
        )
        for _ in range(40):
            if sent:
                break
            time.sleep(0.05)

        assert sent
        assert sent[0].session_id.endswith("@a3f2")
        assert "secret-game" not in sent[0].session_id
        collector.shutdown()

    def test_milestone_idempotent(self, clean_env, isolated_data_dir) -> None:
        collector = tel.TelemetryCollector()
        sent: list[tel.TelemetryRecord] = []
        _drain_to(collector, sent)

        assert collector.record_milestone(tel.MilestoneType.FIRST_STARTUP) is True
        assert collector.record_milestone(tel.MilestoneType.FIRST_STARTUP) is False
        ## On-disk milestones file must reflect exactly one entry.
        on_disk = json.loads(collector.config.milestones_file.read_text(encoding="utf-8"))
        assert "first_startup" in on_disk
        collector.shutdown()

    def test_customer_uuid_round_trip(self, clean_env, isolated_data_dir) -> None:
        c1 = tel.TelemetryCollector()
        uuid_one = c1._customer_uuid
        c1.shutdown()

        c2 = tel.TelemetryCollector()
        assert c2._customer_uuid == uuid_one
        c2.shutdown()

    def test_corrupt_milestones_file_does_not_blow_up(
        self, clean_env, isolated_data_dir: Path
    ) -> None:
        (isolated_data_dir / "milestones.json").write_text("not json {", encoding="utf-8")
        collector = tel.TelemetryCollector()
        assert collector._milestones == {}
        collector.shutdown()

    def test_drop_on_queue_full(self, clean_env, isolated_data_dir) -> None:
        collector = tel.TelemetryCollector()
        ## Stop the worker thread so the queue can fill.
        collector._shutdown = True
        collector._worker.join(timeout=1.0)

        for _ in range(collector.QUEUE_MAXSIZE + 50):
            collector.record(tel.RecordType.USAGE, {"x": 1})
        ## ``put_nowait`` should silently drop once the bound is hit; the
        ## queue should be sitting at exactly ``QUEUE_MAXSIZE``.
        assert collector._queue.qsize() == collector.QUEUE_MAXSIZE

    def test_disabled_does_not_touch_disk(
        self, monkeypatch, clean_env, isolated_data_dir: Path
    ) -> None:
        """Opt-out must be fully side-effect-free: no UUID file, no
        milestones file, no worker thread. Locks in the contract
        documented in docs/TELEMETRY.md.
        """
        monkeypatch.setenv("GODOT_AI_DISABLE_TELEMETRY", "1")
        collector = tel.TelemetryCollector()

        ## No disk artifacts created.
        assert not (isolated_data_dir / "customer_uuid.txt").exists()
        assert not (isolated_data_dir / "milestones.json").exists()
        ## No worker thread spun up.
        assert collector._worker is None
        ## No UUID in memory either.
        assert collector._customer_uuid is None
        ## Path-tracking fields are nullable; on-disk paths deferred.
        assert collector.config.data_dir is None
        assert collector.config.uuid_file is None
        assert collector.config.milestones_file is None
        ## Shutdown remains safe with no worker.
        collector.shutdown()


class TestPublicHelpers:
    def test_is_telemetry_enabled_does_not_construct_collector(
        self, monkeypatch, clean_env, isolated_data_dir: Path
    ) -> None:
        """``is_telemetry_enabled()`` is a pure env check by design — the
        opt-out contract is that no collector / disk side effect happens
        just from asking."""
        assert tel._collector is None  # singleton not created yet
        assert tel.is_telemetry_enabled() is True
        assert tel._collector is None  # still not created
        ## And the env-override path returns False without creating one.
        monkeypatch.setenv("GODOT_AI_DISABLE_TELEMETRY", "1")
        assert tel.is_telemetry_enabled() is False
        assert tel._collector is None

    def test_shutdown_if_initialized_noop_when_no_collector(
        self, clean_env, isolated_data_dir: Path
    ) -> None:
        assert tel._collector is None
        tel.shutdown_if_initialized()  # must not create or raise
        assert tel._collector is None

    def test_shutdown_if_initialized_shuts_down_existing(
        self, clean_env, isolated_data_dir: Path
    ) -> None:
        first = tel.get_telemetry()
        worker = first._worker
        tel.shutdown_if_initialized()
        ## The original collector's worker drains and exits.
        assert worker is None or not worker.is_alive()
        ## Module-level reference is cleared so a subsequent
        ## ``get_telemetry()`` builds a fresh, live collector instead
        ## of returning the dead one.
        assert tel._collector is None

    def test_lifespan_restart_in_same_process_gets_fresh_collector(
        self, clean_env, isolated_data_dir: Path
    ) -> None:
        """Regression: after the first lifespan teardown, a subsequent
        ``record_telemetry()`` was reusing the dead collector and the
        worker had exited — every record was enqueued into a queue with
        no drainer. uvicorn ``--reload`` (and repeated test runs in
        one process) reproduce this. Locked in by this test."""
        import time

        first = tel.get_telemetry()
        first_worker = first._worker
        tel.shutdown_if_initialized()

        second = tel.get_telemetry()
        assert second is not first, "Second start must build a fresh collector"
        assert second._worker is not first_worker
        assert second._worker is not None and second._worker.is_alive()

        ## And the new collector actually drains records.
        sent: list[tel.TelemetryRecord] = []
        second._send = sent.append  # type: ignore[method-assign]
        tel.record_telemetry(tel.RecordType.USAGE, {"after_restart": True})
        deadline = time.monotonic() + 1.0
        while not sent and time.monotonic() < deadline:
            time.sleep(0.02)
        assert sent and sent[0].data["after_restart"] is True
