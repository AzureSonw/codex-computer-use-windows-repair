#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PackageRoot = '',
    [string]$TestRoot = '',
    [switch]$SkipProcessCheck,
    [switch]$Auto,
    [switch]$FullCheck,
    [switch]$InitializeChrome,
    [string]$RestoreChromeBackup = '',
    [ValidateRange(0, 300)][int]$InitializationSeconds = 120,
    [ValidateRange(0, 300)][int]$WaitSeconds = 0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Repair.Engine.ps1')
$mode = if ($Auto) { 'Auto' } else { 'Manual' }
$result = Invoke-CodexRepair -Mode $mode -PackageRoot $PackageRoot -TestRoot $TestRoot -SkipProcessCheck:$SkipProcessCheck -FullCheck:$FullCheck -WaitSeconds $WaitSeconds -InitializeChrome:$InitializeChrome -InitializationSeconds $InitializationSeconds -RestoreChromeBackup $RestoreChromeBackup
exit $result.ExitCode
