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
if ($LASTEXITCODE -ne 10) { throw "Expected Deferred after isolated prerequisite repair: $LASTEXITCODE" }
$reportPath = Join-Path $paths.StateRoot 'last-result.json'
$result = [IO.File]::ReadAllText($reportPath) | ConvertFrom-Json
if ($result.Status -ne 'Deferred' -or $result.Package -ne $package.Identity -or $result.ChromeIntegration.Status -ne 'NeedsRepair') { throw 'Expected verified prerequisites with desktop initialization explicitly deferred.' }
$config = Join-Path $paths.CodexHome 'config.toml'
$configHash = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
$configTime = [IO.File]::GetLastWriteTimeUtc($config)
$backupsBefore = @(Get-ChildItem -LiteralPath $testRoot -Recurse -Force | Where-Object { $_.Name -like '*.before-computer-use-repair-*' }).Count
$clock = [Diagnostics.Stopwatch]::StartNew()
& $checker -TestRoot $testRoot -SkipProcessCheck
if ($LASTEXITCODE -ne 10) { throw "Expected isolated desktop initialization to remain Deferred: $LASTEXITCODE" }
$clock.Stop()
$result = [IO.File]::ReadAllText($reportPath) | ConvertFrom-Json
$backupsAfter = @(Get-ChildItem -LiteralPath $testRoot -Recurse -Force | Where-Object { $_.Name -like '*.before-computer-use-repair-*' }).Count
if ($result.Status -ne 'Deferred' -or $result.Changed.Count -ne 1 -or $result.Changed[0] -ne 'Chrome desktop integration' -or $backupsBefore -ne $backupsAfter -or
    (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash -ne $configHash -or [IO.File]::GetLastWriteTimeUtc($config) -ne $configTime) {
    throw 'Repeated prerequisite check unexpectedly changed resources/configuration/backups.'
}
$script:VerifiedSourceRoot = $package.Root
$plan = Get-RepairPlan $package $paths
$chrome = Get-ChromeIntegrationPlan $package $paths $plan
foreach ($file in Get-ChromeViewFiles $chrome $plan) {
    if ((Get-FileHash -LiteralPath $file.Source).Hash -ne (Get-FileHash -LiteralPath (Join-Path $chrome.View $file.Relative)).Hash) { throw 'Decrypted desktop initialization view differs from trusted package.' }
}
if (Test-Path -LiteralPath $chrome.RegistryFile) { throw 'Installed-package test unexpectedly initialized registry state.' }
$runtimeStats = Get-TreeStats $plan.Runtime
$marketStats = Get-TreeStats $plan.Marketplace
$summary = [ordered]@{
    Package = $package.Identity; PowerShell = [string]$PSVersionTable.PSVersion
    RuntimeHash = $plan.RuntimeHash; RuntimeFiles = $runtimeStats.Count; RuntimeBytes = $runtimeStats.Bytes
    MarketplaceFiles = $marketStats.Count; MarketplaceBytes = $marketStats.Bytes
    Node = (Test-RestoredNode $plan.Runtime); RepeatedCheckSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 2)
    NativeHost = $chrome.HostName; ExtensionIds = $chrome.ExtensionIds; Bridge = $chrome.BridgeRelative
    DesktopAppVersion = $chrome.Contract.AppVersion; ChromePluginVersion = $chrome.Version; ResourceSchema = $chrome.Contract.Schema
    DecryptedViewVerified = $true; DesktopInitialization = 'Not run; isolated prerequisites only'
    ConfigAndBackupsUnchanged = $true; TestRoot = $testRoot
}
Write-RepairJson (Join-Path $testRoot 'verification.json') $summary
$summary | ConvertTo-Json
Write-Host 'PASS: trusted installed package, check-only, isolated prerequisites, decrypted view and repeated invocation. Live Chrome connection NOT tested.'
