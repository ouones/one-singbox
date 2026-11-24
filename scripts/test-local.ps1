# Run the full regression suite in the dedicated WSL2 test distro.
# Usage: powershell -File scripts/test-local.ps1 [-KeepRunning]

param(
    [switch]$KeepRunning
)

$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'run-tests-in-wsl.sh'
$fullPath = [IO.Path]::GetFullPath($scriptPath)
$wslScript = '/mnt/' + $fullPath.Substring(0, 1).ToLower() + $fullPath.Substring(2).Replace('\', '/')

$exitCode = 1
try {
    & wsl.exe -d test -u root -- bash $wslScript
    $exitCode = $LASTEXITCODE
} finally {
    if (-not $KeepRunning) {
        & wsl.exe --shutdown | Out-Null
    }
}

exit $exitCode
