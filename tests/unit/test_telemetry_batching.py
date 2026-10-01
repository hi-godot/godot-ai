"""Batched sends and the successful-tool-call rollup.

Every POST carries ``{"events": [...]}`` (max ``MAX_EVENTS_PER_POST``),
flushed at most once per ``FLUSH_INTERVAL_S`` and once more at shutdown.
Successful tool calls never become individual events: they are counted per
(tool, sub_action, hashed session) with a 13-bucket latency histogram and
shipped as ``tool_rollup`` events. Failures keep their per-event payload.
"""

from __future__ import annotations

import time
from unittest.mock import MagicMock, patch

import pytest

from godot_ai import telemetry as tel

## ``isolated_data_dir`` comes from ``tests/unit/conftest.py``.

ENDPOINT = "https://example.com/events"


@pytest.fixture
def env(monkeypatch, isolated_data_dir):
    monkeypatch.setenv("GODOT_AI_TELEMETRY_ENDPOINT", ENDPOINT)
    monkeypatch.delenv("GODOT_AI_TELEMETRY_FLUSH_INTERVAL", raising=False)
    return monkeypatch


@pytest.fixture
def client():
    inst = MagicMock()
    inst.post.return_value = MagicMock(status_code=200)
    with patch("godot_ai.telemetry.httpx.Client", return_value=inst):
        yield inst


def _bodies(client: MagicMock) -> list[dict]:
    return [call.kwargs["json"] for call in client.post.call_args_list]


def _events(client: MagicMock) -> list[dict]:
    return [event for body in _bodies(client) for event in body["events"]]


def _hist(**bucket_counts: int) -> list[int]:
    hist = [0] * 13
    for index, count in bucket_counts.items():
        hist[int(index.lstrip("b"))] = count
    return hist


# --- aggregation ---------------------------------------------------------


class TestSuccessAggregation:
    @pytest.mark.parametrize(
        ("duration_ms", "bucket"),
        [
            (0.0, 0),
            (10, 0),
            (10.01, 1),
            (25, 1),
            (999.9, 6),
            (1000, 6),
            (60000, 11),
            (60000.1, 12),
            (10_000_000, 12),
        ],
    )
    def test_histogram_bucket_boundaries(self, env, duration_ms, bucket) -> None:
        collector = tel.TelemetryCollector()
        collector.record_tool_success("t", duration_ms)
        hist = collector._rollup[("t", None, "")]
        assert len(hist) == 13
        assert hist.index(1) == bucket and sum(hist) == 1
        collector.shutdown()

    def test_bucket_bounds_are_the_wire_contract(self) -> None:
        assert tel.ROLLUP_BUCKET_BOUNDS_MS == (
            10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 30000, 60000, float("inf"),
        )  # fmt: skip

    def test_successes_are_counted_not_queued(self, env) -> None:
        collector = tel.get_telemetry()
        staged: list[tel.TelemetryRecord] = []
        collector._add_pending = staged.append  # type: ignore[method-assign]

        tel.record_tool_usage("node_create", True, 5.0)
        tel.record_tool_usage("node_create", True, 30.0)
        tel.record_tool_usage("scene_manage", True, 5.0, sub_action="save_as")
        tel.record_tool_usage("scene_manage", True, 5.0, sub_action="x" * 100)
        tel.record_tool_usage("scene_manage", True, 5.0, session_id="secret-game@a3f2")
        collector._queue.join()

        assert staged == []
        hashed = tel.hash_session_id("secret-game@a3f2", salt=collector._customer_uuid)
        assert collector._rollup == {
            ("node_create", None, ""): _hist(b0=1, b2=1),
            ("scene_manage", "save_as", ""): _hist(b0=1),
            ## sub_action truncated to 64, as the per-event path does.
            ("scene_manage", "x" * 64, ""): _hist(b0=1),
            ("scene_manage", None, hashed): _hist(b0=1),
        }

    def test_failures_still_emitted_individually_with_unchanged_payload(self, env, client) -> None:
        collector = tel.get_telemetry()
        tel.record_tool_usage(
            "script_patch",
            False,
            12.345,
            "EDITOR_NOT_READY",
            sub_action="apply",
            session_id="secret-game@a3f2",
            error_sub_code="EDITOR_PLAYING",
        )
        collector._queue.join()
        assert collector._rollup == {}
        collector._flush()

        [event] = _events(client)
        assert event["record"] == "tool_execution"
        assert event["session_id"] == tel.hash_session_id(
            "secret-game@a3f2", salt=collector._customer_uuid
        )
        assert set(event) == {
            "record", "timestamp", "customer_uuid", "session_id", "data",
            "version", "platform", "source",
        }  # fmt: skip
        data = dict(event["data"])
        assert data.pop("platform_detail") and data.pop("python_version")
        assert data == {
            "tool_name": "script_patch",
            "success": False,
            "duration_ms": 12.35,
            "sub_action": "apply",
            "error": "EDITOR_NOT_READY",
            "error_sub_code": "EDITOR_PLAYING",
        }

    def test_successful_resource_reads_stay_individual(self, env) -> None:
        collector = tel.get_telemetry()
        staged: list[tel.TelemetryRecord] = []
        collector._add_pending = staged.append  # type: ignore[method-assign]
        tel.record_resource_usage("godot://scene/current", True, 3.0)
        collector._queue.join()
        assert [r.record_type for r in staged] == [tel.RecordType.RESOURCE_RETRIEVAL]
        assert collector._rollup == {}


# --- wire shape ----------------------------------------------------------


class TestBatchBody:
    def test_body_is_events_list_split_at_500(self, env, client) -> None:
        collector = tel.TelemetryCollector()
        for n in range(501):
            collector._add_pending(
                tel.TelemetryRecord(tel.RecordType.USAGE, 1.0, "u", "", {"n": n})
            )
        collector._flush()

        bodies = _bodies(client)
        assert [list(body) for body in bodies] == [["events"], ["events"]]
        assert [len(body["events"]) for body in bodies] == [500, 1]
        assert [e["data"]["n"] for e in _events(client)] == list(range(501))
        collector.shutdown()

    def test_pending_is_capped(self, env, client) -> None:
        collector = tel.TelemetryCollector()
        for n in range(collector.PENDING_MAXSIZE + 5):
            collector._add_pending(
                tel.TelemetryRecord(tel.RecordType.USAGE, 1.0, "u", "", {"n": n})
            )
        assert len(collector._pending) == collector.PENDING_MAXSIZE
        collector.shutdown()

    def test_rollup_event_shape(self, env, client) -> None:
        collector = tel.TelemetryCollector()
        before = time.time()
        collector.record_tool_success("node_create", 5.0)
        collector.record_tool_success("node_create", 70000.0)
        collector.record_tool_success("scene_manage", 300.0, sub_action="save_as")
        collector._flush()
        after = time.time()

        [event] = _events(client)
        assert event["record"] == "tool_rollup"
        assert event["session_id"] == ""
        assert event["customer_uuid"] == collector._customer_uuid
        assert {"version", "platform", "source"} <= set(event)
        assert "milestone" not in event
        data = event["data"]
        assert before <= data["window_start"] <= data["window_end"] <= after
        assert event["timestamp"] == data["window_start"]
        assert data["platform_detail"] and data["python_version"]
        assert data["tools"] == [
            {"tool_name": "node_create", "sub_action": None, "s": "", "ok": 2,
             "h": _hist(b0=1, b12=1)},
            {"tool_name": "scene_manage", "sub_action": "save_as", "s": "", "ok": 1,
             "h": _hist(b5=1)},
        ]  # fmt: skip
        for tool in data["tools"]:
            assert tool["ok"] == sum(tool["h"])

        ## Counters were swapped out: a second flush has nothing to send.
        assert collector._rollup == {}
        collector._flush()
        assert client.post.call_count == 1
        collector.shutdown()

    def test_rollup_window_restarts_after_flush(self, env, client) -> None:
        collector = tel.TelemetryCollector()
        collector.record_tool_success("a", 1.0)
        collector._flush()
        time.sleep(0.01)
        second_start = time.time()
        collector.record_tool_success("a", 1.0)
        collector._flush()
        first, second = _events(client)
        assert second["data"]["window_start"] >= second_start > first["data"]["window_start"]
        collector.shutdown()

    def test_rollup_tools_capped_per_event(self, env, client) -> None:
        collector = tel.TelemetryCollector()
        for n in range(collector.MAX_ROLLUP_TOOLS + 1):
            collector.record_tool_success(f"tool_{n}", 1.0)
        collector._flush()

        events = _events(client)
        assert [e["record"] for e in events] == ["tool_rollup", "tool_rollup"]
        assert [len(e["data"]["tools"]) for e in events] == [1000, 1]
        assert len({e["data"]["window_start"] for e in events}) == 1
        collector.shutdown()


# --- cadence -------------------------------------------------------------


class TestFlushCadence:
    @pytest.mark.parametrize(
        ("raw", "expected"),
        [
            (None, 900.0),
            ("", 900.0),
            ("30", 30.0),
            ("2.5", 2.5),
            ("0.2", 1.0),
            ("-5", 1.0),
            ("abc", 900.0),
            ("nan", 900.0),
            ("inf", 900.0),
        ],
    )
    def test_interval_env_override(self, env, raw, expected) -> None:
        if raw is None:
            env.delenv("GODOT_AI_TELEMETRY_FLUSH_INTERVAL", raising=False)
        else:
            env.setenv("GODOT_AI_TELEMETRY_FLUSH_INTERVAL", raw)
        assert tel.TelemetryCollector._resolve_flush_interval() == expected

    def test_default_interval_is_fifteen_minutes(self) -> None:
        assert tel.TelemetryCollector.FLUSH_INTERVAL_S == 900.0

    def test_no_post_before_interval_then_one_batch_after(self, env, client) -> None:
        env.setenv("GODOT_AI_TELEMETRY_FLUSH_INTERVAL", "1")
        collector = tel.TelemetryCollector()
        collector.record(tel.RecordType.USAGE, {"n": 1})
        collector.record_tool_success("a", 1.0)
        collector.record(tel.RecordType.USAGE, {"n": 2})

        time.sleep(0.4)
        client.post.assert_not_called()

        deadline = time.monotonic() + 3.0
        while not client.post.called and time.monotonic() < deadline:
            time.sleep(0.05)
        assert client.post.call_count == 1
        records = [e["record"] for e in _events(client)]
        assert records == ["usage", "usage", "tool_rollup"]

        ## Nothing pending: later intervals elapse without a POST.
        time.sleep(1.8)
        assert client.post.call_count == 1
        collector.shutdown()
        assert client.post.call_count == 1

    def test_default_interval_holds_events(self, env, client) -> None:
        collector = tel.TelemetryCollector()
        collector.record(tel.RecordType.USAGE, {"n": 1})
        collector._queue.join()
        time.sleep(0.6)  ## at least one worker poll cycle
        client.post.assert_not_called()
        assert len(collector._pending) == 1
        collector.shutdown()


# --- shutdown + opt-out --------------------------------------------------


class TestShutdownFlush:
    def test_shutdown_performs_final_flush(self, env, client) -> None:
        collector = tel.TelemetryCollector()
        collector.record(tel.RecordType.USAGE, {"n": 1})
        collector.record_tool_success("a", 1.0)
        tel_failure = {"tool_name": "b", "success": False, "duration_ms": 1.0}
        collector.record(tel.RecordType.TOOL_EXECUTION, tel_failure)

        started = time.monotonic()
        collector.shutdown()

        assert time.monotonic() - started < collector.SHUTDOWN_TIMEOUT
        assert not collector._worker.is_alive()
        assert client.post.call_count == 1
        assert [e["record"] for e in _events(client)] == [
            "usage",
            "tool_execution",
            "tool_rollup",
        ]
        client.close.assert_called_once()

    def test_shutdown_with_nothing_pending_does_not_post(self, env, client) -> None:
        collector = tel.TelemetryCollector()
        collector.shutdown()
        client.post.assert_not_called()


class TestOptOutDropsPending:
    def _fill(self, collector: tel.TelemetryCollector) -> None:
        collector.record(tel.RecordType.USAGE, {"n": 1})
        collector.record_tool_success("a", 1.0)
        collector._queue.join()
        assert collector._pending and collector._rollup

    def test_env_opt_out_drops_pending_and_counters(self, env, client) -> None:
        collector = tel.TelemetryCollector()
        self._fill(collector)
        env.setenv("GODOT_AI_DISABLE_TELEMETRY", "true")

        collector.shutdown()

        client.post.assert_not_called()
        assert collector._pending == []
        assert collector._rollup == {}

    def test_runtime_latch_drops_pending_and_counters(self, env, client) -> None:
        collector = tel.TelemetryCollector()
        self._fill(collector)
        tel.latch_runtime_opt_out()

        collector._flush()

        client.post.assert_not_called()
        assert collector._pending == []
        assert collector._rollup == {}
        collector.shutdown()
        client.post.assert_not_called()

    def test_opted_out_successes_are_not_counted(self, env) -> None:
        collector = tel.TelemetryCollector()
        tel.latch_runtime_opt_out()
        collector.record_tool_success("a", 1.0)
        assert collector._rollup == {}
        collector.shutdown()

    def test_disabled_collector_counts_nothing(self, env) -> None:
        env.setenv("GODOT_AI_DISABLE_TELEMETRY", "1")
        collector = tel.TelemetryCollector()
        collector.record_tool_success("a", 1.0)
        assert collector._rollup == {}
        collector.shutdown()
