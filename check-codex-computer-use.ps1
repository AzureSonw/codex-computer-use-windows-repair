#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$FullCheck,
    [string]$PackageRoot = '',
    [string]$TestRoot = '',
    [switch]$SkipProcessCheck,
    [ValidateRange(0, 300)][int]$WaitSeconds = 0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Repair.Engine.ps1')
$result = Invoke-CodexRepair -Mode Check -PackageRoot $PackageRoot -TestRoot $TestRoot -SkipProcessCheck:$SkipProcessCheck -FullCheck:$FullCheck
if ($result.ExitCode -ne 2 -or $CheckOnly) { exit $result.ExitCode }

Write-Host 'Repair is needed. Starting the repair script...'
$repairArguments = @{ Auto = $true; PackageRoot = $PackageRoot; TestRoot = $TestRoot; SkipProcessCheck = $SkipProcessCheck; WaitSeconds = $WaitSeconds }
# The repair script acquires the same lock and rechecks current resources/processes.
# It is called only on damage; it never invokes this checker or the CMD launcher.
& (Join-Path $PSScriptRoot 'repair-codex-computer-use.ps1') @repairArguments
exit $LASTEXITCODE
