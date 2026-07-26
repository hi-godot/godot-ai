"""One-shot probe for #797 — TEMPORARY, delete with its workflow once read.

Question it answers, on a real Windows host: does a uv-created venv's
`python.exe` hand back a PID that dies while the real interpreter keeps
running? That premise is what PR #837's handoff fix rests on, and it is the
one part of that change that cannot be verified off Windows.

Deliberately *not* an end-to-end test of the fix. Whether the bug's symptom
appears is a race against the plugin's 5s spawn grace (the original report saw
it in 1 of 4 boots), so an end-to-end assertion would be flaky and would pass
without the fix most of the time. The trampoline's existence is deterministic,
so that is what this measures.

Exits 0 regardless of verdict: this is signal to read, not a gate.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

POLL_SECONDS = 0.25
PID_FILE_TIMEOUT_SECONDS = 90


def pid_alive(pid: int) -> bool:
    """Liveness via tasklist, mirroring PortResolver.pid_alive on Windows."""
    if pid <= 0:
        return False
    if os.name != "nt":
        try:
            os.kill(pid, 0)
        except OSError:
            return False
        return True
    out = subprocess.run(
        ["tasklist", "/FI", f"PID eq {pid}", "/NH", "/FO", "CSV"],
        capture_output=True,
        text=True,
    )
    return f'"{pid}"' in out.stdout


def main() -> int:
    venv_python = Path(sys.argv[1])
    pid_file = Path(sys.argv[2]).resolve()
    pid_file.parent.mkdir(parents=True, exist_ok=True)
    if pid_file.exists():
        pid_file.unlink()

    cmd = [
        str(venv_python),
        "-m",
        "godot_ai",
        "--transport",
        "streamable-http",
        "--port",
        "8765",
        "--ws-port",
        "9765",
        "--pid-file",
        str(pid_file),
    ]
    ## Detached, exactly as the plugin spawns it: the trampoline must not be
    ## held open by inherited handles, or the hop under test cannot happen.
    flags = 0
    if os.name == "nt":
        flags = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS
    started = time.monotonic()
    proc = subprocess.Popen(
        cmd,
        creationflags=flags,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    spawn_pid = proc.pid

    real_pid = 0
    spawn_exit_ms = -1
    deadline = started + PID_FILE_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if spawn_exit_ms < 0 and proc.poll() is not None:
            spawn_exit_ms = int((time.monotonic() - started) * 1000)
        if real_pid <= 0 and pid_file.exists():
            text = pid_file.read_text(encoding="utf-8", errors="replace").strip()
            if text.isdigit():
                real_pid = int(text)
        if real_pid > 0 and spawn_exit_ms >= 0:
            break
        time.sleep(POLL_SECONDS)

    pid_file_ms = int((time.monotonic() - started) * 1000) if real_pid > 0 else -1
    spawn_still_alive = proc.poll() is None
    real_is_alive = pid_alive(real_pid)

    trampoline = (
        real_pid > 0
        and real_pid != spawn_pid
        and not spawn_still_alive
        and real_is_alive
    )

    result = {
        "spawn_pid": spawn_pid,
        "pid_file_pid": real_pid,
        "pids_differ": real_pid > 0 and real_pid != spawn_pid,
        "spawn_pid_still_alive": spawn_still_alive,
        "spawn_pid_exited_after_ms": spawn_exit_ms,
        "pid_file_published_after_ms": pid_file_ms,
        "pid_file_pid_alive": real_is_alive,
        "trampoline_confirmed": trampoline,
    }

    ## Clean up whichever process is still standing.
    for pid in (real_pid, spawn_pid):
        if pid > 0 and pid_alive(pid):
            if os.name == "nt":
                subprocess.run(
                    ["taskkill", "/F", "/PID", str(pid)], capture_output=True
                )
            else:
                try:
                    os.kill(pid, 9)
                except OSError:
                    pass

    print("#797 PROBE RESULT " + json.dumps(result, indent=2))
    if trampoline:
        print(
            "#797 VERDICT: TRAMPOLINE CONFIRMED — the watched spawn PID died "
            f"after {spawn_exit_ms}ms while the real server (PID {real_pid}) "
            f"kept running; its pid-file landed at {pid_file_ms}ms. The gap "
            "between those two numbers is the window PR #837 waits out."
        )
    elif real_pid > 0 and real_pid == spawn_pid:
        print(
            "#797 VERDICT: NO TRAMPOLINE — the spawned PID is the server's own "
            "PID, so this venv's python.exe execs rather than hopping. The "
            "handoff branch would never fire on a host like this."
        )
    else:
        print(
            "#797 VERDICT: INCONCLUSIVE — see the fields above. A pid_file_pid "
            "of 0 means the server never published within the timeout, which "
            "is a probe/environment failure rather than an answer."
        )

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("## #797 Windows trampoline probe\n\n```json\n")
            handle.write(json.dumps(result, indent=2))
            handle.write("\n```\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
