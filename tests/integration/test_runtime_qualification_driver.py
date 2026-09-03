import shutil
import subprocess

from script import runtime_qualification as runtime
from tests.integration._self_update_fixture import PLUGIN_ROOT, godot_bin_or_skip


def test_external_exact_candidate_driver_parses_in_real_godot(tmp_path):
    godot = godot_bin_or_skip()
    project = tmp_path / "project"
    addon = project / "addons/godot_ai"
    shutil.copytree(PLUGIN_ROOT, addon)
    certificate, _key = runtime._tls_material(tmp_path / "tls")
    runtime._write_project(project, certificate, "4.0.0", "4.0.1", enable_plugin=False)
    environment = {
        **runtime._isolated_environment(
            tmp_path / "environment", "http://127.0.0.1/private/simple/"
        ),
        "GODOT_AI_DISABLE_TELEMETRY": "true",
        "GODOT_AI_MODE": "dev",
        "GODOT_AI_RUNTIME_QUALIFICATION_PARSE_ONLY": "1",
        "PRIVATE_HTTPS_CERTIFICATE": str(certificate),
    }

    completed = subprocess.run(
        [godot, "--headless", "--editor", "--path", str(project)],
        env=environment,
        capture_output=True,
        timeout=60,
        check=False,
    )

    output = completed.stdout + completed.stderr
    assert completed.returncode == 0, output
    assert b"SCRIPT ERROR" not in output, output
