#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Repair.Engine.ps1')
$suiteRoot = Join-Path (Get-FullPath (Join-Path $PSScriptRoot '..\work')) ('tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $suiteRoot -Force | Out-Null
$script:assertions = 0
function Assert { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw "ASSERTION FAILED: $Message" }; $script:assertions++; Write-Host "PASS: $Message" -ForegroundColor Green }
function Put { param([string]$Path, [string]$Text); New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null; [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }
function Read-Text { param([string]$Path); return [IO.File]::ReadAllText($Path) }
function Count-Backups { return @(Get-ChildItem -LiteralPath $target -Recurse -Force | Where-Object { $_.Name -like '*.before-computer-use-repair-*' }).Count }

$fixture = Join-Path $suiteRoot 'official fixture'
$runtime = Join-Path $fixture 'app\resources\cua_node'
$market = Join-Path $fixture 'app\resources\plugins\openai-bundled'
foreach ($path in @('manifest.json', 'bin\node.exe', 'bin\node_repl.exe', 'bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe', 'bin\node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js', 'bin\non-key.js')) { Put (Join-Path $runtime $path) 'original bytes' }
Put (Join-Path $market '.agents\plugins\marketplace.json') '{"name":"openai-bundled"}'
foreach ($name in @('browser', 'chrome', 'computer-use')) {
    Put (Join-Path $market "plugins\$name\.codex-plugin\plugin.json") ('{"name":"' + $name + '","version":"1.0.0"}')
    Put (Join-Path $market "plugins\$name\asset.txt") 'plugin content'
}
Put (Join-Path $market 'plugins\browser\scripts\browser-client.mjs') 'browser'
Put (Join-Path $market 'plugins\computer-use\skills\computer-use\SKILL.md') 'skill'
$target = Join-Path $suiteRoot "user's isolated home"
$arguments = @{ PackageRoot = $fixture; TestRoot = $target; SkipProcessCheck = $true }
$paths = Get-RepairPaths $target ''
$configPath = Join-Path $paths.CodexHome 'config.toml'
$statePath = Join-Path $paths.StateRoot 'state.json'
$script:NodeFails = $false
$script:NodeCalls = 0
function Test-RestoredNode { param([string]$Runtime); $script:NodeCalls++; if ($script:NodeFails) { throw 'Injected Node self-test failure' }; return 'v24.19.0' }

$result = Invoke-CodexRepair -Mode Check @arguments
Assert ($result.Status -eq 'NeedsRepair') 'Fresh check identifies missing components'
Assert (-not (Test-Path -LiteralPath $configPath) -and -not (Test-Path -LiteralPath (Join-Path $paths.LocalRoot 'runtimes'))) 'Check-only does not write runtime or configuration'
$result = Invoke-CodexRepair -Mode Auto @arguments
Assert ($result.Status -eq 'Repaired') 'Fresh on-demand repair succeeds in an apostrophe path'
Assert ($result.Changed.Count -eq 6 -and $script:NodeCalls -eq 1) 'Restores all five trees and configuration, then tests Node'
$before = Read-Text $configPath
$backupCount = Count-Backups
$result = Invoke-CodexRepair -Mode Auto @arguments
Assert ($result.Status -eq 'Healthy' -and $script:NodeCalls -eq 1) 'Healthy run skips repair and executable self-test'
Assert ((Read-Text $configPath) -eq $before -and (Count-Backups) -eq $backupCount) 'Healthy run leaves configuration and backups unchanged'
$plan = Get-RepairPlan (Resolve-CodexPackageRoot $fixture) $paths
$nonKeyTarget = Join-Path $plan.Runtime 'bin\non-key.js'
Put $nonKeyTarget 'tampered bytes'
[IO.File]::SetLastWriteTimeUtc($nonKeyTarget, [DateTime]::UtcNow.AddSeconds(2))
$result = Invoke-CodexRepair -Mode Check @arguments
Assert ($result.Status -eq 'NeedsRepair') 'Detects same-length corruption outside key files'
$result = Invoke-CodexRepair -Mode Auto @arguments
Assert ($result.Status -eq 'Repaired' -and $result.Changed.Count -eq 1) 'Repairs only the damaged runtime'
Assert ($result.Backups.Count -eq 1 -and (Read-Text (Join-Path $result.Backups[0] 'bin\non-key.js')) -eq 'tampered bytes') 'Preserves the old runtime in a backup'
$result = Invoke-CodexRepair -Mode Auto @arguments # Populate hash metadata for the published tree.
$savedTime = [IO.File]::GetLastWriteTimeUtc($nonKeyTarget)
Put $nonKeyTarget 'tampered bytes'
[IO.File]::SetLastWriteTimeUtc($nonKeyTarget, $savedTime)
$result = Invoke-CodexRepair -Mode Check -FullCheck @arguments
Assert ($result.Status -eq 'NeedsRepair') 'Explicit full check detects corruption with unchanged length and timestamp'
$result = Invoke-CodexRepair -Mode Auto @arguments
Assert ($result.Status -eq 'Repaired') 'A full-check finding is passed through to repair'

$result = Invoke-CodexRepair -Mode Auto @arguments
$savedTime = [IO.File]::GetLastWriteTimeUtc($nonKeyTarget)
Put $nonKeyTarget 'tampered bytes'
[IO.File]::SetLastWriteTimeUtc($nonKeyTarget, $savedTime)
$state = Read-RepairState $statePath; $state.LastFullCheck = [DateTime]::UtcNow.AddHours(-25).ToString('o'); Write-RepairJson $statePath $state
$result = Invoke-CodexRepair -Mode Check @arguments
Assert ($result.Status -eq 'NeedsRepair') 'An invocation after 24 hours performs a full hash audit without a background timer'
$result = Invoke-CodexRepair -Mode Auto @arguments
Put $statePath '{broken state'
$result = Invoke-CodexRepair -Mode Check @arguments
Assert ($result.Status -eq 'Healthy') 'A corrupt state file triggers a fresh scan instead of assuming healthy'
$plan = Get-RepairPlan (Resolve-CodexPackageRoot $fixture) $paths
$missingFile = Join-Path $plan.Trees[2].Target 'asset.txt'
Assert-PathWithin $missingFile $target
[IO.File]::Move($missingFile, (Join-Path $suiteRoot 'removed-cache-file.txt'))
$result = Invoke-CodexRepair -Mode Auto @arguments
Assert ($result.Status -eq 'Repaired' -and $result.Changed.Count -eq 1) 'A missing cache file restores only that plugin'

$oldHash = $result.RuntimeHash
Put (Join-Path $market 'plugins\chrome\asset.txt') 'new plugin content, same version'
$result = Invoke-CodexRepair -Mode Auto @arguments
Assert ($result.Status -eq 'Repaired' -and $result.RuntimeHash -eq $oldHash -and $result.Changed.Count -eq 2) 'Plugin resource updates repair marketplace/cache without replacing unchanged runtime'
Put (Join-Path $runtime 'manifest.json') 'new runtime manifest'
$result = Invoke-CodexRepair -Mode Auto @arguments
Assert ($result.Status -eq 'Repaired' -and $result.RuntimeHash -ne $oldHash) 'A runtime update dynamically selects a new hash directory'
Assert (Test-Path -LiteralPath (Join-Path $paths.LocalRoot "runtimes\cua_node\$oldHash")) 'Retains the previous runtime version'
$config = (Read-Text $configPath).Replace('enabled = true', 'enabled = false')
Put $configPath $config
$result = Invoke-CodexRepair -Mode Auto @arguments
Assert ($result.Status -eq 'Healthy' -and (Read-Text $configPath) -eq $config) 'Honors explicitly disabled plugins'
Put $configPath ($config.Replace('source_type = "local"', 'source_type = "git"') + "`r`n[unrelated] # keep this section`r`nvalue = 42`r`n")
$result = Invoke-CodexRepair -Mode Auto @arguments
Assert ($result.Status -eq 'Repaired' -and (Read-Text $configPath).Contains('enabled = false') -and (Read-Text $configPath).Contains('value = 42')) 'Config repair preserves plugin choices and unrelated commented sections'

$busyArguments = @{ PackageRoot = $fixture; TestRoot = $target }
function Get-RepairProcesses { param([string]$RuntimeParent); return [pscustomobject]@{ Id = 999; ProcessName = 'ChatGPT' } }
$before = Read-Text $configPath
$result = Invoke-CodexRepair -Mode Auto @busyArguments
Assert ($result.Status -eq 'Deferred' -and (Read-Text $configPath) -eq $before) 'Running app defers repair without changing configuration'
function Get-RepairProcesses { param([string]$RuntimeParent); return @() }
$result = Invoke-CodexRepair -Mode Auto @busyArguments
Assert ($result.Status -eq 'Healthy') 'A later invocation succeeds after the app closes'
$script:busyCalls = 0
function Get-RepairProcesses { param([string]$RuntimeParent); $script:busyCalls++; if ($script:busyCalls -eq 1) { return [pscustomobject]@{ Id = 999 } }; return @() }
$result = Invoke-CodexRepair -Mode Auto -WaitSeconds 2 @busyArguments
Assert ($result.Status -eq 'Healthy' -and $script:busyCalls -ge 2) 'Optional wait observes app exit and remains bounded'
$lock = [IO.File]::Open((Join-Path $paths.StateRoot 'check.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try { $result = Invoke-CodexRepair -Mode Auto @arguments; Assert ($result.Status -eq 'Deferred') 'Concurrent invocation exits when another check holds the lock' } finally { $lock.Dispose() }

$script:NodeFails = $true
Put $configPath ((Read-Text $configPath).Replace('source_type = "local"', 'source_type = "git"'))
$result = Invoke-CodexRepair -Mode Auto @arguments
Assert ($result.Status -eq 'Failed') 'A failed Node self-test is reported as a failure'
$result = Invoke-CodexRepair -Mode Auto @arguments
Assert ($result.Status -eq 'Cooldown') 'A repeated failed repair is rate-limited'
for ($attempt = 2; $attempt -le 3; $attempt++) {
    $state = Read-RepairState $statePath; $state.NextRetry = [DateTime]::UtcNow.AddSeconds(-1).ToString('o'); Write-RepairJson $statePath $state
    $result = Invoke-CodexRepair -Mode Auto @arguments
    Assert ($result.Status -eq 'Failed') "Bounded retry $attempt reports failure"
}
$result = Invoke-CodexRepair -Mode Auto @arguments
Assert ($result.Status -eq 'Paused') 'Three failures pause repair instead of making endless backups'
$script:NodeFails = $false
$result = Invoke-CodexRepair -Mode Manual @arguments
Assert ($result.Status -eq 'Repaired') 'Manual repair remains available and clears the failed-attempt pause'
$state = Read-RepairState $statePath; $state.Interrupted = $true; Write-RepairJson $statePath $state
$result = Invoke-CodexRepair -Mode Auto @arguments
Assert ($result.Status -eq 'Paused') 'An interrupted transaction requires review before retry'
$result = Invoke-CodexRepair -Mode Check @arguments
Assert ($result.Status -eq 'NeedsRepair') 'Check does not hide an interrupted transaction as healthy'
$result = Invoke-CodexRepair -Mode Manual @arguments
Assert ($result.Status -eq 'Repaired') 'Manual repair recovers the interrupted-run marker'

# Simulate an app starting precisely between backup and publication.
$plan = Get-RepairPlan (Resolve-CodexPackageRoot $fixture) $paths
$tree = $plan.Trees[4]
Put (Join-Path $tree.Target 'asset.txt') 'old user cache'
$script:RepairBackups = [Collections.Generic.List[string]]::new()
$script:HashCache = @{}; $script:NextHashCache = @{}; $script:FullHashCheck = $true
$script:guardCalls = 0
$script:RepairGuard = { $script:guardCalls++; if ($script:guardCalls -eq 2) { throw 'DEFERRED: injected app startup' } }
$threw = $false
try { Copy-TreeByDecryptedStream -Source $tree.Source -Final $tree.Target -AllowedParent $tree.Parent -Label 'Race test' -KeyRelativePaths $tree.Keys -Timestamp 'race' } catch { $threw = $true }
Assert ($threw -and (Read-Text (Join-Path $tree.Target 'asset.txt')) -eq 'old user cache') 'A publication race restores the previous directory'
Assert (@(Get-ChildItem -LiteralPath $tree.Parent -Directory -Force -Filter '.staging-*').Count -gt 0) 'Failed staging is retained for diagnosis'

$threw = $false
try { Invoke-CodexRepair -PackageRoot $fixture -Mode Check } catch { $threw = $true }
Assert $threw 'Custom package roots cannot target the real user profile'
$threw = $false
try { Invoke-CodexRepair -SkipProcessCheck -Mode Check } catch { $threw = $true }
Assert $threw 'Process-check bypass is restricted to isolated tests'

$linkedRoot = Join-Path $suiteRoot 'linked target'
New-Item -ItemType Directory -Path $linkedRoot | Out-Null
New-Item -ItemType Junction -Path (Join-Path $linkedRoot '.codex') -Target $paths.CodexHome | Out-Null
$threw = $false
try { Invoke-CodexRepair -Mode Auto -PackageRoot $fixture -TestRoot $linkedRoot -SkipProcessCheck } catch { $threw = $true }
Assert $threw 'Target directory junctions are rejected before writes'

$manifestFile = Join-Path $runtime 'manifest.json'
$savedManifest = Join-Path $suiteRoot 'removed-manifest.json'
Assert-PathWithin $manifestFile $suiteRoot
[IO.File]::Move($manifestFile, $savedManifest)
$before = Read-Text $configPath
$result = Invoke-CodexRepair -Mode Auto @arguments
Assert ($result.Status -eq 'Failed' -and (Read-Text $configPath) -eq $before) 'Incomplete official resources fail before replacing targets'
[IO.File]::Move($savedManifest, $manifestFile)

# Exercise Store identity selection independently of the current machine.
function Get-AppxPackage {
    param($Name, $ErrorAction)
    foreach ($item in @(@{ Version = '99.0.0.0'; Publisher = 'impostor'; Signature = 'Store' }, @{ Version = '26.10.0.0'; Publisher = '2p2nqsd0c76g0'; Signature = 'Store' }, @{ Version = '26.9.0.0'; Publisher = '2p2nqsd0c76g0'; Signature = 'Store' }, @{ Version = '100.0.0.0'; Publisher = '2p2nqsd0c76g0'; Signature = 'Developer' })) {
        [pscustomobject]@{ PackageFamilyName = 'OpenAI.Codex_2p2nqsd0c76g0'; PublisherId = $item.Publisher; SignatureKind = $item.Signature; Status = 'Ok'; Version = $item.Version; InstallLocation = $fixture; PackageFullName = $item.Version }
    }
}
$package = Resolve-CodexPackageRoot ''
Assert ($package.Version -eq '26.10.0.0') 'Selects newest numeric version and rejects spoofed/developer package identities'

Put (Join-Path $market 'plugins\chrome\.codex-plugin\plugin.json') '{"name":"chrome","version":"..\\escape"}'
$before = Read-Text $configPath
$result = Invoke-CodexRepair -Mode Auto @arguments
Assert ($result.Status -eq 'Failed' -and (Read-Text $configPath) -eq $before) 'Unsafe source plugin version fails before any target replacement'
Write-Host "Passed $script:assertions assertions. Isolated artifacts: $suiteRoot"
