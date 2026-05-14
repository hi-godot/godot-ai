"""Coverage-targeted tests for the parts of ``godot_ai.telemetry`` that
the other test files mock out:

* ``TelemetryCollector._send`` — the real httpx POST path (and its
  empty-endpoint short-circuit, non-2xx, transport-error branches).
* Convenience helpers ``record_latency`` / ``record_failure``.
* ``install_fastmcp_wraps`` resource form.
* Worker-loop exception swallowing.
* The platform branches in ``_get_data_directory``.
* The PII-leak edge in ``_extract_sub_action`` (signature-less callables).
* ``hash_session_id`` with a trailing ``@`` (empty suffix).
* Endpoint validation rejecting empty-netloc and ValueError-shaped urls.
"""

from __future__ import annotations

import threading
import time
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from godot_ai import telemetry as tel

# --- shared fixtures -----------------------------------------------------
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


def _record(milestone: tel.MilestoneType | None = None) -> tel.TelemetryRecord:
    return tel.TelemetryRecord(
        record_type=tel.RecordType.TOOL_EXECUTION,
        timestamp=1.0,
        customer_uuid="anon-uuid",
        session_id="hashed@a3f2",
        data={"tool_name": "demo"},
        milestone=milestone,
    )


# --- _send ---------------------------------------------------------------


class TestSendOverHttpx:
    """Drive the real ``_send`` path with a mocked ``httpx.Client``."""

    def test_empty_endpoint_short_circuits(self, clean_env, isolated_data_dir) -> None:
        ## With no endpoint set, _send must not even open an httpx.Client.
        ## Telemetry is on-by-default with a baked-in endpoint, so we
        ## clear the resolved value to simulate the "invalid override
        ## fell back to empty" path (e.g. a self-host that set a
        ## malformed GODOT_AI_TELEMETRY_ENDPOINT).
        collector = tel.TelemetryCollector()
        collector.config.endpoint = ""
        with patch("godot_ai.telemetry.httpx.Client") as client_cls:
            collector._send(_record())
        client_cls.assert_not_called()
        collector.shutdown()

    def test_empty_endpoint_logs_only_once(
        self, clean_env, isolated_data_dir, caplog
    ) -> None:
        """The 'endpoint unset; dropping' debug log must fire exactly
        once even under a flood of dequeued records — otherwise a busy
        session at debug level would spam logs."""
        import logging

        collector = tel.TelemetryCollector()
        collector.config.endpoint = ""  # simulate empty-endpoint mode
        caplog.clear()
        with caplog.at_level(logging.DEBUG, logger="godot-ai-telemetry"):
            for _ in range(50):
                collector._send(_record())
        endpoint_msgs = [r for r in caplog.records if "endpoint unset" in r.getMessage()]
        assert len(endpoint_msgs) == 1
        collector.shutdown()

    def test_posts_when_endpoint_set(self, monkeypatch, clean_env, isolated_data_dir) -> None:
        monkeypatch.setenv("GODOT_AI_TELEMETRY_ENDPOINT", "https://example.com/x")
        collector = tel.TelemetryCollector()

        client_inst = MagicMock()
        client_inst.post.return_value = MagicMock(status_code=200)

        with patch("godot_ai.telemetry.httpx.Client", return_value=client_inst):
            collector._send(_record())

        client_inst.post.assert_called_once()
        call_args = client_inst.post.call_args
        assert call_args.args[0] == "https://example.com/x"
        payload = call_args.kwargs["json"]
        assert payload["record"] == "tool_execution"
        assert payload["customer_uuid"] == "anon-uuid"
        assert payload["session_id"] == "hashed@a3f2"
        assert payload["data"]["tool_name"] == "demo"
        ## Enrichments must land in the payload data so the backend can
        ## slice by OS without a schema migration.
        assert "platform_detail" in payload["data"]
        assert "python_version" in payload["data"]
        assert "milestone" not in payload  ## absent when no milestone

        collector.shutdown()

    def test_client_is_reused_across_sends(
        self, monkeypatch, clean_env, isolated_data_dir
    ) -> None:
        """``httpx.Client`` must be constructed at most once per collector
        — reusing the same instance is the whole point of caching it on
        ``self._client`` (keep-alive, warm TLS pool, lower per-record
        overhead). Locks in the behavior change vs. the original
        per-record ``with httpx.Client(...)`` pattern.
        """
        monkeypatch.setenv("GODOT_AI_TELEMETRY_ENDPOINT", "https://example.com/x")
        collector = tel.TelemetryCollector()

        client_inst = MagicMock()
        client_inst.post.return_value = MagicMock(status_code=200)

        with patch("godot_ai.telemetry.httpx.Client", return_value=client_inst) as ctor:
            for _ in range(5):
                collector._send(_record())

        assert ctor.call_count == 1, "httpx.Client must be built once and reused"
        assert client_inst.post.call_count == 5

        collector.shutdown()
        client_inst.close.assert_called_once()  ## shutdown must close the client

    def test_includes_milestone_field_when_set(
        self, monkeypatch, clean_env, isolated_data_dir
    ) -> None:
        monkeypatch.setenv("GODOT_AI_TELEMETRY_ENDPOINT", "https://example.com/x")
        collector = tel.TelemetryCollector()

        client_inst = MagicMock()
        client_inst.post.return_value = MagicMock(status_code=200)

        with patch("godot_ai.telemetry.httpx.Client", return_value=client_inst):
            collector._send(_record(milestone=tel.MilestoneType.FIRST_STARTUP))

        payload = client_inst.post.call_args.kwargs["json"]
        assert payload["milestone"] == "first_startup"

        collector.shutdown()

    def test_non_2xx_does_not_raise(
        self, monkeypatch, clean_env, isolated_data_dir, caplog
    ) -> None:
        monkeypatch.setenv("GODOT_AI_TELEMETRY_ENDPOINT", "https://example.com/x")
        collector = tel.TelemetryCollector()

        client_inst = MagicMock()
        client_inst.post.return_value = MagicMock(status_code=500)

        with patch("godot_ai.telemetry.httpx.Client", return_value=client_inst):
            collector._send(_record())  # must not raise

        collector.shutdown()

    def test_httperror_is_swallowed(self, monkeypatch, clean_env, isolated_data_dir) -> None:
        import httpx as _httpx

        monkeypatch.setenv("GODOT_AI_TELEMETRY_ENDPOINT", "https://example.com/x")
        collector = tel.TelemetryCollector()

        client_inst = MagicMock()
        client_inst.post.side_effect = _httpx.HTTPError("nope")

        with patch("godot_ai.telemetry.httpx.Client", return_value=client_inst):
            collector._send(_record())  # must not raise

        collector.shutdown()


# --- worker loop exception path -----------------------------------------


class TestWorkerLoopRobustness:
    def test_send_exception_is_swallowed_and_worker_keeps_running(
        self, clean_env, isolated_data_dir
    ) -> None:
        collector = tel.TelemetryCollector()
        calls: list[tel.TelemetryRecord] = []

        def fake_send(rec: tel.TelemetryRecord) -> None:
            calls.append(rec)
            if len(calls) == 1:
                raise RuntimeError("first call boom")

        collector._send = fake_send  # type: ignore[method-assign]

        collector.record(tel.RecordType.USAGE, {"n": 1})
        collector.record(tel.RecordType.USAGE, {"n": 2})

        ## Both records must reach the worker even though the first send
        ## raised — exceptions must not kill the worker thread.
        deadline = time.monotonic() + 2.0
        while len(calls) < 2 and time.monotonic() < deadline:
            time.sleep(0.02)

        assert len(calls) == 2
        assert collector._worker.is_alive()
        collector.shutdown()


# --- convenience helpers ------------------------------------------------


class TestConvenienceHelpers:
    def _captured(self, isolated_data_dir):
        collector = tel.get_telemetry()
        sent: list[tel.TelemetryRecord] = []
        collector._send = sent.append  # type: ignore[method-assign]
        return collector, sent

    def _wait(self, sent: list, n: int = 1) -> None:
        deadline = time.monotonic() + 2.0
        while len(sent) < n and time.monotonic() < deadline:
            time.sleep(0.02)

    def test_record_latency_minimal(self, clean_env, isolated_data_dir) -> None:
        _, sent = self._captured(isolated_data_dir)
        tel.record_latency("scene_save", 12.5)
        self._wait(sent)
        assert sent[0].record_type is tel.RecordType.LATENCY
        assert sent[0].data == {"operation": "scene_save", "duration_ms": 12.5}

    def test_record_latency_with_metadata(self, clean_env, isolated_data_dir) -> None:
        _, sent = self._captured(isolated_data_dir)
        tel.record_latency("scene_save", 12.5, {"path": "res://x.tscn"})
        self._wait(sent)
        assert sent[0].data["path"] == "res://x.tscn"
        assert sent[0].data["operation"] == "scene_save"

    def test_record_failure_minimal(self, clean_env, isolated_data_dir) -> None:
        _, sent = self._captured(isolated_data_dir)
        tel.record_failure("scene_save", "disk full")
        self._wait(sent)
        assert sent[0].record_type is tel.RecordType.FAILURE
        assert sent[0].data == {"component": "scene_save", "error": "disk full"}

    def test_record_failure_with_metadata_and_truncation(
        self, clean_env, isolated_data_dir
    ) -> None:
        _, sent = self._captured(isolated_data_dir)
        long = "x" * 1000
        tel.record_failure("scene_save", long, {"path": "res://x.tscn"})
        self._wait(sent)
        assert len(sent[0].data["error"]) == 500
        assert sent[0].data["path"] == "res://x.tscn"

    def test_record_tool_usage_no_sub_action_no_error(self, clean_env, isolated_data_dir) -> None:
        _, sent = self._captured(isolated_data_dir)
        tel.record_tool_usage("ping", True, 1.0)
        self._wait(sent)
        assert "sub_action" not in sent[0].data
        assert "error" not in sent[0].data

    def test_record_resource_usage_with_error(self, clean_env, isolated_data_dir) -> None:
        _, sent = self._captured(isolated_data_dir)
        tel.record_resource_usage("godot://scene/current", False, 5.0, error="not connected")
        self._wait(sent)
        assert sent[0].record_type is tel.RecordType.RESOURCE_RETRIEVAL
        assert sent[0].data["error"] == "not connected"
        assert sent[0].data["success"] is False


# --- module-level singleton paths ---------------------------------------


class TestModuleSingleton:
    def test_get_telemetry_is_idempotent(self, clean_env, isolated_data_dir) -> None:
        a = tel.get_telemetry()
        b = tel.get_telemetry()
        assert a is b

    def test_reset_when_no_collector_is_noop(self, clean_env, isolated_data_dir) -> None:
        tel.reset_telemetry()  # already reset by fixture
        tel.reset_telemetry()  # must not raise

    def test_is_telemetry_enabled_reflects_config(
        self, monkeypatch, clean_env, isolated_data_dir
    ) -> None:
        assert tel.is_telemetry_enabled() is True
        tel.reset_telemetry()
        monkeypatch.setenv("GODOT_AI_DISABLE_TELEMETRY", "true")
        assert tel.is_telemetry_enabled() is False


# --- decorator edges ----------------------------------------------------


class TestDecoratorEdges:
    def test_sub_action_extraction_signature_less_callable(
        self, monkeypatch, clean_env, isolated_data_dir
    ) -> None:
        ## Some callables (e.g. C-built-ins) don't have a Python signature;
        ## the extractor must return None rather than blow up. Force the
        ## error path by patching ``inspect.signature`` to raise.
        import inspect as _inspect

        def boom(_obj):
            raise TypeError("no signature available")

        monkeypatch.setattr(tel, "inspect", _inspect)  # ensure import lookup
        monkeypatch.setattr(_inspect, "signature", boom)

        collector = tel.get_telemetry()
        sent: list[tel.TelemetryRecord] = []
        collector._send = sent.append  # type: ignore[method-assign]

        @tel.telemetry_tool("signless")
        def signless(x: int) -> int:
            return x * 2

        result = signless(21)
        assert result == 42  # function still runs

        deadline = time.monotonic() + 1.0
        while not sent and time.monotonic() < deadline:
            time.sleep(0.02)
        assert sent
        assert "sub_action" not in sent[0].data

    def test_none_op_value_does_not_become_string_none(self, clean_env, isolated_data_dir) -> None:
        collector = tel.get_telemetry()
        sent: list[tel.TelemetryRecord] = []
        collector._send = sent.append  # type: ignore[method-assign]

        @tel.telemetry_tool("manage")
        def manage(op: str | None = None, params: dict | None = None) -> dict:
            return {"ok": True}

        manage(op=None)
        deadline = time.monotonic() + 1.0
        while not sent and time.monotonic() < deadline:
            time.sleep(0.02)
        assert sent
        ## ``None`` for the sub-action key must be filtered, not stringified.
        assert "sub_action" not in sent[0].data


# --- install_fastmcp_wraps: resource form -------------------------------


class TestWrapsResourceForm:
    def test_resource_decorator_is_wrapped(self, clean_env, isolated_data_dir) -> None:
        from fastmcp import FastMCP

        collector = tel.get_telemetry()
        sent: list[tel.TelemetryRecord] = []
        collector._send = sent.append  # type: ignore[method-assign]

        mcp = FastMCP("test")
        tel.install_fastmcp_wraps(mcp)

        @mcp.resource("godot://demo/info")
        async def info() -> str:
            return "ok"

        import asyncio

        asyncio.run(info())
        deadline = time.monotonic() + 1.0
        while not sent and time.monotonic() < deadline:
            time.sleep(0.02)

        assert sent
        rec = sent[0]
        assert rec.record_type is tel.RecordType.RESOURCE_RETRIEVAL
        assert rec.data["resource_name"] == "info"


# --- endpoint validation edges ------------------------------------------


class TestEndpointValidationEdges:
    def test_unparseable_returns_empty(self, monkeypatch, clean_env, isolated_data_dir):
        ## A urlparse-shaped exception is the docstring case for the
        ## try/except in _is_valid_endpoint; force it via a patch since
        ## stdlib urlparse rarely raises ValueError in practice.
        monkeypatch.setenv("GODOT_AI_TELEMETRY_ENDPOINT", "https://example.com/x")
        with patch("godot_ai.telemetry.urlparse", side_effect=ValueError("nope")):
            assert tel.TelemetryConfig().endpoint == ""

    def test_missing_netloc_rejected(self, monkeypatch, clean_env, isolated_data_dir) -> None:
        monkeypatch.setenv("GODOT_AI_TELEMETRY_ENDPOINT", "https://")
        assert tel.TelemetryConfig().endpoint == ""


# --- hash_session_id edge ------------------------------------------------


class TestHashEdges:
    def test_trailing_at_keeps_empty_suffix(self) -> None:
        result = tel.hash_session_id("project@")
        assert result.endswith("@")
        ## The hashed slug is still 8 hex chars even with empty suffix.
        head, _, _ = result.partition("@")
        assert len(head) == 8


# --- _get_data_directory ------------------------------------------------


class TestDataDirectory:
    """Per-OS path-resolution branches are covered by CI's matrix
    (linux/macos/windows). Here we just pin the cross-platform invariants
    and the mkdir-failure swallow.

    Patching ``os.name`` / ``sys.platform`` on the imported module aliases
    the real ``os`` module, so the change is global and leaks past the
    test (an earlier version of this file caused pytest's session-finish
    cache write to fail with NotImplementedError: WindowsPath). The
    per-OS code is exercised by the matrix; don't reintroduce the leak.
    """

    def test_returns_godot_ai_named_dir_on_current_platform(self, tmp_path) -> None:
        result = tel.TelemetryConfig._get_data_directory()
        assert result.name == "godot-ai"

    def test_xdg_override_used_on_linux(self, monkeypatch, tmp_path) -> None:
        import sys as _sys

        if _sys.platform == "darwin" or _sys.platform.startswith("win"):
            pytest.skip("XDG_DATA_HOME only consulted on Linux-style posix")
        monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "xdg"))
        result = tel.TelemetryConfig._get_data_directory()
        assert str(result).startswith(str(tmp_path / "xdg"))
        assert result.name == "godot-ai"

    def test_mkdir_failure_is_swallowed(self, monkeypatch, tmp_path) -> None:
        import sys as _sys

        if _sys.platform == "darwin" or _sys.platform.startswith("win"):
            pytest.skip("Linux path used for mkdir-failure test")
        monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path))

        original_mkdir = Path.mkdir

        def boom(self, *args, **kwargs):
            if self.name == "godot-ai":
                raise OSError("read-only fs")
            return original_mkdir(self, *args, **kwargs)

        monkeypatch.setattr(Path, "mkdir", boom)
        ## Should not raise; data_dir is returned even if mkdir failed.
        result = tel.TelemetryConfig._get_data_directory()
        assert result.name == "godot-ai"


# --- persistent data: uuid + milestones edge paths ----------------------


class TestPersistentDataEdges:
    def test_empty_uuid_file_regenerates(self, clean_env, isolated_data_dir: Path) -> None:
        (isolated_data_dir / "customer_uuid.txt").write_text("", encoding="utf-8")
        collector = tel.TelemetryCollector()
        ## Empty file → fresh uuid generated.
        assert collector._customer_uuid
        assert len(collector._customer_uuid) >= 32
        collector.shutdown()

    def test_uuid_persist_oserror_is_logged_not_raised(
        self, monkeypatch, clean_env, isolated_data_dir: Path
    ) -> None:
        ## Force write_text to fail on the uuid file.
        original_write = Path.write_text

        def boom(self, *args, **kwargs):
            if self.name == "customer_uuid.txt":
                raise OSError("read-only")
            return original_write(self, *args, **kwargs)

        monkeypatch.setattr(Path, "write_text", boom)
        collector = tel.TelemetryCollector()
        ## Construction succeeds even though persistence failed.
        assert collector._customer_uuid is not None
        collector.shutdown()

    def test_uuid_load_oserror_falls_back_to_fresh_uuid(
        self, monkeypatch, clean_env, isolated_data_dir: Path
    ) -> None:
        ## Force the *outer* read path (exists() / read_text) to raise OSError
        ## so we hit the outer-except branch in _load_persistent_data.
        original_exists = Path.exists

        def boom(self, *args, **kwargs):
            if self.name == "customer_uuid.txt":
                raise OSError("io")
            return original_exists(self, *args, **kwargs)

        monkeypatch.setattr(Path, "exists", boom)
        collector = tel.TelemetryCollector()
        ## A fresh uuid is generated even though load failed.
        assert collector._customer_uuid
        assert len(collector._customer_uuid) >= 32
        collector.shutdown()

    def test_milestones_save_oserror_is_swallowed(
        self, monkeypatch, clean_env, isolated_data_dir: Path
    ) -> None:
        collector = tel.TelemetryCollector()
        original_write = Path.write_text

        def boom(self, *args, **kwargs):
            if self.name == "milestones.json":
                raise OSError("read-only")
            return original_write(self, *args, **kwargs)

        monkeypatch.setattr(Path, "write_text", boom)
        ## record_milestone -> _save_milestones; the OSError must be
        ## swallowed and the milestone still recorded in memory.
        result = collector.record_milestone(tel.MilestoneType.FIRST_STARTUP)
        assert result is True
        assert "first_startup" in collector._milestones
        collector.shutdown()

    def test_existing_milestones_dict_is_loaded(self, clean_env, isolated_data_dir: Path) -> None:
        import json

        (isolated_data_dir / "milestones.json").write_text(
            json.dumps({"first_startup": {"timestamp": 1.0, "data": {}}}),
            encoding="utf-8",
        )
        collector = tel.TelemetryCollector()
        assert "first_startup" in collector._milestones
        ## Recording it again must be a no-op (idempotence).
        assert collector.record_milestone(tel.MilestoneType.FIRST_STARTUP) is False
        collector.shutdown()

    def test_milestones_file_with_non_dict_payload_is_reset(
        self, clean_env, isolated_data_dir: Path
    ) -> None:
        ## ``milestones.json`` getting a list / null is unexpected but
        ## possible. The loader must fall back to {} silently.
        (isolated_data_dir / "milestones.json").write_text("[]", encoding="utf-8")
        collector = tel.TelemetryCollector()
        assert collector._milestones == {}
        collector.shutdown()

    def test_record_milestone_returns_false_when_disabled(
        self, monkeypatch, clean_env, isolated_data_dir: Path
    ) -> None:
        monkeypatch.setenv("GODOT_AI_DISABLE_TELEMETRY", "1")
        collector = tel.TelemetryCollector()
        result = collector.record_milestone(tel.MilestoneType.FIRST_STARTUP)
        assert result is False
        collector.shutdown()


# --- shutdown when worker isn't alive -----------------------------------


class TestShutdownEdges:
    def test_shutdown_no_op_when_worker_dead(self, clean_env, isolated_data_dir) -> None:
        collector = tel.TelemetryCollector()
        collector._shutdown = True
        collector._worker.join(timeout=1.0)
        assert not collector._worker.is_alive()
        collector.shutdown()  # must not raise

    def test_shutdown_does_not_close_client_while_worker_in_flight(
        self, monkeypatch, clean_env, isolated_data_dir
    ) -> None:
        """If the worker is still inside ``self._client.post(...)`` when
        ``shutdown`` times out joining, closing the client from this
        thread would tear an httpx connection out from under the
        worker — undefined behavior. The contract is: only close when
        the worker is actually gone. Locks in the race fix flagged
        by the lazy-init second-opinion review.
        """
        import threading

        monkeypatch.setenv("GODOT_AI_TELEMETRY_ENDPOINT", "https://example.com/x")
        ## SHUTDOWN_TIMEOUT defaults to 2.0s; force a tighter window
        ## so we don't slow the test suite waiting for it.
        monkeypatch.setattr(tel.TelemetryCollector, "SHUTDOWN_TIMEOUT", 0.2)
        collector = tel.TelemetryCollector()

        ## Pin _client to a stub so we don't need network. Make
        ## ``post`` block long enough that the join times out.
        worker_in_post = threading.Event()
        release = threading.Event()

        def slow_post(*_a, **_kw):
            worker_in_post.set()
            release.wait(timeout=5.0)
            return MagicMock(status_code=200)

        client_inst = MagicMock()
        client_inst.post.side_effect = slow_post
        collector._client = client_inst

        collector.record(tel.RecordType.USAGE, {"x": 1})
        ## Wait for the worker to actually be inside post() before
        ## calling shutdown, otherwise the worker might exit cleanly
        ## and we'd test the wrong branch.
        assert worker_in_post.wait(timeout=2.0), "worker never entered post()"

        collector.shutdown()  # join times out → must NOT close client

        client_inst.close.assert_not_called()
        assert collector._client is client_inst, "client must still be live"

        ## Let the in-flight post return so the worker can exit cleanly
        ## (otherwise the daemon thread lingers).
        release.set()
        collector._worker.join(timeout=2.0)


# --- silence threading test warnings ------------------------------------


@pytest.fixture(autouse=True)
def _join_lingering_threads():
    yield
    ## Conservative cleanup so a flaky daemon worker can't bleed into the
    ## next test's timing.
    for thr in list(threading.enumerate()):
        if thr is threading.main_thread():
            continue
        if thr.name.startswith("godot-ai-telemetry"):
            thr.join(timeout=0.5)
