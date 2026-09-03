# Ensure test_project\addons\godot_ai is a directory junction to this
# checkout's plugin\addons\godot_ai - the one Windows implementation shared by
# script\setup-dev.ps1 (invoked as a script) and script\verify-worktree
# (invoked from Git Bash).
#
# Policy (#935):
#   * Only a verified reparse point (junction/symlink) is ever removed, and only
#     with `cmd /c rmdir`, which drops the pointer without recursing into the
#     target.
#   * A real directory (or file) at the link path is NEVER deleted. It is moved
#     to `<link>.stale.<timestamp>` with a warning - it may hold uncommitted
#     plugin edits from a manual copy or a botched checkout.
#   * A junction is accepted only when its target resolves to the expected
#     plugin directory; a stale or dangling junction is repaired.
#
# Exit codes: 0 = link OK (already valid, created, or repaired); 2 = could not
# create the junction; 3 = -CheckOnly and the link is missing/wrong.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $LinkPath,
    [Parameter(Mandatory = $true)] [string] $TargetPath,
    [switch] $CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-ToComparablePath([string] $Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path
    if ($p.StartsWith('\\?\')) { $p = $p.Substring(4) }
    $p = $p.Replace('/', '\')
    try { $p = [System.IO.Path]::GetFullPath($p) } catch { }
    return $p.TrimEnd('\').ToLowerInvariant()
}

function Get-ReparseInfo([string] $Path) {
    # Returns @{ IsReparse = bool; Target = string } for an existing path.
    $info = @{ IsReparse = $false; Target = '' }
    $item = Get-Item -LiteralPath $Path -Force
    $flag = [int][System.IO.FileAttributes]::ReparsePoint
    if (([int]$item.Attributes -band $flag) -ne 0) {
        $info.IsReparse = $true
        $t = $null
        try { $t = $item.Target } catch { $t = $null }
        if ($t -is [System.Array]) {
            if ($t.Length -gt 0) { $t = $t[0] } else { $t = '' }
        }
        if ($null -eq $t) { $t = '' }
        $info.Target = [string] $t
    }
    return $info
}

function Remove-ReparsePointOnly([string] $Path) {
    # rmdir on a junction removes the pointer only (no recursion into target).
    & cmd /c rmdir $Path.Replace('/', '\')
    if (Test-Path -LiteralPath $Path) {
        throw "could not remove reparse point at $Path"
    }
}

function New-PluginJunction([string] $Link, [string] $Target) {
    $parent = Split-Path -Parent $Link
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    & cmd /c mklink /J $Link.Replace('/', '\') $Target.Replace('/', '\') | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    $made = Get-ReparseInfo $Link
    if (-not $made.IsReparse) { return $false }
    return ((Convert-ToComparablePath $made.Target) -eq (Convert-ToComparablePath $Target))
}

function Move-AsideStale([string] $Path) {
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $stale = "$Path.stale.$stamp"
    $n = 0
    while (Test-Path -LiteralPath $stale) { $n++; $stale = "$Path.stale.$stamp.$n" }
    Move-Item -LiteralPath $Path -Destination $stale
    return $stale
}

$expected = Convert-ToComparablePath $TargetPath

if (-not (Test-Path -LiteralPath $TargetPath -PathType Container)) {
    Write-Host "[FAIL] plugin target does not exist: $TargetPath" -ForegroundColor Red
    exit 2
}

$linkExists = Test-Path -LiteralPath $LinkPath

if (-not $linkExists) {
    if ($CheckOnly) {
        Write-Host "[warn] $LinkPath is missing" -ForegroundColor Yellow
        exit 3
    }
} else {
    $info = Get-ReparseInfo $LinkPath
    if ($info.IsReparse) {
        if ((Convert-ToComparablePath $info.Target) -eq $expected) {
            Write-Host "[ok] $LinkPath -> $TargetPath (junction)"
            exit 0
        }
        if ($CheckOnly) {
            Write-Host "[warn] $LinkPath is a junction to '$($info.Target)', expected '$TargetPath'" -ForegroundColor Yellow
            exit 3
        }
        Write-Host "[warn] $LinkPath pointed at '$($info.Target)' - repairing to $TargetPath" -ForegroundColor Yellow
        Remove-ReparsePointOnly $LinkPath
    } else {
        if ($CheckOnly) {
            Write-Host "[warn] $LinkPath is a real directory/file, not a junction" -ForegroundColor Yellow
            exit 3
        }
        $stale = Move-AsideStale $LinkPath
        Write-Host "[warn] $LinkPath was a real directory, not a junction - moved to $stale (delete it once you have confirmed nothing in it matters)." -ForegroundColor Yellow
    }
}

if (New-PluginJunction $LinkPath $TargetPath) {
    Write-Host "[ok] Created $LinkPath as a directory junction -> $TargetPath"
    exit 0
}

Write-Host "[FAIL] Could not create junction $LinkPath -> $TargetPath" -ForegroundColor Red
exit 2
