#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $repository 'Repair.Engine.ps1')
$package = Resolve-CodexPackageRoot ''
$testRoot = Join-Path $repository ("work\installed package ' " + [Guid]::NewGuid().ToString('N'))
$paths = Get-RepairPaths $testRoot ''
$checker = Join-Path $repository 'check-codex-computer-use.ps1'
Write-Host "Testing official package $($package.Identity) with PowerShell $($PSVersionTable.PSVersion)"
Write-Host "All restored resources go to: $testRoot"
& $checker -TestRoot $testRoot -SkipProcessCheck -CheckOnly
if ($LASTEXITCODE -ne 2) { throw "Expected NeedsRepair from the fresh check; got $LASTEXITCODE" }
if (Test-Path -LiteralPath (Join-Path $paths.CodexHome 'config.toml')) { throw 'Check-only unexpectedly wrote configuration.' }

& $checker -TestRoot $testRoot -SkipProcessCheck
if ($LASTEXITCODE -ne 0) { throw "Isolated repair failed: $LASTEXITCODE" }
$reportPath = Join-Path $paths.StateRoot 'last-result.json'
$result = [IO.File]::ReadAllText($reportPath) | ConvertFrom-Json
if ($result.Status -ne 'Repaired' -or $result.Package -ne $package.Identity) { throw 'Expected a repaired result with verified package identity.' }
$config = Join-Path $paths.CodexHome 'config.toml'
$configHash = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
$configTime = [IO.File]::GetLastWriteTimeUtc($config)
$backupsBefore = @(Get-ChildItem -LiteralPath $testRoot -Recurse -Force | Where-Object { $_.Name -like '*.before-computer-use-repair-*' }).Count
$clock = [Diagnostics.Stopwatch]::StartNew()
& $checker -TestRoot $testRoot -SkipProcessCheck
if ($LASTEXITCODE -ne 0) { throw "Repeated check failed: $LASTEXITCODE" }
$clock.Stop()
$result = [IO.File]::ReadAllText($reportPath) | ConvertFrom-Json
$backupsAfter = @(Get-ChildItem -LiteralPath $testRoot -Recurse -Force | Where-Object { $_.Name -like '*.before-computer-use-repair-*' }).Count
if ($result.Status -ne 'Healthy' -or $result.Changed.Count -ne 0 -or $backupsBefore -ne $backupsAfter -or
    (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash -ne $configHash -or [IO.File]::GetLastWriteTimeUtc($config) -ne $configTime) {
    throw 'Healthy run unexpectedly changed repaired resources/configuration/backups.'
}
$script:VerifiedSourceRoot = $package.Root
$plan = Get-RepairPlan $package $paths
$runtimeStats = Get-TreeStats $plan.Runtime
$marketStats = Get-TreeStats $plan.Marketplace
$summary = [ordered]@{
    Package = $package.Identity; PowerShell = [string]$PSVersionTable.PSVersion
    RuntimeHash = $plan.RuntimeHash; RuntimeFiles = $runtimeStats.Count; RuntimeBytes = $runtimeStats.Bytes
    MarketplaceFiles = $marketStats.Count; MarketplaceBytes = $marketStats.Bytes
    Node = (Test-RestoredNode $plan.Runtime); HealthyCheckSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 2)
    ConfigAndBackupsUnchanged = $true; TestRoot = $testRoot
}
Write-RepairJson (Join-Path $testRoot 'verification.json') $summary
$summary | ConvertTo-Json
Write-Host 'PASS: trusted installed package, check-only, conditional repair, and healthy repeated invocation.'
