param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('codex', 'claude')]
    [string]$Client,
    [switch]$Remote,
    [string]$Task = ''
)

$ErrorActionPreference = 'Stop'
if ($Remote -and $Client -ne 'claude') {
    throw 'For Codex, enable and pair its native remote-control daemon separately; see docs/pstack.md.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$entryPoint = Join-Path $repoRoot 'docs/poteto-session.md'
if (-not (Test-Path -LiteralPath $entryPoint -PathType Leaf)) {
    throw 'The checkout is missing docs/poteto-session.md.'
}
if (-not (Get-Command $Client -ErrorAction SilentlyContinue)) {
    throw "Install and sign in to $Client before using this launcher."
}

$prompt = 'This is an explicitly requested poteto session. Read docs/poteto-session.md and follow it for every task in this session until I turn the mode off.'
if ($Task) {
    $prompt += "`n`nTask:`n$Task"
} else {
    $prompt += ' Confirm the mode and wait for my task.'
}
$clientArguments = @()
if ($Remote) {
    $clientArguments += '--remote-control'
    $clientArguments += 'Godot AI poteto'
}
$clientArguments += $prompt

Push-Location -LiteralPath $repoRoot
try {
    & $Client @clientArguments
    $clientExitCode = $LASTEXITCODE
} finally {
    Pop-Location
}
if ($clientExitCode) {
    exit $clientExitCode
}
