# Run offline static checks and regression tests in the dedicated WSL2 test distro.
# Examples:
#   powershell -File scripts/test-local.ps1
#   powershell -File scripts/test-local.ps1 -Tests tests-node-note.sh -KeepRunning -ReuseId impl-112
#   powershell -File scripts/test-local.ps1 -CleanReuseId impl-112

param(
    [string[]]$Tests = @(),
    [switch]$KeepRunning,
    [int]$Jobs = 2,
    [string]$ReuseId = '',
    [string]$CleanReuseId = '',
    [switch]$StaticOnly,
    [switch]$NoStatic
)

$ErrorActionPreference = 'Stop'

if ($Jobs -lt 1) {
    throw "Invalid -Jobs value: $Jobs"
}

$scriptPath = Join-Path $PSScriptRoot 'run-offline-tests.sh'
$fullPath = [IO.Path]::GetFullPath($scriptPath)
$wslScript = '/mnt/' + $fullPath.Substring(0, 1).ToLower() + $fullPath.Substring(2).Replace('\', '/')

$exitCode = 1
try {
    if ($CleanReuseId) {
        & wsl.exe -d test -u root -- bash $wslScript --clean-reuse $CleanReuseId
        $exitCode = $LASTEXITCODE
    } else {
        $normalizedTests = @()
        foreach ($item in $Tests) {
            foreach ($part in ($item -split ',')) {
                $trimmed = $part.Trim()
                if ($trimmed) {
                    $normalizedTests += $trimmed
                }
            }
        }

        $effectiveJobs = $Jobs
        if ($normalizedTests.Count -eq 1) {
            $effectiveJobs = 1
        }

        $argsList = @('--copy-to-tmp', '--jobs', "$effectiveJobs")
        if ($ReuseId) {
            $argsList += @('--reuse-id', $ReuseId)
        }
        if ($StaticOnly) {
            $argsList += '--static-only'
        }
        if ($NoStatic) {
            $argsList += '--no-static'
        }
        if ($normalizedTests.Count -gt 0) {
            $argsList += $normalizedTests
        }

        & wsl.exe -d test -u root -- bash $wslScript @argsList
        $exitCode = $LASTEXITCODE
    }
} finally {
    if (-not $KeepRunning) {
        & wsl.exe --shutdown | Out-Null
    }
}

exit $exitCode
