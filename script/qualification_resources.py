"""Read-only, identity-bound resource samples; never release approval.

Run with ``python -m script.qualification_resources`` from the reviewed harness
checkout. The caller proves which editor/backend PIDs belong to its disposable
project. This collector never discovers targets from names or follows PID reuse.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import re
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path

import psutil

PSUTIL_VERSION = "7.2.2"
ROLE = re.compile(r"[a-z][a-z0-9_-]{0,47}")


class ResourceError(ValueError):
    """A measurement cannot be attributed to the requested process identity."""


@dataclass(frozen=True)
class ProcessBinding:
    pid: int
    created_at: float

    def __post_init__(self) -> None:
        if type(self.pid) is not int or self.pid <= 1:
            raise ResourceError("process PID must be an integer greater than one")
        if (
            type(self.created_at) not in (int, float)
            or not math.isfinite(self.created_at)
            or self.created_at <= 0
        ):
            raise ResourceError("process creation time must be positive and finite")


def _process(pid: int):
    process = psutil.Process(pid)
    if process.status() in (psutil.STATUS_DEAD, psutil.STATUS_ZOMBIE):
        raise ResourceError("requested process is dead or a zombie")
    return process


def bind_process(pid: int) -> ProcessBinding:
    """Pin the caller's explicit PID before its workload; no automatic repin."""
    ProcessBinding(pid, 1.0)  # Validate before asking the OS about a target.
    try:
        return ProcessBinding(pid, _process(pid).create_time())
    except (psutil.Error, OSError):
        raise ResourceError("cannot prove requested process identity") from None


def _count(value: int, *, minimum: int = 0) -> int:
    if type(value) is not int or value < minimum:
        raise ResourceError("process returned an invalid resource count")
    return value


def sample_process(binding: ProcessBinding) -> dict:
    """Measure one PID between fresh start-time checks, without cached identity.

    Counts are observations over a bounded call sequence, not an atomic OS
    snapshot. Windows handles are explicitly NOT reported as Unix descriptors.
    """
    try:
        process = _process(binding.pid)
        if process.create_time() != binding.created_at:
            raise ResourceError("requested process identity changed")
        rss = _count(process.memory_info().rss)
        threads = _count(process.num_threads(), minimum=1)
        if sys.platform == "win32":
            descriptors = None
            handles = _count(process.num_handles())
        elif sys.platform in ("darwin", "linux"):
            descriptors = _count(process.num_fds())
            handles = None
        else:
            raise ResourceError("resource collector supports only required desktop platforms")
        # create_time is cached on a psutil.Process object. Construct another
        # one so exit/reuse during the reads cannot borrow the first identity.
        if _process(binding.pid).create_time() != binding.created_at:
            raise ResourceError("requested process identity changed during measurement")
    except (psutil.Error, OSError):
        raise ResourceError("process measurement unavailable; no zero-value fallback") from None
    return {
        **asdict(binding),
        "rss_bytes": rss,
        "threads": threads,
        "file_descriptors": descriptors,
        "handles": handles,
    }


def collect(specs: list[str], output: Path, *, count: int, interval: float) -> int:
    """Retain each sample immediately; an incomplete/failed stream is not green."""
    if (
        type(count) is not int
        or not 1 <= count <= 3600
        or type(interval) not in (int, float)
        or not math.isfinite(interval)
        or not 0.01 <= interval <= 60
    ):
        raise ResourceError("require 1–3600 samples and a finite 0.01–60 second interval")
    if psutil.__version__ != PSUTIL_VERSION:
        raise ResourceError("resource collector requires the pinned psutil version")
    if not 1 <= len(specs) <= 32:
        raise ResourceError("require one to 32 explicit ROLE=PID targets")
    pids = {}
    for spec in specs:
        role, separator, raw_pid = spec.partition("=")
        if (
            not separator
            or ROLE.fullmatch(role) is None
            or re.fullmatch(r"[1-9][0-9]{0,9}", raw_pid) is None
            or role in pids
        ):
            raise ResourceError("targets must be unique ROLE=PID bindings")
        pids[role] = int(raw_pid)
        ProcessBinding(pids[role], 1.0)
    if len(set(pids.values())) != len(pids):
        raise ResourceError("each target must name a distinct process")

    # O_EXCL refuses existing files, symlinks and FIFOs. Never truncate earlier
    # evidence. The enclosing harness chooses its external artifact directory.
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:

        def emit(row: dict) -> None:
            stream.write(json.dumps(row, sort_keys=True, allow_nan=False) + "\n")
            stream.flush()
            os.fsync(stream.fileno())

        try:
            bindings = {role: bind_process(pid) for role, pid in pids.items()}
            emit(
                {
                    "event": "header",
                    "schema_version": 1,
                    "purpose": "resource_measurement_not_release_approval",
                    "platform": sys.platform,
                    "architecture": platform.machine(),
                    "python": platform.python_version(),
                    "psutil": psutil.__version__,
                    "bindings": {role: asdict(binding) for role, binding in bindings.items()},
                    "requested_samples": count,
                    "interval_seconds": interval,
                }
            )
            for sequence in range(count):
                started = time.monotonic_ns()
                samples = {role: sample_process(binding) for role, binding in bindings.items()}
                emit(
                    {
                        "event": "sample",
                        "sequence": sequence,
                        "started_monotonic_ns": started,
                        "finished_monotonic_ns": time.monotonic_ns(),
                        "processes": samples,
                    }
                )
                if sequence + 1 < count:
                    time.sleep(interval)
            emit({"event": "complete", "status": "measured", "samples": count})
            return 0
        except ResourceError as error:
            emit({"event": "error", "status": "failed", "reason": str(error)})
            return 2


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--process", action="append", required=True, metavar="ROLE=PID")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--count", type=int, default=1)
    parser.add_argument("--interval", type=float, default=1.0)
    args = parser.parse_args(argv)
    try:
        return collect(args.process, args.output, count=args.count, interval=args.interval)
    except (ResourceError, OSError):
        # OS exception strings may contain caller-controlled paths. The fixed
        # diagnostic does not expose process arguments, environment or tokens.
        print(
            "resource measurement refused; preserve existing evidence and inspect inputs",
            file=sys.stderr,
        )
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
