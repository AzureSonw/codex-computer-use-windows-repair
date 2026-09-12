#Requires -Version 5.1
# Functions only. Loading this file never repairs anything.
. (Join-Path $PSScriptRoot 'Repair.Core.ps1')

function Get-ConfigSection {
    param([string]$Content, [string]$Section)
    $pattern = '(?ms)^\s*\[' + [regex]::Escape($Section) + '\][ \t]*(?:#[^\r\n]*)?\r?\n(.*?)(?=^[ \t]*\[|\z)'
    $match = [regex]::Match($Content, $pattern)
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function Test-CodexConfig {
    param([string]$CodexHome, [string]$MarketplacePath)
    $path = Join-Path $CodexHome 'config.toml'
    Assert-NoReparsePath $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $content = [IO.File]::ReadAllText($path)
    $section = Get-ConfigSection $content 'marketplaces.openai-bundled'
    $escaped = $MarketplacePath.Replace('\', '\\').Replace('"', '\"')
    if ($section -notmatch '(?m)^source_type\s*=\s*"local"\s*(?:#.*)?$' -or
        $section -notmatch ('(?m)^source\s*=\s*"' + [regex]::Escape($escaped) + '"\s*(?:#.*)?$')) { return $false }
    foreach ($name in @('browser', 'chrome', 'computer-use')) {
        $section = Get-ConfigSection $content ('plugins."' + $name + '@openai-bundled"')
        # An explicit false is a user preference, not damage.
        if ($section -notmatch '(?m)^enabled\s*=\s*(true|false)\s*(?:#.*)?$') { return $false }
    }
    return $true
}

function Get-RepairPaths {
    param([string]$TestRoot, [string]$CodexHomePath)
    $realHome = if ($env:CODEX_HOME) { Get-FullPath $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $realLocal = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'
    if ($TestRoot) {
        $testPath = Get-FullPath $TestRoot
        $configHome = Join-Path $testPath '.codex'
        $localRoot = Join-Path $testPath 'LocalAppData\OpenAI\Codex'
        foreach ($target in @($configHome, $localRoot)) {
            foreach ($live in @($realHome, (Join-Path $env:USERPROFILE '.codex'), $realLocal)) {
                if ($live -eq $target -or $live.StartsWith($target.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'TestRoot would overlap a live Codex target.'
                }
            }
        }
    }
    else {
        $configHome = if ($CodexHomePath) { Get-FullPath $CodexHomePath } else { $realHome }
        $localRoot = $realLocal
    }
    Assert-NoReparsePath $configHome
    Assert-NoReparsePath $localRoot
    return [pscustomobject]@{ CodexHome = $configHome; LocalRoot = $localRoot; StateRoot = (Join-Path $localRoot 'computer-use-repair') }
}

function Get-LimitedProcessImagePath {
    param([int]$ProcessId)
    # Get-Process.Path can require module access and return null for unrelated
    # elevated apps. Limited image queries do not read process memory.
    if (-not ('CodexRepair.ProcessImageLookup' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace CodexRepair {
    public static class ProcessImageLookup {
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inherit, int id);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool QueryFullProcessImageName(IntPtr handle, uint flags, StringBuilder name, ref uint size);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);
        public static string GetPath(int id) {
            IntPtr handle = OpenProcess(0x1000, false, id); // PROCESS_QUERY_LIMITED_INFORMATION
            if (handle == IntPtr.Zero) return null;
            try {
                uint size = 32768;
                var name = new StringBuilder((int)size);
                return QueryFullProcessImageName(handle, 0, name, ref size) ? name.ToString() : null;
            } finally { CloseHandle(handle); }
        }
    }
}
'@
    }
    return [CodexRepair.ProcessImageLookup]::GetPath($ProcessId)
}

function Get-RepairProcesses {
    param([string]$RuntimeParent)
    $runtimePrefix = (Get-FullPath $RuntimeParent).TrimEnd('\') + '\'
    foreach ($process in @(Get-Process -Name 'Codex', 'ChatGPT', 'node_repl', 'codex-computer-use', 'node' -ErrorAction SilentlyContinue)) {
        try { $path = $process.Path } catch { $path = $null }
        if (-not $path) {
            try { $path = Get-LimitedProcessImagePath $process.Id } catch { $path = $null }
        }
        if ($process.ProcessName -eq 'node' -and $path -and
            -not $path.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $reason = if ($path) { 'Codex app or Computer Use runtime' } else { 'Image path unavailable; cannot safely rule out runtime use' }
        [pscustomobject]@{ Id = $process.Id; ProcessName = $process.ProcessName; Path = $path; Reason = $reason }
    }
}

function Format-RepairProcesses {
    param([object[]]$Processes)
    return ((@($Processes | ForEach-Object { "$($_.ProcessName) (PID $($_.Id))" })) -join ', ')
}

function Wait-RepairProcesses {
    param([string]$RuntimeParent, [int]$WaitSeconds, $Report, [string]$ReportPath)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastDisplay = -15
    $previous = ''
    while ($true) {
        $blocking = @(Get-RepairProcesses $RuntimeParent)
        $Report.BlockingProcesses = $blocking
        if (-not $blocking.Count) {
            if ($previous) { Write-Host 'Blocking processes have exited. Continuing repair...' }
            return
        }
        $summary = Format-RepairProcesses $blocking
        $remaining = [Math]::Max(0, [Math]::Ceiling($WaitSeconds - $timer.Elapsed.TotalSeconds))
        if ($summary -ne $previous -or $timer.Elapsed.TotalSeconds - $lastDisplay -ge 15) {
            Write-Host "Blocking processes: $summary"
            foreach ($process in $blocking) {
                if ($process.PSObject.Properties['Path'] -and $process.Path) { Write-Host "  PID $($process.Id): $($process.Path)" }
            }
            if ($remaining -gt 0) {
                Write-Host "Keep this CMD window open. Fully quit ChatGPT/Codex from the tray; repair will continue here (up to $remaining seconds remaining)."
            }
            $Report.Status = 'Waiting'; $Report.ExitCode = 10
            $Report.Message = "Waiting for: $summary"
            Write-RepairJson $ReportPath $Report
            $lastDisplay = $timer.Elapsed.TotalSeconds
            $previous = $summary
        }
        if ($timer.Elapsed.TotalSeconds -ge $WaitSeconds) {
            throw "DEFERRED: Still blocked by $summary. Check these PIDs in Task Manager. No process was stopped; run the CMD again after they exit."
        }
        Start-Sleep -Milliseconds 1000
    }
}

function Write-RepairJson {
    param([string]$Path, $Value)
    Assert-NoReparsePath $Path
    $temp = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temp, $Path) }
}

function Read-RepairState {
    param([string]$Path)
    $state = @{ Schema = 1; Fingerprint = ''; LastFullCheck = ''; FailureCount = 0; NextRetry = ''; Interrupted = $false; Hashes = @{} }
    if (Test-Path -LiteralPath $Path) {
        try {
            $saved = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
            if ($saved.Schema -ne 1) { return $state }
            foreach ($key in @('Fingerprint', 'LastFullCheck', 'FailureCount', 'NextRetry', 'Interrupted')) { $state[$key] = $saved.$key }
            # PowerShell 7.5+ deserializes ISO strings as DateTime; 5.1 leaves
            # them as strings. Normalize UTC before comparing retry deadlines.
            foreach ($key in @('LastFullCheck', 'NextRetry')) {
                if ($state[$key] -is [DateTime]) { $state[$key] = $state[$key].ToUniversalTime().ToString('o') }
            }
            foreach ($property in $saved.Hashes.PSObject.Properties) {
                $state.Hashes[$property.Name] = @{ Stamp = $property.Value.Stamp; Hash = $property.Value.Hash }
            }
        }
        catch {
            Write-Warning 'Unreadable check state; performing a fresh integrity check.'
            $state = @{ Schema = 1; Fingerprint = ''; LastFullCheck = ''; FailureCount = 0; NextRetry = ''; Interrupted = $false; Hashes = @{} }
        }
    }
    return $state
}

function Get-ResourceFingerprint {
    param($Package, $Trees)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add($Package.Identity)
    $lines.Add($Package.Root)
    foreach ($tree in $Trees) {
        $lines.Add($tree.Target)
        $inventory = Get-TreeInventory $tree.Source
        foreach ($key in @($inventory.Keys | Sort-Object)) { $lines.Add("$key|$($inventory[$key].Length)|$($inventory[$key].Hash)") }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($lines -join "`n")))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-RepairPlan {
    param($Package, $Paths)
    $runtime = Join-Path $Package.Root 'app\resources\cua_node'
    $market = Join-Path $Package.Root 'app\resources\plugins\openai-bundled'
    $runtimeKeys = @('manifest.json', 'bin\node.exe', 'bin\node_repl.exe',
        'bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe',
        'bin\node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js')
    $marketKeys = @('.agents\plugins\marketplace.json', 'plugins\browser\.codex-plugin\plugin.json',
        'plugins\browser\scripts\browser-client.mjs', 'plugins\chrome\.codex-plugin\plugin.json',
        'plugins\computer-use\.codex-plugin\plugin.json', 'plugins\computer-use\skills\computer-use\SKILL.md')
    foreach ($source in @(@{ Root = $runtime; Keys = $runtimeKeys }, @{ Root = $market; Keys = $marketKeys })) {
        foreach ($key in $source.Keys) {
            $file = Join-Path $source.Root $key
            Assert-SourcePath $file
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Unsupported/incomplete official package: missing $file. No targets replaced." }
        }
    }
    $runtimeHash = Get-RuntimeDirectoryHash $runtime
    $runtimeParent = Join-Path $Paths.LocalRoot 'runtimes\cua_node'
    $marketParent = Join-Path $Paths.CodexHome '.tmp\bundled-marketplaces'
    $trees = @(
        @{ Label = 'Official Computer Use runtime'; Source = $runtime; Parent = $runtimeParent; Target = (Join-Path $runtimeParent $runtimeHash); Keys = $runtimeKeys },
        @{ Label = 'OpenAI bundled marketplace'; Source = $market; Parent = $marketParent; Target = (Join-Path $marketParent 'openai-bundled'); Keys = $marketKeys }
    )
    foreach ($name in @('browser', 'chrome', 'computer-use')) {
        $source = Join-Path $market "plugins\$name"
        $manifest = [IO.File]::ReadAllText((Join-Path $source '.codex-plugin\plugin.json')) | ConvertFrom-Json
        if ($manifest.name -ne $name -or [string]$manifest.version -notmatch '^\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9.-]+)?$') {
            throw "Unsupported plugin manifest for $name. Refusing an unsafe version directory."
        }
        $parent = Join-Path $Paths.CodexHome "plugins\cache\openai-bundled\$name"
        $trees += @{ Label = "Plugin cache: $name"; Source = $source; Parent = $parent; Target = (Join-Path $parent ([string]$manifest.version)); Keys = @('.codex-plugin\plugin.json') }
    }
    foreach ($tree in $trees) {
        Assert-PathWithin $tree.Target $tree.Parent
        if ($tree.Target.StartsWith($Package.Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Repair targets cannot be inside the official source package.' }
    }
    return [pscustomobject]@{ Trees = $trees; RuntimeHash = $runtimeHash; Marketplace = $trees[1].Target; Runtime = $trees[0].Target }
}

function Test-RestoredNode {
    param([string]$Runtime)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $Runtime 'bin\node.exe'
    $start.Arguments = '--version'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Restored Node self-test timed out after 10 seconds.' }
        $version = $process.StandardOutput.ReadToEnd().Trim()
        if ($process.ExitCode -ne 0 -or $version -notmatch '^v\d+\.\d+\.\d+$') { throw 'Restored Node --version self-test failed.' }
        return $version
    }
    finally { $process.Dispose() }
}

function Invoke-CodexRepair {
    [CmdletBinding()]
    param(
        [ValidateSet('Manual', 'Auto', 'Check')][string]$Mode = 'Manual',
        [string]$PackageRoot = '', [string]$TestRoot = '', [string]$CodexHomePath = '',
        [switch]$SkipProcessCheck, [switch]$FullCheck,
        [ValidateRange(0, 300)][int]$WaitSeconds = 0
    )
    $ErrorActionPreference = 'Stop'
    if (($PackageRoot -or $SkipProcessCheck) -and -not $TestRoot) { throw '-PackageRoot and -SkipProcessCheck require an isolated -TestRoot.' }
    if ($TestRoot -and $CodexHomePath) { throw '-TestRoot cannot be combined with -CodexHomePath.' }
    $paths = Get-RepairPaths $TestRoot $CodexHomePath
    Assert-NoReparsePath $paths.StateRoot
    New-Item -ItemType Directory -Path $paths.StateRoot -Force | Out-Null
    $lockPath = Join-Path $paths.StateRoot 'check.lock'
    Assert-NoReparsePath $lockPath
    try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] {
        Write-Warning 'Deferred: another repair/check owns the lock. Run the CMD again after it finishes.'
        return [pscustomobject]@{ Status = 'Deferred'; ExitCode = 10; Message = 'Another repair/check owns the lock.' }
    }
    $transcribing = $false
    $statePath = Join-Path $paths.StateRoot 'state.json'
    $reportPath = Join-Path $paths.StateRoot 'last-result.json'
    $script:RepairBackups = [Collections.Generic.List[string]]::new()
    $report = [ordered]@{ Status = 'Checking'; ExitCode = 1; CheckedAt = [DateTime]::UtcNow.ToString('o'); Package = ''; PackageVersion = ''; RuntimeHash = ''; Fingerprint = ''; Changed = @(); Backups = @(); BlockingProcesses = @(); Message = ''; Log = '' }
    $state = $null
    $attempted = $false
    try {
        $logs = Join-Path $paths.StateRoot 'logs'
        Assert-NoReparsePath $logs
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        $report.Log = Join-Path $logs ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N') + '.log')
        Start-Transcript -LiteralPath $report.Log | Out-Null
        $transcribing = $true
        # Keep the most recent 20 diagnostic logs; never remove repair backups or staging.
        foreach ($old in @(Get-ChildItem -LiteralPath $logs -File -Filter '*.log' | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 20)) {
            Assert-PathWithin $old.FullName $logs
            Remove-Item -LiteralPath $old.FullName -Force
        }
        $package = Resolve-CodexPackageRoot $PackageRoot
        $script:VerifiedSourceRoot = $package.Root
        $report.Package = $package.Identity
        $report.PackageVersion = $package.Version
        Write-Host "Installed package: $($package.Identity)"
        $runtimeParent = Join-Path $paths.LocalRoot 'runtimes\cua_node'
        if ($Mode -ne 'Check' -and -not $SkipProcessCheck) {
            Wait-RepairProcesses -RuntimeParent $runtimeParent -WaitSeconds $WaitSeconds -Report $report -ReportPath $reportPath
            # An update can finish while the user is quitting the application.
            $package = Resolve-CodexPackageRoot $PackageRoot
            $script:VerifiedSourceRoot = $package.Root
            $report.Package = $package.Identity
            $report.PackageVersion = $package.Version
        }
        $script:RepairGuard = {
            if (-not $SkipProcessCheck) {
                $blocking = @(Get-RepairProcesses $runtimeParent)
                $report.BlockingProcesses = $blocking
                if ($blocking.Count) { throw "DEFERRED: Runtime is in use by $(Format-RepairProcesses $blocking). Run the CMD again after these processes exit." }
            }
            if (-not $PackageRoot) {
                $current = Resolve-CodexPackageRoot ''
                if ($current.Identity -ne $package.Identity -or $current.Root -ne $package.Root) { throw 'DEFERRED: The installed package changed during the check; retry on the next run.' }
            }
        }.GetNewClosure()
        $state = Read-RepairState $statePath
        $script:HashCache = $state.Hashes
        $script:NextHashCache = @{}
        $script:SourceInventories = @{}
        $script:FullHashCheck = $FullCheck -or $Mode -eq 'Manual' -or -not $state.LastFullCheck
        if ($state.LastFullCheck) {
            try { if ([DateTime]::Parse($state.LastFullCheck).ToUniversalTime() -lt [DateTime]::UtcNow.AddHours(-24)) { $script:FullHashCheck = $true } }
            catch { $script:FullHashCheck = $true }
        }
        $plan = Get-RepairPlan $package $paths
        $report.RuntimeHash = $plan.RuntimeHash
        $fingerprint = Get-ResourceFingerprint $package $plan.Trees
        $report.Fingerprint = $fingerprint
        if ($state.Fingerprint -ne $fingerprint) {
            $state.FailureCount = 0; $state.NextRetry = ''; $state.Interrupted = $false
        }
        $state.Fingerprint = $fingerprint
        if ($Mode -eq 'Auto' -and $state.Interrupted) { throw 'PAUSED: Previous repair was interrupted. Review logs/backups and run the manual repair once.' }
        $damaged = @()
        foreach ($tree in $plan.Trees) {
            if (-not (Test-TreeMatches $tree.Source $tree.Target $tree.Keys)) { $damaged += $tree }
        }
        $configHealthy = Test-CodexConfig $paths.CodexHome $plan.Marketplace
        if (-not $damaged.Count -and $configHealthy -and -not $state.FailureCount -and -not $state.Interrupted -and $Mode -ne 'Manual') {
            $report.Status = 'Healthy'; $report.ExitCode = 0; $report.Message = 'All required runtime and plugin files are healthy; no repair needed.'
            $state.FailureCount = 0; $state.NextRetry = ''; $state.Interrupted = $false
        }
        elseif ($Mode -eq 'Check') {
            $report.Status = 'NeedsRepair'; $report.ExitCode = 2; $report.Message = 'Missing, changed, or unconfigured components detected. Check mode did not modify Codex.'
            $report.Changed = @($damaged | ForEach-Object { $_.Label })
            if (-not $configHealthy) { $report.Changed += 'Plugin configuration' }
        }
        else {
            if ($Mode -eq 'Auto' -and $state.FailureCount -ge 3) { throw 'PAUSED: Three automatic repair attempts failed for these resources. Review diagnostics and run the manual repair.' }
            if ($Mode -eq 'Auto' -and $state.NextRetry -and [DateTime]::Parse($state.NextRetry).ToUniversalTime() -gt [DateTime]::UtcNow) { throw "COOLDOWN: Next automatic attempt after $($state.NextRetry)." }
            & $script:RepairGuard
            $state.Interrupted = $true
            Write-RepairJson $statePath $state
            $report.Status = 'Repairing'
            Write-RepairJson $reportPath $report
            $attempted = $true
            $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            foreach ($tree in $damaged) {
                Copy-TreeByDecryptedStream -Source $tree.Source -Final $tree.Target -AllowedParent $tree.Parent -Label $tree.Label -KeyRelativePaths $tree.Keys -Timestamp $timestamp
                $report.Changed += $tree.Label
                $report.Backups = @($script:RepairBackups.ToArray())
                Write-RepairJson $reportPath $report
            }
            # Verify executable health before changing user configuration.
            $nodeVersion = Test-RestoredNode $plan.Runtime
            if (-not $configHealthy -or $Mode -eq 'Manual') {
                Update-CodexConfig -CodexHome $paths.CodexHome -MarketplacePath $plan.Marketplace -Timestamp $timestamp -PreservePluginPreferences:($Mode -eq 'Auto')
                $report.Changed += 'Plugin configuration'
            }
            & $script:RepairGuard
            if (-not (Test-CodexConfig $paths.CodexHome $plan.Marketplace)) { throw 'Configuration verification failed.' }
            $state.FailureCount = 0; $state.NextRetry = ''; $state.Interrupted = $false
            $report.Status = 'Repaired'; $report.ExitCode = 0; $report.Message = "Repair completed successfully. Node runtime: $nodeVersion"
        }
        $state.Hashes = $script:NextHashCache
        if ($script:FullHashCheck) { $state.LastFullCheck = [DateTime]::UtcNow.ToString('o') }
        Write-RepairJson $statePath $state
    }
    catch {
        $report.Message = $_.Exception.Message
        if ($report.Message -like 'DEFERRED:*') { $report.Status = 'Deferred'; $report.ExitCode = 10 }
        elseif ($report.Message -like 'COOLDOWN:*') { $report.Status = 'Cooldown'; $report.ExitCode = 11 }
        elseif ($report.Message -like 'PAUSED:*') { $report.Status = 'Paused'; $report.ExitCode = 12 }
        else { $report.Status = 'Failed'; $report.ExitCode = 1 }
        if ($attempted -and $state) {
            $state.Interrupted = $false
            if ($report.Status -eq 'Failed') {
                $state.FailureCount = [int]$state.FailureCount + 1
                $hours = [Math]::Min(24, [Math]::Pow(4, [int]$state.FailureCount - 1))
                $state.NextRetry = [DateTime]::UtcNow.AddHours($hours).ToString('o')
            }
            Write-RepairJson $statePath $state
        }
        Write-Warning $report.Message
    }
    finally {
        try {
            $report.Backups = @($script:RepairBackups.ToArray())
            Write-RepairJson $reportPath $report
            Write-Host "$($report.Status): $($report.Message)"
            Write-Host "Result: $reportPath"
            if ($transcribing) { Stop-Transcript | Out-Null }
        }
        finally { $lock.Dispose() }
    }
    return [pscustomobject]$report
}
