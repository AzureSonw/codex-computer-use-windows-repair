#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Repair.Engine.ps1')
$suite = Join-Path (Get-FullPath (Join-Path $PSScriptRoot '..\work')) ('chrome-tests-' + [Guid]::NewGuid().ToString('N'))
$script:assertions = 0
function Assert { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw "ASSERTION FAILED: $Message" }; $script:assertions++; Write-Host "PASS: $Message" }
function Put { param([string]$Path, [string]$Text); New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null; [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }
$realContractReader = ${function:Read-ChromeAsarContract}
. (Join-Path $PSScriptRoot 'Chrome.Fixture.ps1')
$fixture = Join-Path $suite 'official fixture'
$runtime = Join-Path $fixture 'app\resources\cua_node'
$market = Join-Path $fixture 'app\resources\plugins\openai-bundled'
foreach ($file in @('manifest.json','bin\node.exe','bin\node_repl.exe','bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe','bin\node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js')) { Put (Join-Path $runtime $file) 'fixture runtime bytes' }
foreach ($name in @('browser','chrome','computer-use')) { Put (Join-Path $market "plugins\$name\.codex-plugin\plugin.json") ('{"name":"' + $name + '","version":"1.0.0"}') }
Put (Join-Path $market 'plugins\browser\scripts\browser-client.mjs') 'fixture browser'
Put (Join-Path $market 'plugins\computer-use\skills\computer-use\SKILL.md') 'fixture skill'
Add-ChromeFixture $fixture
$target = Join-Path $suite "user's isolated home"
$arguments = @{ PackageRoot=$fixture; TestRoot=$target; SkipProcessCheck=$true; InitializeChrome=$true; InitializationSeconds=0 }
function Test-RestoredNode { param([string]$Runtime); return 'v24.0.0' }
$result = Invoke-CodexRepair -Mode Auto @arguments
Assert ($result.Status -eq 'Repaired') 'Fixture initializes inside apostrophe/space path without live registry access'
$paths = Get-RepairPaths $target ''
$package = Resolve-CodexPackageRoot $fixture
$resources = Get-RepairPlan $package $paths
$plan = Get-ChromeIntegrationPlan $package $paths $resources
$initializer = ${function:Start-ChromeDesktopInitialization}
$baseline = @{}
foreach ($file in @($plan.Manifest, $plan.Marker, $plan.RegistryFile) + $plan.V2Files) { $baseline[$file] = [IO.File]::ReadAllBytes($file) }
function Reset-State { foreach ($path in $baseline.Keys) { [IO.File]::WriteAllBytes($path, $baseline[$path]) } }
function Check-Fault { param([scriptblock]$Change, [string]$Message); Reset-State; & $Change; $health = Test-ChromeNativeMessaging $plan; Assert ($health.Status -eq 'NeedsRepair' -and $health.Issues.Count -gt 0) $Message; Reset-State }

Check-Fault { Remove-Item -LiteralPath $plan.RegistryFile } 'Healthy v1.2 resource trees with missing registry cannot be Healthy'
Check-Fault { Remove-Item -LiteralPath $plan.Manifest } 'Missing native manifest detected'
Check-Fault { Put $plan.Manifest '{bad json' } 'Invalid native manifest JSON detected'
Check-Fault { $r=Read-ChromeJson $plan.RegistryFile; $r.Value='C:\missing\manifest.json'; Write-RepairJson $plan.RegistryFile $r } 'Registry pointing at nonexistent manifest detected'
Check-Fault { $r=Read-ChromeJson $plan.RegistryFile; $r.Kind='ExpandString'; Write-RepairJson $plan.RegistryFile $r } 'Unexpected registry value type detected'
Check-Fault { $m=Read-ChromeJson $plan.Manifest; $m.path='C:\missing\bridge.exe'; Write-RepairJson $plan.Manifest $m } 'Missing or arbitrary bridge rejected'
Check-Fault { $m=Read-ChromeJson $plan.Manifest; $m.name='org.other.host'; Write-RepairJson $plan.Manifest $m } 'Wrong host name rejected'
Check-Fault { $m=Read-ChromeJson $plan.Manifest; $m.type='socket'; Write-RepairJson $plan.Manifest $m } 'Wrong transport rejected'
Check-Fault { $m=Read-ChromeJson $plan.Manifest; $m.allowed_origins=@('chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/'); Write-RepairJson $plan.Manifest $m } 'Wrong extension origin rejected'
Check-Fault { $m=Read-ChromeJson $plan.Manifest; $m.path=Join-Path (Split-Path -Parent $plan.Cache) '0.9.0\extension-host.exe'; Write-RepairJson $plan.Manifest $m } 'Old plugin bridge path rejected'
Check-Fault { Remove-Item -LiteralPath $plan.Marker } 'Missing marketplace initialization metadata detected'
Check-Fault { $m=Read-ChromeJson $plan.Marker; $m.appVersion='0.9.0'; Write-RepairJson $plan.Marker $m } 'Old application materialization metadata detected'
Check-Fault { $m=Read-ChromeJson $plan.Marker; $m.bundleId='old-bundle'; Write-RepairJson $plan.Marker $m } 'Old bundled marketplace identity detected'
foreach ($file in $plan.V2Files) { Check-Fault { Remove-Item -LiteralPath $file } "Missing v2 registration detected: $(Split-Path -Leaf (Split-Path -Parent $file))" }
Check-Fault { $v=Read-ChromeJson $plan.V2Files[0]; $v.schemaVersion=99; Write-RepairJson $plan.V2Files[0] $v } 'Future v2 schema rejected'
Check-Fault { $v=Read-ChromeJson $plan.V2Files[0]; $v.entries[0].PSObject.Properties.Remove('entryId'); Write-RepairJson $plan.V2Files[0] $v } 'Incomplete v2 identity rejected'
Check-Fault { $v=Read-ChromeJson $plan.V2Files[0]; $v.entries[0].paths.nodePath='C:\old\node.exe'; Write-RepairJson $plan.V2Files[0] $v } 'Stale runtime registration detected'
Check-Fault { $v=Read-ChromeJson $plan.V2Files[0]; $v.entries[0].paths.nodeModuleDirs=@('C:\unrelated'); Write-RepairJson $plan.V2Files[0] $v } 'Unrelated module search directory rejected'
[IO.Directory]::Delete($plan.Latest)
Assert ((Test-ChromeNativeMessaging $plan).Status -eq 'NeedsRepair') 'Missing latest reference detected'
$oldCache=Join-Path (Split-Path -Parent $plan.Cache) '0.9.0'
New-Item -ItemType Directory -Path $oldCache | Out-Null
New-Item -ItemType Junction -Path $plan.Latest -Target $oldCache | Out-Null
Assert ((Test-ChromeNativeMessaging $plan).Status -eq 'NeedsRepair') 'Stale latest reference detected'
[IO.Directory]::Delete($plan.Latest)
New-Item -ItemType Junction -Path $plan.Latest -Target $plan.Cache | Out-Null

$tracked = @((Join-Path $paths.CodexHome 'config.toml'), $plan.Manifest, $plan.Marker, $plan.RegistryFile) + $plan.V2Files
foreach ($tree in $resources.Trees) { $tracked += @(Get-SafeTreeFiles $tree.Target | ForEach-Object { $_.FullName }) }
$stamps=@{}; foreach ($file in $tracked) { $stamps[$file]=[IO.File]::GetLastWriteTimeUtc($file) }
$result=Invoke-CodexRepair -Mode Manual @arguments
Assert ($result.Status -eq 'Healthy' -and $result.Backups.Count -eq 0 -and $result.Changed.Count -eq 0) 'Healthy manual invocation performs no repair or backup'
Assert (@($tracked | Where-Object { [IO.File]::GetLastWriteTimeUtc($_) -ne $stamps[$_] }).Count -eq 0) 'Healthy run preserves registry surrogate, files, config and timestamps'

$r=Read-ChromeJson $plan.RegistryFile; $r.Value='C:\previous\manifest.json'; Write-RepairJson $plan.RegistryFile $r
$result=Invoke-CodexRepair -Mode Auto @arguments
Assert ($result.Status -eq 'Repaired' -and $result.Changed.Count -eq 1 -and $result.Changed[0] -eq 'Chrome desktop integration') 'Registry-only damage repairs only Chrome integration'
$snapshot=Read-ChromeJson (Join-Path $result.Backups[0] 'snapshot.json')
Assert ($snapshot.Registry.Value -eq 'C:\previous\manifest.json') 'Previous registry value backed up before initialization'
$treeFiles=@(); foreach ($tree in $resources.Trees) { $treeFiles+=@(Get-SafeTreeFiles $tree.Target | Where-Object { $_.FullName -ne $plan.Marker } | ForEach-Object { $_.FullName }) }
Assert (@($treeFiles | Where-Object { [IO.File]::GetLastWriteTimeUtc($_) -ne $stamps[$_] }).Count -eq 0) 'Registration repair does not recopy healthy runtime or marketplace'

# Simulate the official initializer publishing partial state before throwing.
Reset-State
$r=Read-ChromeJson $plan.RegistryFile; $r.Value='C:\before-failure.json'; Write-RepairJson $plan.RegistryFile $r
$beforeManifest=(Get-FileHash -LiteralPath $plan.Manifest).Hash
function Start-ChromeDesktopInitialization { param($Plan); Put $Plan.Manifest 'partial'; Write-RepairJson $Plan.RegistryFile @{KeyExists=$true;ValueExists=$true;Value='broken';Kind='String'}; [IO.Directory]::Delete($Plan.Latest); New-Item -ItemType Junction -Path $Plan.Latest -Target $oldCache | Out-Null; throw 'Injected initializer failure' }
$result=Invoke-CodexRepair -Mode Manual @arguments
Assert ($result.Status -eq 'Failed' -and (Get-FileHash -LiteralPath $plan.Manifest).Hash -eq $beforeManifest -and (Get-ChromeRegistryState $plan).Value -eq 'C:\before-failure.json' -and (Test-ChromeLatest $plan)) 'Failed initialization restores previous manifest, registry and latest target'
${function:Start-ChromeDesktopInitialization}=$initializer
Reset-State
$script:RepairGuard={}; $script:RepairBackups=[Collections.Generic.List[string]]::new()
$backup=Backup-ChromeIntegration $plan 'rollback-test'
Put (Join-Path $backup '0.bin') 'tampered backup'
$threw=$false; try { Restore-ChromeIntegration $plan $backup } catch { $threw=$true }
Assert ($threw -and (Get-FileHash -LiteralPath $plan.Manifest).Hash -eq $beforeManifest) 'Tampered backup rejected before any restoration writes'

[IO.Directory]::Delete($plan.Latest)
New-Item -ItemType Junction -Path $plan.Latest -Target $suite | Out-Null
$threw=$false; try { Assert-ChromeWriteTargets $plan } catch { $threw=$true }
Assert $threw 'Latest junction escaping the version cache rejected before writes'
[IO.Directory]::Delete($plan.Latest)
New-Item -ItemType Junction -Path $plan.Latest -Target $plan.Cache | Out-Null
$v2=$plan.V2Files[0]; Remove-Item -LiteralPath $v2
New-Item -ItemType HardLink -Path $v2 -Target $plan.V2Files[1] | Out-Null
# Hard links are regular files; publication replaces the link, preserving its sibling.
$otherHash=(Get-FileHash -LiteralPath $plan.V2Files[1]).Hash
Write-RepairJson $v2 @{schemaVersion=99}
Assert ((Get-FileHash -LiteralPath $plan.V2Files[1]).Hash -eq $otherHash) 'Atomic metadata publication preserves hard-linked sibling'
Reset-State

# Account-selected marketplace subsets still have healthy payloads when their
# initialization marker alone is missing. Never restore all official plugins.
$marketManifest = Join-Path $plan.Marketplace '.agents\plugins\marketplace.json'
$manifestBytes = [IO.File]::ReadAllBytes($marketManifest)
$selected = Read-ChromeJson $marketManifest
$selected.plugins = @($selected.plugins | Where-Object { $_.name -ne 'browser' })
Write-RepairJson $marketManifest $selected
Remove-Item -LiteralPath $plan.Marker
Assert (Test-ChromeMarketplaceResources $plan) 'Missing metadata preserves a healthy account-selected marketplace subset'
$result = Invoke-CodexRepair -Mode Check @arguments
Assert ($result.Status -eq 'NeedsRepair' -and 'OpenAI bundled marketplace' -notin $result.Changed) 'Metadata-only damage never schedules a full marketplace restore'
[IO.File]::WriteAllBytes($marketManifest, $manifestBytes)
Reset-State

$goodBackup = Backup-ChromeIntegration $plan 'explicit-rollback'
Put $plan.Manifest 'partial metadata'
$result = Invoke-CodexRepair -Mode Manual -PackageRoot $fixture -TestRoot $target -SkipProcessCheck -RestoreChromeBackup $goodBackup
Assert ($result.Status -eq 'Restored' -and (Get-FileHash -LiteralPath $plan.Manifest).Hash -eq $beforeManifest) 'Public rollback entry restores validated integration snapshot'
Reset-State
$r=Read-ChromeJson $plan.RegistryFile; $r.Value='C:\before-timeout.json'; Write-RepairJson $plan.RegistryFile $r
function Start-ChromeDesktopInitialization { param($Plan); return }
$result=Invoke-CodexRepair -Mode Manual @arguments
Assert ($result.Status -eq 'Deferred' -and $result.Backups.Count -eq 1 -and (Get-ChromeRegistryState $plan).Value -eq 'C:\before-timeout.json') 'Bounded initialization timeout retains previous state and backup without claiming success'
${function:Start-ChromeDesktopInitialization}=$initializer
Reset-State

$asar=Join-Path $fixture 'app\resources\app.asar'; Put $asar 'future layout'
$result=Invoke-CodexRepair -Mode Manual @arguments
Assert ($result.Status -eq 'Failed' -and $result.Changed.Count -eq 0 -and $result.Backups.Count -eq 0) 'Unsupported future layout fails before replacing targets'
${function:Read-ChromeAsarContract}=$realContractReader
$threw=$false; try { Read-ChromeAsarContract $asar } catch { $threw=$true }
Assert $threw 'Real ASAR reader rejects unrecognized header'
Write-Host "Passed $script:assertions Chrome assertions. Isolated artifacts: $suite"
