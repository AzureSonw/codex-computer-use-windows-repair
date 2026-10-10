#Requires -Version 5.1
# Real installed CLI regression: never uses the live Codex home or desktop.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Repair.Engine.ps1')
$package = Resolve-CodexPackageRoot ''
$script:VerifiedSourceRoot = $package.Root
$cli = Join-Path $package.Root 'app\resources\codex.exe'
Assert-SourcePath $cli
$suite = Join-Path (Get-FullPath (Join-Path $PSScriptRoot '..\work')) ('marketplace-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $suite | Out-Null
$script:assertions = 0
$script:RepairGuard = {}
$script:RepairBackups = [Collections.Generic.List[string]]::new()
function Assert { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw "ASSERTION FAILED: $Message" }; $script:assertions++; Write-Host "PASS: $Message" }
function Put { param([string]$Path, [string]$Content); [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false)) }
function Invoke-IsolatedMarketplaceAdd {
    param([string]$TestHome, [string]$Marketplace)
    Assert-PathWithin $TestHome $suite
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $cli
    $start.Arguments = 'app-server --stdio'
    $start.WorkingDirectory = $suite
    $start.EnvironmentVariables['CODEX_HOME'] = $TestHome
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $stderr = $process.StandardError.ReadToEndAsync()
    try {
        $requests = @(
            @{ id = 1; method = 'initialize'; params = @{ clientInfo = @{name='repair-test';version='1.3.1'}; capabilities = @{experimentalApi=$true} } },
            @{ id = 2; method = 'marketplace/add'; params = @{source=$Marketplace} }
        )
        foreach ($request in $requests) {
            $process.StandardInput.WriteLine(($request | ConvertTo-Json -Depth 10 -Compress))
            $timer = [Diagnostics.Stopwatch]::StartNew()
            do {
                $read = $process.StandardOutput.ReadLineAsync()
                $remaining = [Math]::Max(1, 15000 - [int]$timer.ElapsedMilliseconds)
                if (-not $read.Wait($remaining)) { throw 'Isolated app-server response timed out.' }
                if ($null -eq $read.Result) { throw 'Isolated app-server closed before responding.' }
                $response = $read.Result | ConvertFrom-Json
            } while ((Get-ChromeProperty $response 'id') -ne $request.id -and $timer.ElapsedMilliseconds -lt 15000)
            if ((Get-ChromeProperty $response 'id') -ne $request.id) { throw 'Expected app-server response missing.' }
            if ($request.id -eq 1) {
                if (Get-ChromeProperty $response 'error') { throw 'Isolated app-server initialization failed.' }
                if ($response.result.codexHome -ne $TestHome) { throw 'App-server did not select the isolated home.' }
                $process.StandardInput.WriteLine('{"method":"initialized"}')
            }
        }
        return $response
    }
    finally {
        $process.StandardInput.Close()
        # Only this test-owned isolated child is stopped; never an existing app.
        if (-not $process.WaitForExit(2000)) { $process.Kill(); $null = $process.WaitForExit(2000) }
        $process.Dispose()
    }
}

foreach ($name in @('literal home', "user's home")) {
    $testHome = Join-Path $suite $name
    $marketplace = Join-Path $testHome '.tmp\bundled-marketplaces\openai-bundled'
    $manifestDir = Join-Path $marketplace '.agents\plugins'
    New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
    Put (Join-Path $manifestDir 'marketplace.json') '{"name":"openai-bundled","plugins":[]}'
    $configPath = Join-Path $testHome 'config.toml'
    $plain = $marketplace.Replace('\', '\\')
    $legacy = "[marketplaces.openai-bundled]`r`nsource_type = `"local`"`r`nsource = `"$plain`"`r`n"
    foreach ($plugin in @('browser', 'chrome', 'computer-use')) { $legacy += "`r`n[plugins.`"$plugin@openai-bundled`"]`r`nenabled = false`r`n" }
    $legacy += "`r`n[unrelated] # preserved`r`nvalue = 42`r`n"
    Put $configPath $legacy
    Assert (-not (Test-CodexConfig $testHome $marketplace)) "$name : legacy source requires migration"
    $before = (Get-FileHash -LiteralPath $configPath).Hash
    $response = Invoke-IsolatedMarketplaceAdd $testHome $marketplace
    Assert ((Get-ChromeProperty $response 'error').message -like '*already added from a different source*') "$name : installed CLI reproduces the original failure"
    Assert ((Get-FileHash -LiteralPath $configPath).Hash -eq $before) "$name : failed registration preserves the old configuration"
    Update-CodexConfig $testHome $marketplace 'source-migration' -PreservePluginPreferences
    Assert ((Get-FileHash -LiteralPath $script:RepairBackups[$script:RepairBackups.Count - 1]).Hash -eq $before) "$name : migration backs up the exact old configuration"
    $fixed = [IO.File]::ReadAllText($configPath)
    Assert (([regex]::Matches($fixed, 'enabled = false')).Count -eq 3 -and $fixed.Contains('value = 42')) "$name : plugin choices and unrelated settings survive migration"
    Assert (Test-CodexConfig $testHome $marketplace) "$name : migrated source passes the checker"
    Assert ((Get-MarketplaceSourcePath $marketplace.ToUpperInvariant()) -ceq (Get-MarketplaceSourcePath $marketplace)) "$name : filesystem canonicalization resolves case aliases"
    $response = Invoke-IsolatedMarketplaceAdd $testHome $marketplace
    Assert (-not (Get-ChromeProperty $response 'error') -and $response.result.alreadyAdded) "$name : installed CLI accepts migrated source"
    Assert (Test-CodexConfig $testHome $marketplace) "$name : desktop TOML serialization remains healthy"
    $accepted = [IO.File]::ReadAllText($configPath)
    Assert (([regex]::Matches($accepted, 'enabled = false')).Count -eq 3 -and $accepted.Contains('value = 42')) "$name : CLI round trip preserves unrelated settings"
    $response = Invoke-IsolatedMarketplaceAdd $testHome $marketplace
    Assert (-not (Get-ChromeProperty $response 'error') -and $response.result.alreadyAdded) "$name : repeated real registration succeeds"
    Assert (Test-CodexConfig $testHome $marketplace) "$name : repeated registration stays healthy"
}
Write-Host "Passed $script:assertions installed marketplace assertions on $($package.Identity), PowerShell $($PSVersionTable.PSVersion). No live profile or Native Messaging state was changed."
