# Dev environment setup for Windows contributors.
# Run once after cloning, or after recreating .venv:
#     .\script\setup-dev.ps1
#
# On Linux/macOS use script/setup-dev (bash) instead.

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
    Write-Host "setup-dev.ps1 is Windows-only. On macOS/Linux, run script/setup-dev instead." -ForegroundColor Yellow
    exit 0
}
if ($PSVersionTable.PSVersion.Major -lt 6 -and $env:OS -ne 'Windows_NT') {
    Write-Host "setup-dev.ps1 is Windows-only. On macOS/Linux, run script/setup-dev instead." -ForegroundColor Yellow
    exit 0
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $repoRoot
Write-Host "Repo: $repoRoot"

# --- 1. Windows Developer Mode check --------------------------------------
$devModeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$devModeOn = $false
try {
    $val = Get-ItemPropertyValue -Path $devModeKey -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction Stop
    $devModeOn = ($val -eq 1)
} catch {
    $devModeOn = $false
}

if (-not $devModeOn) {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host " Windows Developer Mode is OFF" -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Without Developer Mode, git cannot create symlinks and the"
    Write-Host "test_project/addons/godot_ai symlink will check out as a plain"
    Write-Host "text file. Godot will then fail to load the plugin."
    Write-Host ""
    Write-Host "To enable Developer Mode:"
    Write-Host "  1. Open Settings -> Privacy & security -> For developers"
    Write-Host "     (or run: start ms-settings:developers)"
    Write-Host "  2. Toggle 'Developer Mode' on"
    Write-Host "  3. Re-run this script"
    Write-Host ""
    Write-Host "Alternatively, run this script from an Administrator PowerShell."
    Write-Host ""
    $resp = Read-Host "Continue anyway? Symlink hydration will likely fail. [y/N]"
    if ($resp -notmatch '^[Yy]') {
        Write-Host "Aborted. Enable Developer Mode and try again." -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "[ok] Windows Developer Mode is enabled."
}

# --- 2. core.symlinks for this repo ---------------------------------------
& git config core.symlinks true
if ($LASTEXITCODE -ne 0) { throw "git config core.symlinks true failed" }
Write-Host "[ok] git config core.symlinks=true (local)."

# --- 3. Re-materialize the plugin symlink ---------------------------------
$symlinkPath = Join-Path $repoRoot 'test_project\addons\godot_ai'
if (Test-Path -LiteralPath $symlinkPath) {
    Remove-Item -LiteralPath $symlinkPath -Force -Recurse -ErrorAction SilentlyContinue
}
& git checkout HEAD -- 'test_project/addons/godot_ai'
if ($LASTEXITCODE -ne 0) { throw "git checkout of test_project/addons/godot_ai failed" }

$item = Get-Item -LiteralPath $symlinkPath -Force
$isSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
if ($isSymlink) {
    Write-Host "[ok] test_project/addons/godot_ai is a symlink."
} else {
    Write-Host ""
    Write-Host "[WARN] test_project/addons/godot_ai did NOT hydrate as a symlink." -ForegroundColor Yellow
    Write-Host "       The plugin will not load in Godot until this is fixed."
    Write-Host "       Most common cause: Windows Developer Mode is off."
    Write-Host ""
}

# --- 4. Python venv via uv ------------------------------------------------
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
