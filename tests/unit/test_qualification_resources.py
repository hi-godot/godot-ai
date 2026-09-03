"""Measurement identity/availability proofs; no simulated row grants approval."""

import copy
import json
import runpy
from pathlib import Path
from types import SimpleNamespace

import psutil
import pytest

from script import qualification_resources as resources


class Process:
    def __init__(self, *, created=123.5, status="running", rss=4096, threads=3, fds=7, handles=9):
        self.created = created
        self.state = status
        self.rss = rss
        self.threads = threads
        self.fds = fds
        self.handles = handles

    def create_time(self):
        return self.created

    def status(self):
        return self.state

    def memory_info(self):
        return SimpleNamespace(rss=self.rss)

    def num_threads(self):
        return self.threads

    def num_fds(self):
        return self.fds

    def num_handles(self):
        return self.handles


@pytest.fixture
def process(monkeypatch):
    item = Process()
    monkeypatch.setattr(resources.psutil, "Process", lambda pid: copy.copy(item))
    return item


@pytest.mark.parametrize("pid", [True, 0, 1, -1, 3.0, "3", None])
def test_invalid_pid_refuses_before_os_access(monkeypatch, pid):
    def forbidden(pid):
        pytest.fail("invalid PID reached the OS")

    monkeypatch.setattr(resources.psutil, "Process", forbidden)
    with pytest.raises(resources.ResourceError, match="PID"):
        resources.bind_process(pid)


@pytest.mark.parametrize("created", [True, 0, -1, float("nan"), float("inf"), "123", None])
def test_invalid_creation_time_is_never_an_identity(created):
    with pytest.raises(resources.ResourceError, match="creation time"):
        resources.ProcessBinding(100, created)


@pytest.mark.parametrize("platform", ["darwin", "linux", "win32"])
def test_snapshot_has_fresh_identity_and_platform_specific_counters(monkeypatch, platform):
    seen = []

    def factory(pid):
        seen.append(pid)
        return Process()

    monkeypatch.setattr(resources.psutil, "Process", factory)
    monkeypatch.setattr(resources.sys, "platform", platform)
    binding = resources.bind_process(100)
    row = resources.sample_process(binding)
    assert seen == [100, 100, 100], "end identity must use a new Process, not cached create_time"
    assert row == {
        "pid": 100,
        "created_at": 123.5,
        "rss_bytes": 4096,
        "threads": 3,
        "file_descriptors": None if platform == "win32" else 7,
        "handles": 9 if platform == "win32" else None,
    }


@pytest.mark.parametrize("status", [psutil.STATUS_DEAD, psutil.STATUS_ZOMBIE])
def test_dead_or_zombie_is_not_a_successful_sample(process, status):
    process.state = status
    with pytest.raises(resources.ResourceError, match="dead or a zombie"):
        resources.bind_process(100)
    with pytest.raises(resources.ResourceError, match="dead or a zombie"):
        resources.sample_process(resources.ProcessBinding(100, 123.5))


@pytest.mark.parametrize("when", ["before", "during"])
def test_pid_reuse_never_rebinds(monkeypatch, when):
    calls = iter([Process(created=999 if when == "before" else 123.5), Process(created=999)])
    monkeypatch.setattr(resources.psutil, "Process", lambda pid: next(calls))
    with pytest.raises(resources.ResourceError, match="identity changed"):
        resources.sample_process(resources.ProcessBinding(100, 123.5))


@pytest.mark.parametrize(
    "error", [psutil.NoSuchProcess(100), psutil.AccessDenied(100), OSError("secret")]
)
def test_unavailable_identity_is_sanitized_not_zero(monkeypatch, error):
    def unavailable(pid):
        raise error

    monkeypatch.setattr(resources.psutil, "Process", unavailable)
    with pytest.raises(resources.ResourceError, match="cannot prove") as bind_error:
        resources.bind_process(100)
    with pytest.raises(resources.ResourceError, match="no zero-value fallback") as sample_error:
        resources.sample_process(resources.ProcessBinding(100, 123.5))
    assert "secret" not in str(bind_error.value) + str(sample_error.value)


@pytest.mark.parametrize("method", ["memory_info", "num_threads", "num_fds", "num_handles"])
def test_counter_access_failure_is_fatal(monkeypatch, method):
    monkeypatch.setattr(resources.sys, "platform", "win32" if method == "num_handles" else "linux")

    def denied(self):
        raise psutil.AccessDenied(100, "secret argument")

    monkeypatch.setattr(Process, method, denied)
    monkeypatch.setattr(resources.psutil, "Process", lambda pid: Process())
    with pytest.raises(resources.ResourceError, match="unavailable") as caught:
        resources.sample_process(resources.ProcessBinding(100, 123.5))
    assert "secret" not in str(caught.value)


@pytest.mark.parametrize(
    "field,value", [("rss", -1), ("rss", True), ("threads", 0), ("fds", -1), ("handles", 1.5)]
)
def test_invalid_counts_are_rejected(process, monkeypatch, field, value):
    monkeypatch.setattr(resources.sys, "platform", "win32" if field == "handles" else "linux")
    setattr(process, field, value)
    with pytest.raises(resources.ResourceError, match="invalid resource count"):
        resources.sample_process(resources.ProcessBinding(100, 123.5))


def test_unsupported_platform_is_explicit(process, monkeypatch):
    monkeypatch.setattr(resources.sys, "platform", "other")
    with pytest.raises(resources.ResourceError, match="desktop platforms"):
        resources.sample_process(resources.ProcessBinding(100, 123.5))


def rows(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def test_stream_preserves_bindings_order_timing_and_measurement_only_status(
    process, monkeypatch, tmp_path
):
    output = tmp_path / "measurement.jsonl"
    sleeps = []
    monkeypatch.setattr(resources.time, "sleep", sleeps.append)
    ticks = iter([100, 110, 210, 220])
    monkeypatch.setattr(resources.time, "monotonic_ns", lambda: next(ticks))
    assert resources.collect(["editor-a=100", "backend=101"], output, count=2, interval=0.1) == 0
    header, first, second, completion = rows(output)
    assert header["purpose"] == "resource_measurement_not_release_approval"
    assert header["bindings"] == {
        "editor-a": {"pid": 100, "created_at": 123.5},
        "backend": {"pid": 101, "created_at": 123.5},
    }
    assert [first["sequence"], second["sequence"]] == [0, 1]
    assert [
        first["started_monotonic_ns"],
        first["finished_monotonic_ns"],
        second["started_monotonic_ns"],
        second["finished_monotonic_ns"],
    ] == [100, 110, 210, 220]
    assert sleeps == [0.1]
    assert completion == {"event": "complete", "status": "measured", "samples": 2}
    assert set(first["processes"]) == {"editor-a", "backend"}
    content = output.read_text(encoding="utf-8")
    assert "command" not in content and "environment" not in content


def test_failure_retains_prior_samples_and_no_completion(process, monkeypatch, tmp_path):
    output = tmp_path / "measurement.jsonl"

    def die(_interval):
        # The first sample has already reached disk before the next wait.
        assert [row["event"] for row in rows(output)] == ["header", "sample"]
        process.created = 999

    monkeypatch.setattr(resources.time, "sleep", die)
    assert resources.collect(["editor-a=100"], output, count=3, interval=0.1) == 2
    assert [row["event"] for row in rows(output)] == ["header", "sample", "error"]
    assert rows(output)[-1]["status"] == "failed"


def test_binding_failure_is_retained_without_false_header(monkeypatch, tmp_path):
    def missing(pid):
        raise psutil.NoSuchProcess(pid)

    monkeypatch.setattr(resources.psutil, "Process", missing)
    output = tmp_path / "measurement.jsonl"
    assert resources.collect(["editor-a=100"], output, count=1, interval=1) == 2
    assert rows(output) == [
        {"event": "error", "status": "failed", "reason": "cannot prove requested process identity"}
    ]


@pytest.mark.parametrize(
    "count,interval", [(True, 1), (0, 1), (3601, 1), (1, 0), (1, 61), (1, float("nan")), (1, True)]
)
def test_invalid_schedule_creates_no_output(tmp_path, count, interval):
    output = tmp_path / "measurement.jsonl"
    with pytest.raises(resources.ResourceError, match="samples"):
        resources.collect(["editor=100"], output, count=count, interval=interval)
    assert not output.exists()


@pytest.mark.parametrize(
    "specs",
    [
        [],
        ["a=100"] * 33,
        ["a=100", "a=101"],
        ["a=100", "b=100"],
        ["=100"],
        ["a=1"],
        ["a=-1"],
        ["a=0100"],
        ["a=100;secret"],
        ["a"],
        ["a/secret=100"],
    ],
)
def test_invalid_bindings_create_no_output(tmp_path, specs):
    output = tmp_path / "measurement.jsonl"
    with pytest.raises(resources.ResourceError):
        resources.collect(specs, output, count=1, interval=1)
    assert not output.exists()


def test_wrong_collector_version_does_not_measure(monkeypatch, tmp_path):
    monkeypatch.setattr(resources.psutil, "__version__", "other")
    with pytest.raises(resources.ResourceError, match="pinned psutil"):
        resources.collect(["a=100"], tmp_path / "out", count=1, interval=1)


def test_never_overwrites_existing_evidence(process, tmp_path):
    output = tmp_path / "existing"
    output.write_text("retained", encoding="utf-8")
    with pytest.raises(FileExistsError):
        resources.collect(["a=100"], output, count=1, interval=1)
    assert output.read_text(encoding="utf-8") == "retained"


def test_cli_success_and_sanitized_failure(process, tmp_path, capsys):
    output = tmp_path / "secret-path"
    args = ["--process", "a=100", "--output", str(output), "--count", "1"]
    assert resources.main(args) == 0
    before = output.read_bytes()
    assert resources.main(args) == 2
    assert output.read_bytes() == before
    assert "secret-path" not in capsys.readouterr().err


def test_dependency_pin_is_test_only_and_in_qualification_runner():
    import tomllib

    from script.release_qualification import TEST_REQUIREMENTS

    config = tomllib.loads(
        (Path(__file__).parents[2] / "pyproject.toml").read_text(encoding="utf-8")
    )
    expected = f"psutil=={resources.PSUTIL_VERSION}"
    assert expected in config["project"]["optional-dependencies"]["dev"]
    assert expected in TEST_REQUIREMENTS
    assert all(not item.startswith("psutil") for item in config["project"]["dependencies"])


def test_module_entrypoint_uses_cli_exit_status(process, monkeypatch, tmp_path):
    monkeypatch.setattr(
        resources.sys,
        "argv",
        [
            "qualification_resources",
            "--process",
            "a=100",
            "--output",
            str(tmp_path / "samples"),
        ],
    )
    with pytest.raises(SystemExit) as caught:
        runpy.run_path(str(Path(resources.__file__)), run_name="__main__")
    assert caught.value.code == 0


def test_io_failure_never_returns_a_measurement_success(process, monkeypatch, tmp_path, capsys):
    def denied(fd):
        raise OSError("secret file path")

    monkeypatch.setattr(resources.os, "fsync", denied)
    output = tmp_path / "interrupted"
    assert resources.main(["--process", "a=100", "--output", str(output)]) == 2
    assert not any(row["event"] == "complete" for row in rows(output))
    assert "secret" not in capsys.readouterr().err
