# Thin PowerShell wrapper around the cross-platform launcher
# `script/serve_worktree.py`, so Windows has a discoverable serve command. The
# real logic (venv resolution, port free, --port/--ws-port, --reload) lives in
# the Python launcher so POSIX and Windows share one implementation. See
# #509 / #514.
#
# Usage: .\script\serve-this-worktree.ps1 --port 18130 --ws-port 19630
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
if (-not $py) {
    throw 'python not found on PATH (install Python, or run script\setup-dev.ps1)'
}

& $py.Source (Join-Path $dir 'serve_worktree.py') @args
exit $LASTEXITCODE
