"""#647: startup pre-flight for HTTP/WS ports held by a foreign process."""

from __future__ import annotations

import json
import re
import socket
import threading
import time
from contextlib import closing
from pathlib import Path
from types import SimpleNamespace

import pytest

import godot_ai
from godot_ai import EXIT_PORT_IN_USE, main, preflight_check_port


def _reserve_port() -> tuple[socket.socket, int]:
    """Bind + listen a throwaway socket on a random free loopback port."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    sock.listen(1)
    return sock, sock.getsockname()[1]


def _free_port() -> int:
    with closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def test_preflight_passes_on_free_port() -> None:
    ## Must also not leave the port unbindable afterwards (probe socket is
    ## closed, SO_REUSEADDR set) — bind it again to prove that.
    port = _free_port()
    preflight_check_port(port, label="HTTP", setting="godot_ai/http_port")
    with closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as sock:
        sock.bind(("127.0.0.1", port))


def test_preflight_exits_with_distinctive_code_and_message(
    capsys: pytest.CaptureFixture[str],
) -> None:
    blocker, port = _reserve_port()
    try:
        with pytest.raises(SystemExit) as excinfo:
            preflight_check_port(port, label="HTTP", setting="godot_ai/http_port")
    finally:
        blocker.close()
    assert excinfo.value.code == EXIT_PORT_IN_USE
    err = capsys.readouterr().err
    assert f"HTTP port {port} is already in use by another process" in err
    assert "godot_ai/http_port" in err


def test_main_exits_before_serving_when_http_port_taken(
    capsys: pytest.CaptureFixture[str],
) -> None:
    blocker, port = _reserve_port()
    try:
        with pytest.raises(SystemExit) as excinfo:
            main(
                [
                    "--transport",
                    "streamable-http",
                    "--port",
                    str(port),
                    "--ws-port",
                    str(_free_port()),
                ]
            )
    finally:
        blocker.close()
    assert excinfo.value.code == EXIT_PORT_IN_USE
    assert f"HTTP port {port} is already in use" in capsys.readouterr().err


def test_main_exits_when_ws_port_taken(capsys: pytest.CaptureFixture[str]) -> None:
    blocker, ws_port = _reserve_port()
    try:
        with pytest.raises(SystemExit) as excinfo:
            main(
                [
                    "--transport",
                    "streamable-http",
                    "--port",
                    str(_free_port()),
                    "--ws-port",
                    str(ws_port),
                ]
            )
    finally:
        blocker.close()
    assert excinfo.value.code == EXIT_PORT_IN_USE
    err = capsys.readouterr().err
    assert f"WebSocket port {ws_port} is already in use" in err
    assert "godot_ai/ws_port" in err


def _ipv6_available() -> bool:
    import socket

    try:
        socket.socket(socket.AF_INET6, socket.SOCK_STREAM).close()
        return True
    except OSError:
        return False


def test_preflight_ipv6_host_binds_with_correct_family():
    ## Copilot review on the #647 PR: --allow-host can resolve an IPv6 bind
    ## host ("::"); an AF_INET probe would raise an address-family error and
    ## crash startup instead of preflighting. A free port on "::1" must probe
    ## clean (no SystemExit, no OSError).
    import socket

    if not _ipv6_available():
        pytest.skip("IPv6 not available in this environment")
    sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    sock.bind(("::1", 0))
    port = sock.getsockname()[1]
    sock.close()
    preflight_check_port(port, label="HTTP", setting="godot_ai/http_port", host="::1")


def test_preflight_ipv6_host_detects_occupied_port():
    import socket

    if not _ipv6_available():
        pytest.skip("IPv6 not available in this environment")
    holder = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    holder.bind(("::1", 0))
    holder.listen(1)
    port = holder.getsockname()[1]
    try:
        with pytest.raises(SystemExit) as excinfo:
            preflight_check_port(port, label="HTTP", setting="godot_ai/http_port", host="::1")
        assert excinfo.value.code == EXIT_PORT_IN_USE
    finally:
        holder.close()


def _hold_port() -> tuple[socket.socket, int]:
    holder = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    holder.bind(("127.0.0.1", 0))
    holder.listen(1)
    return holder, holder.getsockname()[1]


def test_preflight_waits_for_the_port_when_the_plugin_asks(monkeypatch) -> None:
    holder, port = _hold_port()
    monkeypatch.setenv("GODOT_AI_WAIT_FOR_PORT_MS", "3000")
    started = time.monotonic()
    threading.Timer(0.3, holder.close).start()
    held = preflight_check_port(port, label="HTTP", setting="godot_ai/http_port")
    assert 0.25 <= time.monotonic() - started < 2.5
    # The port is held from the instant the wait ends, for the real server
    # to take over; nobody else can bind it in between.
    assert held is not None and held.getsockname()[1] == port
    other = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        with pytest.raises(OSError):
            other.bind(("127.0.0.1", port))
    finally:
        other.close()
        held.close()


def test_preflight_returns_nothing_on_the_ordinary_path(monkeypatch) -> None:
    monkeypatch.delenv("GODOT_AI_WAIT_FOR_PORT_MS", raising=False)
    probe, port = _hold_port()
    probe.close()
    assert preflight_check_port(port, label="HTTP", setting="godot_ai/http_port") is None
    reusable = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        reusable.bind(("127.0.0.1", port))
    finally:
        reusable.close()


@pytest.mark.parametrize("release_after", [25.262, 45.0, None])
def test_replacement_budget_survives_delayed_handoff_and_stays_bounded(
    monkeypatch, release_after
) -> None:
    # Use the actual plugin request so this catches either side reverting its
    # budget. A real socket stays occupied while a controlled clock advances.
    lifecycle = (
        Path(__file__).resolve().parents[2]
        / "plugin/addons/godot_ai/utils/server_lifecycle.gd"
    ).read_text(encoding="utf-8")
    match = re.search(r"const REPLACEMENT_WAIT_FOR_PORT_MS := ([\d_]+)", lifecycle)
    assert match is not None
    requested_ms = int(match[1].replace("_", ""))
    monkeypatch.setenv("GODOT_AI_WAIT_FOR_PORT_MS", str(requested_ms))
    holder, port = _hold_port()
    elapsed = 0.0

    def advance(_seconds: float) -> None:
        nonlocal elapsed
        elapsed += 1.0
        if release_after is not None and elapsed >= release_after:
            holder.close()

    monkeypatch.setattr(
        godot_ai, "time", SimpleNamespace(monotonic=lambda: elapsed, sleep=advance)
    )
    held = None
    try:
        if release_after is None:
            with pytest.raises(SystemExit) as raised:
                preflight_check_port(port, label="HTTP", setting="godot_ai/http_port")
            assert raised.value.code == EXIT_PORT_IN_USE
            assert elapsed == 60.0
        else:
            held = preflight_check_port(port, label="HTTP", setting="godot_ai/http_port")
            assert release_after <= elapsed < release_after + 1.0
            assert held is not None and held.getsockname()[1] == port
            with closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as other:
                with pytest.raises(OSError):
                    other.bind(("127.0.0.1", port))
    finally:
        holder.close()
        if held is not None:
            held.close()


def test_preflight_still_fails_fast_without_the_wait(monkeypatch) -> None:
    holder, port = _hold_port()
    monkeypatch.delenv("GODOT_AI_WAIT_FOR_PORT_MS", raising=False)
    try:
        started = time.monotonic()
        with pytest.raises(SystemExit) as raised:
            preflight_check_port(port, label="HTTP", setting="godot_ai/http_port")
        assert raised.value.code == EXIT_PORT_IN_USE
        assert time.monotonic() - started < 0.5
    finally:
        holder.close()


def test_preflight_gives_up_after_the_wait(monkeypatch) -> None:
    holder, port = _hold_port()
    monkeypatch.setenv("GODOT_AI_WAIT_FOR_PORT_MS", "300")
    try:
        with pytest.raises(SystemExit) as raised:
            preflight_check_port(port, label="HTTP", setting="godot_ai/http_port")
        assert raised.value.code == EXIT_PORT_IN_USE
    finally:
        holder.close()


def test_preflight_reports_the_port_wait_phase_while_the_port_is_still_held(
    monkeypatch, tmp_path
) -> None:
    """The phase must exist before the bind succeeds: the plugin kills the
    occupant on reading it, so a phase written after bind and listen would
    reopen the port-free window the phase exists to close."""
    from godot_ai.runtime_info import (
        STARTUP_PHASE_WAITING_FOR_PORT,
        install_startup_report,
    )

    report = tmp_path / "startup-report.json"
    install_startup_report(report)
    holder, port = _hold_port()
    monkeypatch.setenv("GODOT_AI_WAIT_FOR_PORT_MS", "3000")
    monkeypatch.setenv("GODOT_AI_LAUNCH_ID", "launch-7")
    outcome: dict[str, object] = {}

    def run() -> None:
        try:
            outcome["held"] = preflight_check_port(port, label="HTTP", setting="godot_ai/http_port")
        except BaseException as exc:  # pragma: no cover - reported by the assertions
            outcome["error"] = exc

    worker = threading.Thread(target=run)
    try:
        worker.start()
        deadline = time.monotonic() + 2.0
        phase: dict[str, object] | None = None
        while phase is None and time.monotonic() < deadline:
            try:
                phase = json.loads(report.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                time.sleep(0.01)
        assert worker.is_alive(), outcome
        assert phase is not None, "no phase record while the port was held"
        assert phase["phase"] == STARTUP_PHASE_WAITING_FOR_PORT
        assert phase["port"] == port
        assert phase["launch_id"] == "launch-7"
        assert "error" not in phase
        holder.close()
        worker.join(timeout=2.5)
        assert not worker.is_alive()
        held = outcome.get("held")
        assert held is not None and held.getsockname()[1] == port
        held.close()
        # The wait ending is not a failure: the phase record stays as it was.
        assert json.loads(report.read_text(encoding="utf-8")) == phase
    finally:
        holder.close()
        install_startup_report(None)


def test_preflight_failure_after_the_wait_replaces_the_phase(monkeypatch, tmp_path) -> None:
    from godot_ai.runtime_info import install_startup_report

    report = tmp_path / "startup-report.json"
    install_startup_report(report)
    holder, port = _hold_port()
    monkeypatch.setenv("GODOT_AI_WAIT_FOR_PORT_MS", "300")
    try:
        with pytest.raises(SystemExit):
            preflight_check_port(port, label="HTTP", setting="godot_ai/http_port")
        final = json.loads(report.read_text(encoding="utf-8"))
        assert final["error"] == "OSError"
        assert "already in use" in final["message"]
        assert "phase" not in final
    finally:
        holder.close()
        install_startup_report(None)


def test_preflight_writes_no_phase_on_the_ordinary_path(monkeypatch, tmp_path) -> None:
    from godot_ai.runtime_info import install_startup_report

    report = tmp_path / "startup-report.json"
    install_startup_report(report)
    try:
        monkeypatch.delenv("GODOT_AI_WAIT_FOR_PORT_MS", raising=False)
        probe, port = _hold_port()
        probe.close()
        assert preflight_check_port(port, label="HTTP", setting="godot_ai/http_port") is None
        assert not report.exists()
    finally:
        install_startup_report(None)
