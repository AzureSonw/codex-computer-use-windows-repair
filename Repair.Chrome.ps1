#Requires -Version 5.1
# Chrome integration is a separate stage; this module never runs on import.
Set-StrictMode -Version Latest

function Read-ChromeJson {
    param([string]$Path, [switch]$Trusted)
    if ($Trusted) { Assert-SourcePath $Path } else { Assert-NoReparsePath $Path }
    if ((Get-Item -LiteralPath $Path).Length -gt 16MB) { throw "JSON file is too large: $Path" }
    return [IO.File]::ReadAllText($Path) | ConvertFrom-Json
}

function Get-ChromeProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Read-ChromeAsarContract {
    param([string]$Path)
    Assert-SourcePath $Path
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt32() -ne 4) { throw 'Unsupported ASAR header.' }
        $headerSize = $reader.ReadUInt32()
        $null = $reader.ReadUInt32()
        $jsonSize = $reader.ReadUInt32()
        if ($jsonSize -gt 32MB -or $headerSize -lt ($jsonSize + 8)) { throw 'Invalid ASAR header size.' }
        $header = [Text.Encoding]::UTF8.GetString($reader.ReadBytes($jsonSize)) | ConvertFrom-Json
        $base = 8L + $headerSize
        $entries = @(@{ Name = 'package.json'; Entry = $header.files.'package.json' })
        foreach ($p in $header.files.'.vite'.files.build.files.PSObject.Properties) {
            if ($p.Name -match '^(main-|src-).+\.js$') { $entries += @{ Name = $p.Name; Entry = $p.Value } }
        }
        $main = ''; $native = ''; $appVersion = ''
        foreach ($entry in $entries) {
            $item = $entry.Entry
            if ((Get-ChromeProperty $item 'unpacked' $false) -or $item.size -gt 24MB) { continue }
            $offset = $base + [long]$item.offset
            if ($offset -lt $base -or ($offset + [long]$item.size) -gt $stream.Length) { throw 'Invalid ASAR entry bounds.' }
            $stream.Position = $offset
            $text = [Text.Encoding]::UTF8.GetString($reader.ReadBytes([int]$item.size))
            if ($entry.Name -eq 'package.json') { $appVersion = ($text | ConvertFrom-Json).version }
            if ($text.Contains('CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH') -and $text.Contains('.materialization-key')) { $main = $text }
            if ($text.Contains('chrome-native-hosts-v2.json') -and $text.Contains('nativeHostProtocolVersion:')) { $native = $text }
        }
        # Recognize semantics, not minifier identifiers or a hard-coded release number.
        foreach ($token in @('bundled_plugins_marketplace_resolve_failed', 'computerUseAudioEnabled:', 'liveVisualizationSkillVariant:', 'visualizeSkillContentHash:', '.bundle-id', 'process.resourcesPath')) {
            if (-not $main.Contains($token)) { throw "Unsupported marketplace initialization layout: missing $token" }
        }
        $schema = [regex]::Match($native, 'schemaVersion:(\w+),appServerProtocolVersion:(\w+)')
        $protocol = [regex]::Match($native, 'nativeHostProtocolVersion:(\w+),nativeHostVersion:')
        if (-not $schema.Success -or -not $protocol.Success) { throw 'Unsupported Chrome resource registration layout.' }
        foreach ($symbol in @($schema.Groups[1].Value, $schema.Groups[2].Value, $protocol.Groups[1].Value)) {
            if (-not [regex]::IsMatch($native, ('\b' + [regex]::Escape($symbol) + '=2[,;]'))) { throw 'Unsupported Chrome resource protocol; refusing to guess.' }
        }
        if ($appVersion -notmatch '^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$') { throw 'Unsupported desktop application version format.' }
        return [pscustomobject]@{ AppVersion = $appVersion; Schema = 2; ResourceFile = 'chrome-native-hosts-v2.json'; LaunchEnvironment = 'CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH' }
    }
    finally { $reader.Dispose(); $stream.Dispose() }
}

function Get-ChromeIntegrationPlan {
    param($Package, $Paths, $ResourcePlan)
    $resources = Join-Path $Package.Root 'app\resources'
    $source = Join-Path $resources 'plugins\openai-bundled\plugins\chrome'
    $ids = Read-ChromeJson (Join-Path $source 'scripts\extension-ids.json') -Trusted
    $hostName = [string]$ids.extensionHostName
    if ($hostName -notmatch '^[a-z0-9_]+(?:\.[a-z0-9_]+)+$') { throw 'Unsupported native host name.' }
    $extensionIds = @($ids.extensionIds)
    if (-not $extensionIds.Count -or @($extensionIds | Where-Object { $_ -notmatch '^[a-p]{32}$' }).Count) { throw 'Unsupported native extension origins.' }
    $registryRoot = [string]$ids.windowsNativeMessaging.registryRoot
    if ($registryRoot -cne 'HKCU\Software\Google\Chrome\NativeMessagingHosts') { throw 'Unsupported native host registry destination; only the current-user Chrome key is supported.' }
    if ([string]$ids.windowsNativeMessaging.manifestDirectory -cne 'AppData/Local/OpenAI/extension') { throw 'Unsupported native host manifest destination.' }
    $contract = Read-ChromeAsarContract (Join-Path $resources 'app.asar')
    $plugin = Read-ChromeJson (Join-Path $source '.codex-plugin\plugin.json') -Trusted
    $cacheTree = @($ResourcePlan.Trees | Where-Object { $_.Label -eq 'Plugin cache: chrome' })[0]
    $bridges = @(Get-SafeTreeFiles (Join-Path $source 'extension-host\windows') | Where-Object { $_.Name -eq 'extension-host.exe' })
    if ($bridges.Count -ne 1) { throw 'Unsupported/ambiguous Windows Chrome bridge layout.' }
    $bridgeRelative = Get-RelativePath $source $bridges[0].FullName
    $localAppData = Split-Path -Parent (Split-Path -Parent $Paths.LocalRoot)
    $manifest = Join-Path $localAppData ("OpenAI\extension\$hostName.json")
    $latest = Join-Path $cacheTree.Parent 'latest'
    $view = Join-Path $Paths.StateRoot ('chrome-resources\' + $ResourcePlan.RuntimeHash + '-' + $plugin.version)
    $appxPath = Join-Path $Package.Root 'AppxManifest.xml'
    Assert-SourcePath $appxPath
    [xml]$appx = [IO.File]::ReadAllText($appxPath)
    $aliases = @($appx.SelectNodes('//*[local-name()="Extension" and @Category="windows.appExecutionAlias"]') | Where-Object {
        ([string]$_.Executable).Replace('/', '\').EndsWith($bridgeRelative, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($aliases.Count -ne 1) { throw 'Unsupported Chrome execution alias declaration.' }
    $aliasName = [string]$aliases[0].SelectSingleNode('.//*[local-name()="ExecutionAlias"]/@Alias').Value
    if ($aliasName -notmatch '^[a-zA-Z0-9-]+\.exe$') { throw 'Unsafe Chrome execution alias.' }
    $backing = Join-Path $Package.Root ([string]$aliases[0].Executable)
    Assert-SourcePath $backing
    if ((Get-FullPath $backing) -ne $bridges[0].FullName) { throw 'Chrome alias does not refer to the trusted bridge.' }
    $desktopNodes = @($appx.SelectNodes('//*[local-name()="Application" and @Id="App"]'))
    if ($desktopNodes.Count -ne 1) { throw 'Unsupported desktop application entry point.' }
    $desktop = Join-Path $Package.Root ([string]$desktopNodes[0].Executable)
    Assert-SourcePath $desktop
    if (-not (Test-Path -LiteralPath $desktop -PathType Leaf)) { throw 'Missing trusted desktop executable.' }
    foreach ($p in @($manifest, $view, $cacheTree.Target)) { Assert-NoReparsePath $p }
    return [pscustomobject]@{
        HostName = $hostName; ExtensionIds = $extensionIds; Origins = @($extensionIds | ForEach-Object { "chrome-extension://$_/" })
        RegistryPath = "$registryRoot\$hostName"; RegistrySubKey = $registryRoot.Substring(5) + '\' + $hostName
        Manifest = $manifest; BridgeRelative = $bridgeRelative; SourceBridge = $bridges[0].FullName
        Cache = $cacheTree.Target; Latest = $latest; Version = [string]$plugin.version
        Alias = (Join-Path $localAppData "Microsoft\WindowsApps\$($Package.Family)\$aliasName")
        Resources = $resources; View = $view; Desktop = $desktop; Contract = $contract
        V2Files = @((Join-Path $Paths.CodexHome $contract.ResourceFile), (Join-Path $Paths.LocalRoot $contract.ResourceFile))
        Marker = (Join-Path $ResourcePlan.Marketplace '.materialization-key'); Marketplace = $ResourcePlan.Marketplace
        SourceMarketplace = (Join-Path $resources 'plugins\openai-bundled'); CodexHome = $Paths.CodexHome
        Runtime = $ResourcePlan.Runtime; StateRoot = $Paths.StateRoot; Isolated = [bool]$Paths.Isolated
        RegistryFile = (Join-Path $Paths.StateRoot 'isolated-native-registry.json')
    }
}

function Get-ChromeRegistryState {
    param($Plan)
    if ($Plan.Isolated) {
        if (Test-Path -LiteralPath $Plan.RegistryFile) { return Read-ChromeJson $Plan.RegistryFile }
        return [pscustomobject]@{ KeyExists = $false; ValueExists = $false; Value = $null; Kind = 'String' }
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Plan.RegistrySubKey, $false)
    try {
        if ($null -eq $key) { return [pscustomobject]@{ KeyExists = $false; ValueExists = $false; Value = $null; Kind = 'String' } }
        $exists = @($key.GetValueNames()) -contains ''
        return [pscustomobject]@{ KeyExists = $true; ValueExists = $exists; Value = $key.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); Kind = $(if ($exists) { [string]$key.GetValueKind('') } else { 'String' }) }
    }
    finally { if ($null -ne $key) { $key.Dispose() } }
}

function Test-ChromeLatest {
    param($Plan)
    # The app-owned latest junction is inspected, never traversed by tree copying.
    Assert-NoReparsePath (Split-Path -Parent $Plan.Latest)
    Assert-NoReparsePath $Plan.Cache
    $item = Get-Item -LiteralPath $Plan.Latest -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    if ($item.LinkType -ne 'Junction') { return $false }
    $targets = @($item.Target)
    return $targets.Count -eq 1 -and (Get-FullPath $targets[0]) -eq (Get-FullPath $Plan.Cache)
}

function Get-ChromeLatestTarget {
    param($Plan)
    Assert-NoReparsePath (Split-Path -Parent $Plan.Latest)
    $item = Get-Item -LiteralPath $Plan.Latest -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return '' }
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType -ne 'Junction' -or @($item.Target).Count -ne 1) {
        throw 'Unsafe Chrome latest reference; expected an app-owned version junction.'
    }
    $target = Get-FullPath (@($item.Target)[0])
    if ((Split-Path -Parent $target) -ne (Split-Path -Parent $Plan.Cache) -or (Split-Path -Leaf $target) -notmatch '^\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9.-]+)?$') {
        throw 'Unsafe Chrome latest target outside the versioned cache.'
    }
    Assert-NoReparsePath $target
    return $target
}

function Assert-ChromeWriteTargets {
    param($Plan)
    $null = Get-ChromeLatestTarget $Plan
    foreach ($path in @($Plan.Manifest, $Plan.Marker, $Plan.View) + $Plan.V2Files) { Assert-NoReparsePath $path }
    $key = $null
    if (Test-Path -LiteralPath $Plan.Marker -PathType Leaf) { try { $key = Read-ChromeJson $Plan.Marker } catch { } }
    if ((Get-ChromeProperty $key 'computerUseAudioEnabled' $false) -eq $true -or
        (Get-ChromeProperty $key 'visualizeTreatment' $false) -eq $true -or
        ($env:SKY_ENABLE_AUDIO -eq '1' -and $env:NODE_REPL_ENABLE_AUDIO -eq '1')) {
        throw 'DEFERRED: Unsupported marketplace content variant. Existing state was preserved; use desktop diagnostics before repair.'
    }
}

function Test-ChromeTrustedFile {
    param([string]$Path, [string]$Source, $Plan, [string[]]$AllowedPaths)
    if ($AllowedPaths -notcontains $Path) { return $false }
    Assert-SourcePath $Source
    $physical = $Path
    if ($Path.StartsWith($Plan.Latest + '\', [StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-ChromeLatest $Plan)) { return $false }
        $physical = $Plan.Cache + $Path.Substring($Plan.Latest.Length)
    }
    if ($physical.StartsWith($script:VerifiedSourceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { Assert-SourcePath $physical }
    else { Assert-NoReparsePath $physical }
    if (-not (Test-Path -LiteralPath $physical -PathType Leaf)) { return $false }
    return (Get-FileHash -LiteralPath $physical -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
}

function Test-MarketplaceInitialization {
    param($Plan, [switch]$ResourcesOnly)
    $issues = [Collections.Generic.List[string]]::new()
    try {
        $key = $null
        if (-not $ResourcesOnly) { $key = Read-ChromeJson $Plan.Marker }
        $sourceManifest = Read-ChromeJson (Join-Path $Plan.SourceMarketplace '.agents\plugins\marketplace.json') -Trusted
        $manifest = Read-ChromeJson (Join-Path $Plan.Marketplace '.agents\plugins\marketplace.json')
        $bundlePath = Join-Path $Plan.SourceMarketplace '.bundle-id'; Assert-SourcePath $bundlePath
        if (-not $ResourcesOnly -and ($key.version -ne 1 -or $key.appVersion -ne $Plan.Contract.AppVersion -or
            $key.bundleId -ne [IO.File]::ReadAllText($bundlePath).Trim() -or $key.marketplaceName -ne 'openai-bundled')) { throw 'Stale or incompatible marketplace initialization metadata.' }
        if ($manifest.name -ne 'openai-bundled' -or (-not $ResourcesOnly -and @($key.plugins).Count -ne @($manifest.plugins).Count)) { throw 'Marketplace initialization/plugin set mismatch.' }
        if (-not $ResourcesOnly -and ($key.computerUseAudioEnabled -ne $false -or $key.visualizeTreatment -ne $false -or $key.liveVisualizationSkillVariant -notin @($null, 'live-enabled', 'live-disabled'))) { throw 'Unsupported marketplace content variant; leave regeneration to the desktop app.' }
        $seen = @{}
        foreach ($entry in $manifest.plugins) {
            if ($seen.ContainsKey($entry.name)) { throw 'Duplicate initialized plugin.' }; $seen[$entry.name] = $true
            $official = @($sourceManifest.plugins | Where-Object { $_.name -ceq $entry.name })
            if ($official.Count -ne 1 -or $entry.source.source -ne 'local' -or $entry.source.path -cne $official[0].source.path) { throw 'Unexpected initialized marketplace plugin.' }
            $src = Join-Path $Plan.SourceMarketplace $entry.source.path; Assert-SourcePath $src
            $dst = Join-Path $Plan.Marketplace $entry.source.path; Assert-PathWithin $dst $Plan.Marketplace
            $original = Read-ChromeJson (Join-Path $src '.codex-plugin\plugin.json') -Trusted
            if (-not $ResourcesOnly) {
                $metadata = @($key.plugins | Where-Object { $_.name -ceq $entry.name })
                if ($metadata.Count -ne 1 -or $metadata[0].version -cne $original.version) { throw 'Stale initialized plugin version.' }
            }
            $liveVariant = $null
            if ($entry.name -eq 'visualize') {
                $variant = Read-ChromeJson (Join-Path $dst '.codex-plugin\plugin.json')
                $liveVariant = Get-ChromeProperty $variant 'bundledContentVariant'
                if ($liveVariant -notin @($null, 'live-enabled', 'live-disabled') -or (-not $ResourcesOnly -and $liveVariant -ne $key.liveVisualizationSkillVariant)) { throw 'Wrong visualization variant.' }
            }
            $expected = Get-TreeInventory $src; $actual = Get-TreeInventory $dst
            foreach ($relative in $expected.Keys) {
                if ($entry.name -eq 'visualize' -and $liveVariant -eq 'live-disabled' -and $relative.StartsWith('skills\live\')) { continue }
                if ($entry.name -eq 'visualize' -and $relative -eq '.codex-plugin\plugin.json') {
                    $variant.PSObject.Properties.Remove('bundledContentVariant')
                    if (($variant | ConvertTo-Json -Depth 30 -Compress) -cne ($original | ConvertTo-Json -Depth 30 -Compress)) { throw 'Changed initialized plugin manifest.' }
                }
                elseif (-not $actual.ContainsKey($relative) -or $actual[$relative].Hash -ne $expected[$relative].Hash) { throw "Missing or changed initialized plugin file: $($entry.name)/$relative" }
            }
            foreach ($relative in $actual.Keys) { if (-not $expected.ContainsKey($relative)) { throw 'Unexpected file in initialized plugin.' } }
        }
        if (-not $seen.ContainsKey('chrome')) { throw 'Chrome is not in the initialized marketplace.' }
        $sourceManifest.plugins = @($sourceManifest.plugins | Where-Object { $seen.ContainsKey($_.name) })
        if (($manifest | ConvertTo-Json -Depth 30 -Compress) -cne ($sourceManifest | ConvertTo-Json -Depth 30 -Compress)) { throw 'Changed initialized marketplace manifest.' }
        if (-not $ResourcesOnly -and $seen.ContainsKey('visualize')) {
            $skillPath = Join-Path $Plan.SourceMarketplace 'plugins\visualize\skills\visualize\SKILL.md'; Assert-SourcePath $skillPath
            if ($key.visualizeSkillContentHash -ne (Get-FileHash -LiteralPath $skillPath -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Stale visualization skill metadata.' }
        }
    }
    catch { $issues.Add('Bundled marketplace initialization: ' + $_.Exception.Message) }
    return $issues.ToArray()
}

function Test-ChromeNativeMessaging {
    param($Plan)
    $issues = [Collections.Generic.List[string]]::new()
    foreach ($issue in @(Test-MarketplaceInitialization $Plan)) { $issues.Add($issue) }
    $latestHealthy = Test-ChromeLatest $Plan
    if (-not $latestHealthy) { $issues.Add('Chrome latest reference is missing or stale.') }
    $bridgeCandidates = @($Plan.SourceBridge, (Join-Path $Plan.Cache $Plan.BridgeRelative), (Join-Path $Plan.Latest $Plan.BridgeRelative), (Join-Path $Plan.View ('plugins\openai-bundled\plugins\chrome\' + $Plan.BridgeRelative)))
    try {
        $registry = Get-ChromeRegistryState $Plan
        if (-not $registry.KeyExists -or -not $registry.ValueExists) { $issues.Add('Chrome NativeMessagingHosts registration missing.') }
        elseif ($registry.Kind -ne 'String' -or $registry.Value -ne $Plan.Manifest) { $issues.Add('Chrome NativeMessagingHosts registration points to an unexpected manifest.') }
        $manifest = Read-ChromeJson $Plan.Manifest
        if ($manifest.name -cne $Plan.HostName -or $manifest.type -cne 'stdio') { $issues.Add('Chrome native messaging manifest has the wrong host name or transport.') }
        if (@(Compare-Object @($manifest.allowed_origins | Sort-Object -Unique) @($Plan.Origins | Sort-Object -Unique)).Count -or @($manifest.allowed_origins).Count -ne $Plan.Origins.Count) { $issues.Add('Chrome native messaging manifest has incorrect extension origins.') }
        $validBridge = $false
        if ($manifest.path -eq $Plan.Alias -and -not $Plan.Isolated) {
            # The trusted package's alias declaration maps this path to SourceBridge.
            Assert-NoReparsePath (Split-Path -Parent (Split-Path -Parent $Plan.Alias))
            $validBridge = Test-Path -LiteralPath $Plan.Alias -PathType Leaf
        }
        else { $validBridge = Test-ChromeTrustedFile $manifest.path $Plan.SourceBridge $Plan $bridgeCandidates }
        if (-not $validBridge) { $issues.Add('Chrome manifest bridge is missing, stale, or untrusted.') }
    }
    catch { $issues.Add('Chrome native messaging manifest/registry: ' + $_.Exception.Message) }
    foreach ($path in $Plan.V2Files) {
        try {
            $state = Read-ChromeJson $path
            if ($state.schemaVersion -ne 2) { throw 'Unsupported resource schema.' }
            $entries = @($state.entries | Where-Object { (Get-ChromeProperty $_ 'nativeHostNames' @()) -contains $Plan.HostName -and (Get-ChromeProperty (Get-ChromeProperty $_ 'paths') 'codexHome') -eq $Plan.CodexHome })
            $valid = $false
            foreach ($entry in $entries) {
                $missingIdentity = $false
                foreach ($name in @('channel', 'entryId', 'installId', 'updatedAt')) {
                    if ([string]::IsNullOrWhiteSpace([string](Get-ChromeProperty $entry $name))) { $missingIdentity = $true }
                }
                if ($missingIdentity -or $null -eq (Get-ChromeProperty $entry 'extensionBuildChannels')) { continue }
                if ($entry.schemaVersion -ne 2 -or $entry.nativeHostProtocolVersion -ne 2 -or $entry.appServerProtocolVersion -ne 2 -or
                    $entry.nativeHostVersion -ne $Plan.Version -or $entry.appVersion -ne $Plan.Version -or $entry.cliVersion -ne $Plan.Version -or
                    $entry.proxyHost -ne '127.0.0.1' -or $entry.proxyPort -lt 0 -or $entry.proxyPort -gt 65535) { continue }
                if (@(Compare-Object @($entry.extensionIds | Sort-Object -Unique) @($Plan.ExtensionIds | Sort-Object -Unique)).Count) { continue }
                $p = $entry.paths
                if ($p.resourcesPath -notin @($Plan.Resources, $Plan.View)) { continue }
                $moduleDirs = @(Get-ChromeProperty $p 'nodeModuleDirs' @())
                $allowedModuleDirs = @((Join-Path $Plan.Runtime 'bin\node_modules'), (Join-Path $Plan.Resources 'cua_node\bin\node_modules'), (Join-Path $Plan.View 'cua_node\bin\node_modules'))
                if (-not $moduleDirs.Count -or @($moduleDirs | Where-Object { $_ -notin $allowedModuleDirs -or -not (Test-Path -LiteralPath $_ -PathType Container) }).Count) { continue }
                foreach ($directory in $moduleDirs) {
                    if ($directory.StartsWith($Plan.Resources + '\', [StringComparison]::OrdinalIgnoreCase)) { Assert-SourcePath $directory } else { Assert-NoReparsePath $directory }
                }
                $checks = @(
                    @{ Path = $p.extensionHostPath; Source = $Plan.SourceBridge; Allowed = $bridgeCandidates },
                    @{ Path = $p.browserClientPath; Source = (Join-Path $Plan.SourceMarketplace 'plugins\chrome\scripts\browser-client.mjs'); Allowed = @((Join-Path $Plan.Latest 'scripts\browser-client.mjs')) },
                    @{ Path = $p.browserServicePath; Source = (Join-Path $Plan.SourceMarketplace 'plugins\chrome\scripts\browser-service.mjs'); Allowed = @((Join-Path $Plan.Latest 'scripts\browser-service.mjs')) }
                )
                foreach ($name in @('node', 'node_repl')) {
                    $property = if ($name -eq 'node') { 'nodePath' } else { 'nodeReplPath' }
                    $checks += @{ Path = $p.$property; Source = (Join-Path $Plan.Resources "cua_node\bin\$name.exe"); Allowed = @((Join-Path $Plan.Runtime "bin\$name.exe"), (Join-Path $Plan.Resources "cua_node\bin\$name.exe"), (Join-Path $Plan.View "cua_node\bin\$name.exe")) }
                }
                $cli = [string]$p.codexCliPath
                $allowedCli = @((Join-Path $Plan.Resources 'codex.exe'), (Join-Path $Plan.View 'codex.exe'))
                foreach ($root in @((Join-Path $Plan.CodexHome 'plugins\.plugin-appserver'), (Join-Path (Split-Path -Parent $Plan.StateRoot) 'bin'))) {
                    if ($cli.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($cli) -eq 'codex.exe') { $allowedCli += $cli }
                }
                $checks += @{ Path = $cli; Source = (Join-Path $Plan.Resources 'codex.exe'); Allowed = $allowedCli }
                $failed = $false
                foreach ($check in $checks) { if (-not (Test-ChromeTrustedFile $check.Path $check.Source $Plan $check.Allowed)) { $failed = $true; break } }
                if (-not $failed) { $valid = $true; break }
            }
            if (-not $valid) { throw 'Missing or stale trusted Chrome runtime entry.' }
        }
        catch { $issues.Add("Chrome v2 resource registration ($path): " + $_.Exception.Message) }
    }
    return [pscustomobject]@{ Status = $(if ($issues.Count) { 'NeedsRepair' } else { 'Healthy' }); Manifest = $Plan.Manifest; NativeHost = $Plan.HostName; RegistryPath = $Plan.RegistryPath; Bridge = (Join-Path $Plan.Cache $Plan.BridgeRelative); ExtensionIds = $Plan.ExtensionIds; Issues = $issues.ToArray(); Initialization = 'DesktopOwned' }
}

function Test-ChromeMarketplaceResources {
    param($Plan)
    if (-not (Test-Path -LiteralPath $Plan.Marketplace -PathType Container)) { return $false }
    if (@(Test-MarketplaceInitialization $Plan -ResourcesOnly).Count -eq 0) { return $true }
    # A damaged marker alone must not force a byte-for-byte healthy v1.2 tree
    # to be recopied. The desktop will regenerate metadata in its own stage.
    $source = Get-TreeInventory $Plan.SourceMarketplace
    $target = Get-TreeInventory $Plan.Marketplace
    $target.Remove('.materialization-key')
    if ($source.Count -ne $target.Count) { return $false }
    foreach ($key in $source.Keys) {
        if (-not $target.ContainsKey($key) -or $source[$key].Hash -ne $target[$key].Hash) { return $false }
    }
    return $true
}

function Get-ChromeViewFiles {
    param($Plan, $ResourcePlan)
    foreach ($tree in $ResourcePlan.Trees | Select-Object -First 2) {
        $prefix = if ($tree.Label -eq 'Official Computer Use runtime') { 'cua_node' } else { 'plugins\openai-bundled' }
        foreach ($file in Get-SafeTreeFiles $tree.Source) {
            $relative = Get-RelativePath $tree.Source $file.FullName
            [pscustomobject]@{ Source = $file.FullName; Relative = (Join-Path $prefix $relative); Existing = (Join-Path $tree.Target $relative) }
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $Plan.Resources -File -Filter '*.exe') {
        Assert-SourcePath $file.FullName
        [pscustomobject]@{ Source = $file.FullName; Relative = $file.Name; Existing = '' }
    }
}

function Repair-MarketplaceInitialization {
    param($Plan, $ResourcePlan, [string]$Timestamp)
    # A verified decrypted source view lets the DESKTOP generate feature-dependent
    # materialization metadata. We never synthesize a guessed feature profile.
    $files = @(Get-ChromeViewFiles $Plan $ResourcePlan)
    Assert-PathWithin $Plan.View $Plan.StateRoot
    $healthy = Test-Path -LiteralPath $Plan.View -PathType Container
    foreach ($file in $files) {
        $target = Join-Path $Plan.View $file.Relative
        Assert-NoReparsePath $target
        if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $file.Source).Hash) { $healthy = $false; break }
    }
    if ($healthy -and @(Get-SafeTreeFiles $Plan.View).Count -eq $files.Count) { return }
    $parent = Split-Path -Parent $Plan.View
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $stage = Join-Path $parent ('.staging-chrome-' + [Guid]::NewGuid().ToString('N'))
    Assert-PathWithin $stage $parent
    New-Item -ItemType Directory -Path $stage | Out-Null
    Write-Host "Preparing verified Chrome initialization resources: $($files.Count) files..."
    $prepared = 0
    foreach ($file in $files) {
        $target = Join-Path $stage $file.Relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        $linked = $false
        if ($file.Existing -and (Test-Path -LiteralPath $file.Existing -PathType Leaf)) {
            Assert-NoReparsePath $file.Existing
            if ((Get-FileHash -LiteralPath $file.Existing).Hash -eq (Get-FileHash -LiteralPath $file.Source).Hash) {
                try { New-Item -ItemType HardLink -Path $target -Target $file.Existing -ErrorAction Stop | Out-Null; $linked = $true } catch { $linked = $false }
            }
        }
        if (-not $linked) {
            # Same byte-stream primitive as resource restoration; never Copy-Item
            # from WindowsApps. Hard links above reuse already verified bytes.
            $input = [IO.File]::OpenRead($file.Source)
            try { $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write); try { $input.CopyTo($output) } finally { $output.Dispose() } }
            finally { $input.Dispose() }
        }
        if ((Get-FileHash -LiteralPath $target).Hash -ne (Get-FileHash -LiteralPath $file.Source).Hash) { throw "Chrome initialization view verification failed; retained: $stage" }
        $prepared++
        if ($prepared % 500 -eq 0) { Write-Host "Chrome initialization resources: verified $prepared/$($files.Count) files..." }
    }
    & $script:RepairGuard
    $backup = Move-ExistingToBackup $Plan.View $parent $Timestamp
    if ($backup) { $script:RepairBackups.Add($backup) }
    try { & $script:RepairGuard; Move-RepairDirectory $stage $Plan.View $parent }
    catch { if ($backup -and -not (Test-Path -LiteralPath $Plan.View)) { [IO.Directory]::Move($backup, $Plan.View) }; throw }
}

function Backup-ChromeIntegration {
    param($Plan, [string]$Timestamp)
    $backup = Join-Path $Plan.StateRoot ('chrome.before-computer-use-repair-' + $Timestamp + '-' + [Guid]::NewGuid().ToString('N'))
    Assert-PathWithin $backup $Plan.StateRoot
    New-Item -ItemType Directory -Path $backup | Out-Null
    $records = @()
    foreach ($file in @($Plan.Manifest) + $Plan.V2Files + @($Plan.Marker, (Join-Path $Plan.Marketplace '.agents\plugins\marketplace.json'))) {
        Assert-NoReparsePath $file
        $exists = Test-Path -LiteralPath $file -PathType Leaf
        $saved = Join-Path $backup ($records.Count.ToString() + '.bin')
        if ($exists) { [IO.File]::WriteAllBytes($saved, [IO.File]::ReadAllBytes($file)) }
        $records += [pscustomobject]@{ Path = $file; Existed = $exists; Saved = $saved; Hash = $(if ($exists) { (Get-FileHash -LiteralPath $saved).Hash } else { '' }) }
    }
    $snapshot = [ordered]@{ Schema = 1; RegistryPath = $Plan.RegistryPath; Registry = (Get-ChromeRegistryState $Plan); Files = $records; Latest = (Get-ChromeLatestTarget $Plan); CodexHome = $Plan.CodexHome }
    Write-RepairJson (Join-Path $backup 'snapshot.json') $snapshot
    $script:RepairBackups.Add($backup)
    return $backup
}

function Start-ChromeDesktopInitialization {
    param($Plan)
    if ($Plan.Isolated) { throw 'DEFERRED: Isolated validation never launches the desktop or writes the live registry. Use the test initializer.' }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Plan.Desktop
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.EnvironmentVariables[$Plan.Contract.LaunchEnvironment] = $Plan.View
    $start.EnvironmentVariables['CODEX_HOME'] = $Plan.CodexHome
    $process = [Diagnostics.Process]::Start($start)
    if ($null -eq $process) { throw 'Could not start the trusted desktop initializer.' }
    $process.Dispose()
}

function Repair-ChromeNativeMessaging {
    param($Plan, $ResourcePlan, [string]$Timestamp, [switch]$InitializeChrome, [int]$InitializationSeconds = 120)
    $before = Test-ChromeNativeMessaging $Plan
    if ($before.Status -eq 'Healthy') { return $before }
    Assert-ChromeWriteTargets $Plan
    Repair-MarketplaceInitialization $Plan $ResourcePlan $Timestamp
    if (-not $InitializeChrome) { throw 'DEFERRED: Chrome initialization prerequisites are ready. Fully quit Codex, then run repair-codex-computer-use.ps1 -InitializeChrome to let the trusted desktop generate its marketplace and Native Messaging state. No live registry was written by this tool.' }
    & $script:RepairGuard
    $backup = Backup-ChromeIntegration $Plan $Timestamp
    # Only the official app writes registrations. No guessed legacy installManifest
    # invocation, no persistent environment setting, and no background repair job.
    try { Start-ChromeDesktopInitialization $Plan }
    catch {
        $launchError = $_
        try { & $script:RepairGuard; Restore-ChromeIntegration $Plan $backup } catch { Write-Warning "Automatic Chrome rollback could not complete: $($_.Exception.Message). Backup: $backup" }
        throw $launchError
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $result = Test-ChromeNativeMessaging $Plan
        if ($result.Status -eq 'Healthy') {
            if (-not $Plan.Isolated) {
                $current = Resolve-CodexPackageRoot ''
                if ($current.Root -ne $script:VerifiedSourceRoot) { throw 'DEFERRED: The installed package changed during desktop initialization; run a fresh check.' }
            }
            return $result
        }
        if ($timer.Elapsed.TotalSeconds -ge $InitializationSeconds) { break }
        Start-Sleep -Milliseconds 1000
    } while ($true)
    throw "DEFERRED: Desktop initialization did not validate within $InitializationSeconds seconds. No processes were killed. Review ChromeIntegration diagnostics; previous registration/metadata are backed up at $backup. Do not claim the connection is repaired."
}

function Restore-ChromeIntegration {
    param($Plan, [string]$Backup)
    Assert-PathWithin $Backup $Plan.StateRoot
    $snapshot = Read-ChromeJson (Join-Path $Backup 'snapshot.json')
    if ($snapshot.Schema -ne 1 -or $snapshot.RegistryPath -cne $Plan.RegistryPath -or $snapshot.CodexHome -ne $Plan.CodexHome) { throw 'Backup belongs to a different integration.' }
    $allowed = @($Plan.Manifest) + $Plan.V2Files + @($Plan.Marker, (Join-Path $Plan.Marketplace '.agents\plugins\marketplace.json'))
    if (@($snapshot.Files).Count -ne $allowed.Count) { throw 'Incomplete integration backup.' }
    $seen = @{}
    foreach ($file in $snapshot.Files) {
        if ($allowed -notcontains $file.Path -or $seen.ContainsKey($file.Path)) { throw 'Unexpected backup destination.' }
        $seen[$file.Path] = $true
        Assert-NoReparsePath $file.Path
        Assert-PathWithin $file.Saved $Backup
        Assert-NoReparsePath $file.Saved
        if ($file.Existed -and (Get-FileHash -LiteralPath $file.Saved).Hash -ne $file.Hash) { throw 'Integration backup hash mismatch.' }
    }
    $currentLatest = Get-ChromeLatestTarget $Plan
    if ($snapshot.Latest) {
        if ((Split-Path -Parent $snapshot.Latest) -ne (Split-Path -Parent $Plan.Cache) -or (Split-Path -Leaf $snapshot.Latest) -notmatch '^\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9.-]+)?$') { throw 'Unsafe saved latest target.' }
        Assert-NoReparsePath $snapshot.Latest
    }
    if ($snapshot.Registry.Kind -notin @('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord', 'None')) { throw 'Invalid saved registry value type.' }
    $registryValue = $snapshot.Registry.Value
    if ($snapshot.Registry.ValueExists) {
        switch ($snapshot.Registry.Kind) {
            'Binary' { $registryValue = [byte[]]$registryValue }
            'None' { $registryValue = [byte[]]$registryValue }
            'DWord' { $registryValue = [int]$registryValue }
            'QWord' { $registryValue = [long]$registryValue }
            'MultiString' { $registryValue = [string[]]$registryValue }
            default { $registryValue = [string]$registryValue }
        }
    }
    & $script:RepairGuard
    foreach ($file in $snapshot.Files) {
        if ($file.Existed) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $file.Path) -Force | Out-Null
            $temp = $file.Path + '.restore-' + [Guid]::NewGuid().ToString('N')
            [IO.File]::WriteAllBytes($temp, [IO.File]::ReadAllBytes($file.Saved))
            if (Test-Path -LiteralPath $file.Path) { [IO.File]::Replace($temp, $file.Path, [NullString]::Value) } else { [IO.File]::Move($temp, $file.Path) }
        }
        elseif (Test-Path -LiteralPath $file.Path -PathType Leaf) { Remove-Item -LiteralPath $file.Path }
    }
    if ($Plan.Isolated) { Write-RepairJson $Plan.RegistryFile $snapshot.Registry }
    else {
        # Rollback is the only registry write in this tool. The initializer is
        # desktop-owned. Restore only its exact HKCU default value, not siblings.
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Plan.RegistrySubKey, $true)
        try {
            if ($snapshot.Registry.KeyExists -and $null -eq $key) { $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Plan.RegistrySubKey) }
            if ($null -ne $key) {
                if ($snapshot.Registry.ValueExists) { $key.SetValue('', $registryValue, [Enum]::Parse([Microsoft.Win32.RegistryValueKind], $snapshot.Registry.Kind)) }
                else { $key.DeleteValue('', $false) }
            }
            $empty = $null -ne $key -and $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0
        }
        finally { if ($null -ne $key) { $key.Dispose() } }
        if (-not $snapshot.Registry.KeyExists -and $empty) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($Plan.RegistrySubKey, $false) }
    }
    if ($currentLatest -ne $snapshot.Latest) {
        # Delete only the already validated junction itself; never its contents.
        if ($currentLatest) { [IO.Directory]::Delete($Plan.Latest) }
        if ($snapshot.Latest) { New-Item -ItemType Junction -Path $Plan.Latest -Target $snapshot.Latest | Out-Null }
    }
}
