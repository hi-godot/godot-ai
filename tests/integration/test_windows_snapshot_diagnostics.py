"""Real PowerShell collection preserves proof semantics with optional diagnostics."""

import sys

import pytest

from tests.integration.test_unix_startup import run_probe

pytestmark = [
    pytest.mark.editor,
    pytest.mark.skipif(sys.platform != "win32", reason="Windows collector"),
]


@pytest.mark.parametrize(
    "control,category",
    [
        ("ancestor_creation_empty", "row_identity"),
        # A parent PID that points at a newer process is a reused PID: the
        # chain ends there instead of looping (the CI failure in run 43952810276).
        ("ancestor_cycle", None),
        ("ancestor_cycle_same_age", "lineage_cycle"),
        ("target_cim_missing", None),
    ],
)
def test_snapshot_diagnostics_classify_real_collector_controls(tmp_path, control, category):
    result = run_probe(
        tmp_path,
        r"""    var target := OS.get_process_id()
    var query: String = Ports._windows_process_snapshot_script(target)
    var control := OS.get_environment("SNAPSHOT_TEST_CONTROL")
    var injection := ""
    if control == "target_cim_missing":
        injection = "$processes.Remove(%d); " % target
    else:
        injection = ("$ancestor = [int]$processes[%d].ParentProcessId; "
            + "$original = $processes[$ancestor]; "
            + "if ($null -eq $original) { throw 'control_precondition' }; ") % target
        var creation := "$original.CreationDate"
        if control == "ancestor_creation_empty":
            creation = "''"
        elif control == "ancestor_cycle_same_age":
            creation = "$processes[%d].CreationDate" % target
        var parent := "$original.ParentProcessId"
        if control.begins_with("ancestor_cycle"):
            parent = str(target)
        injection += ("$processes[$ancestor] = [pscustomobject]@{"
            + "ProcessId=$original.ProcessId;ParentProcessId=%s;CreationDate=%s;"
            + "CommandLine=$original.CommandLine}; ") % [parent, creation]
    query = query.replace("for ($depth", injection + "for ($depth")
    var shell_output: Array = []
    result["shell_exit"] = Ports.execute_windows_powershell(query, shell_output)
    var raw := str(shell_output[0]) if not shell_output.is_empty() else ""
    var diagnostics: Array = []
    var snapshot := Ports.parse_process_snapshot(raw, target, diagnostics)
    result["same_without_sink"] = snapshot == Ports.parse_process_snapshot(raw, target)
    result["failed"] = Ports.capture_failed(snapshot)
    result["diagnostics"] = diagnostics
    result["failure_category"] = (
        Ports.snapshot_failure_category(diagnostics[0].category, diagnostics[0].depth)
        if not diagnostics.is_empty() else ""
    )
    result["fingerprint"] = not Ports.process_fingerprint(target, snapshot).is_empty()
    result["brand"] = Ports.pid_cmdline_is_godot_ai(target, snapshot)
    var rows: Variant = JSON.parse_string(raw)
    result["target_valid"] = false
    if rows is Array and not rows.is_empty():
        var target_only := Ports.parse_process_snapshot(JSON.stringify([rows[0]]), target)
        result["target_valid"] = not Ports.capture_failed(target_only)
""",
        environment={"SNAPSHOT_TEST_CONTROL": control},
    )
    assert result["shell_exit"] == 0
    assert result["same_without_sink"] is True
    assert result["target_valid"] is True
    if category is None:
        assert result["failed"] is False
        assert result["diagnostics"] == []
        assert result["fingerprint"] is True
        assert result["brand"] is False
    else:
        assert result["failed"] is True
        assert result["fingerprint"] is False
        assert result["diagnostics"] == [
            {"category": category, "stage": "single", "depth": 1, "elapsed_ms": -1, "count": 1}
        ]
        assert result["failure_category"] == "ancestor_capture"
