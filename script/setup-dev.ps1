# Dev environment setup for Windows contributors.
# Run once after cloning, or after recreating .venv:
#     .\script\setup-dev.ps1
#
# On Linux/macOS use script/setup-dev (bash) instead.

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isWin = if ($PSVersionTable.PSVersion.Major -lt 6) {
    $env:OS -eq 'Windows_NT'
} else {
    [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
}

if (-not $isWin) {
    Write-Host "setup-dev.ps1 is Windows-only. On macOS/Linux, run script/setup-dev instead." -ForegroundColor Yellow
    exit 0
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $repoRoot
Write-Host "Repo: $repoRoot"

# --- 1. Install git hooks to .git/hooks/ ----------------------------------
# Copy script/githooks/* (tracked) into .git/hooks/ (untracked, local-only)
# so they fire on `git worktree add` and `git checkout <branch>` regardless
# of which branch the main repo is currently on. .git/hooks/ is the path
# git always checks, and it is shared across all worktrees of this clone.
#
# We don't use core.hooksPath=script/githooks because git resolves that
# relative path against the main repo's working tree — if main is on a
# branch that doesn't contain script/githooks/, the hook is silently invisible.
$gitCommonDir = (& git rev-parse --git-common-dir).Trim()
if ($LASTEXITCODE -ne 0) { throw "git rev-parse --git-common-dir failed" }
if (Test-Path -LiteralPath 'script/githooks') {
    $hooksTargetDir = Join-Path $gitCommonDir 'hooks'
    Get-ChildItem -LiteralPath 'script/githooks' -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $hooksTargetDir $_.Name) -Force
    }
    Write-Host "[ok] Installed script/githooks/* into $hooksTargetDir"
}
# Clear any stale core.hooksPath from earlier setup-dev runs that used it.
& git config --unset core.hooksPath 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "[ok] Cleared stale core.hooksPath config."
}

# --- 2. Build the test_project plugin junction ----------------------------
# The link is not tracked in git (see #185 / .gitignore). A directory
# junction works without admin rights or Windows Developer Mode — unlike
# real symlinks — so any Windows contributor can run this without changing
# system settings.
$addonsDir = Join-Path $repoRoot 'test_project\addons'
if (-not (Test-Path -LiteralPath $addonsDir)) {
    New-Item -ItemType Directory -Path $addonsDir -Force | Out-Null
}

$linkPath = Join-Path $addonsDir 'godot_ai'
$targetPath = Join-Path $repoRoot 'plugin\addons\godot_ai'

# One shared implementation with script/verify-worktree (#935): a verified
# junction is accepted or repaired (pointer removed with rmdir, never recursed
# into); a REAL directory at the link path is moved to a timestamped .stale.*
# sibling instead of deleted, because it may hold uncommitted plugin edits.
& (Join-Path $PSScriptRoot '_plugin_junction.ps1') -LinkPath $linkPath -TargetPath $targetPath
if ($LASTEXITCODE -ne 0) { throw "could not establish test_project\addons\godot_ai junction (exit $LASTEXITCODE)" }

# --- 3. Python venv via uv ------------------------------------------------
$uv = Get-Command uv -ErrorAction SilentlyContinue
if (-not $uv) {
    Write-Host ""
    Write-Host "[ERROR] 'uv' not found on PATH." -ForegroundColor Red
    Write-Host "Install uv first:"
    Write-Host '  powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"'
    exit 1
}

if (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.venv'))) {
    & uv venv .venv
    if ($LASTEXITCODE -ne 0) { throw "uv venv .venv failed" }
}

$venvPython = Join-Path $repoRoot '.venv\Scripts\python.exe'
& uv pip install -e ".[dev]" --python $venvPython
if ($LASTEXITCODE -ne 0) { throw "uv pip install -e .[dev] failed" }

Write-Host ""
Write-Host "Done. Activate with: .venv\Scripts\Activate.ps1" -ForegroundColor Green
