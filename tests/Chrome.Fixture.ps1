# Only synthetic test data and an injectable official-initializer boundary.
function Add-ChromeFixture {
    param([string]$Fixture)
    $source = Join-Path $Fixture 'app\resources\plugins\openai-bundled'
    Put (Join-Path $source '.bundle-id') 'fixture-bundle'
    $plugins = @('browser','chrome','computer-use') | ForEach-Object { @{ name = $_; source = @{ source = 'local'; path = "./plugins/$_" } } }
    Put (Join-Path $source '.agents\plugins\marketplace.json') (@{ name = 'openai-bundled'; plugins = @($plugins) } | ConvertTo-Json -Depth 10)
    Put (Join-Path $source 'plugins\chrome\scripts\extension-ids.json') (@{ extensionHostName = 'org.example.fixture'; extensionIds = @('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'); windowsNativeMessaging = @{ registryRoot = 'HKCU\Software\Google\Chrome\NativeMessagingHosts'; manifestDirectory = 'AppData/Local/OpenAI/extension' } } | ConvertTo-Json -Depth 10)
    foreach ($file in @('scripts\browser-client.mjs','scripts\browser-service.mjs','extension-host\windows\x64\extension-host.exe')) { Put (Join-Path $source "plugins\chrome\$file") 'fixture chrome bytes' }
    Put (Join-Path $Fixture 'app\resources\codex.exe') 'fixture cli bytes'
    Put (Join-Path $Fixture 'app\ChatGPT.exe') 'fixture desktop bytes'
    Put (Join-Path $Fixture 'app\resources\app.asar') 'synthetic recognized contract'
    Put (Join-Path $Fixture 'AppxManifest.xml') '<Package><Applications><Application Id="App" Executable="app\ChatGPT.exe"><Extensions><Extension Category="windows.appExecutionAlias" Executable="app\resources\plugins\openai-bundled\plugins\chrome\extension-host\windows\x64\extension-host.exe"><AppExecutionAlias><ExecutionAlias Alias="fixture-native-host.exe" /></AppExecutionAlias></Extension></Extensions></Application></Applications></Package>'
}
function Read-ChromeAsarContract {
    param([string]$Path)
    if ([IO.File]::ReadAllText($Path) -ne 'synthetic recognized contract') { throw 'Unsupported fixture layout.' }
    return [pscustomobject]@{ AppVersion = '1.0.0'; Schema = 2; ResourceFile = 'chrome-native-hosts-v2.json'; LaunchEnvironment = 'FIXTURE_ONLY' }
}
function Start-ChromeDesktopInitialization {
    param($Plan)
    if (-not $Plan.Isolated) { throw 'Tests may not initialize a live profile.' }
    if (Test-Path -LiteralPath $Plan.Latest) {
        $item = Get-Item -LiteralPath $Plan.Latest -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($Plan.Latest) }
        else { throw 'Unexpected fixture latest directory.' }
    }
    New-Item -ItemType Junction -Path $Plan.Latest -Target $Plan.Cache | Out-Null
    $sourceManifest = Read-ChromeJson (Join-Path $Plan.SourceMarketplace '.agents\plugins\marketplace.json') -Trusted
    $key = [ordered]@{ version=1; appVersion=$Plan.Contract.AppVersion; bundleId='fixture-bundle'; marketplaceName='openai-bundled'; computerUseAudioEnabled=$false; liveVisualizationSkillVariant=$null; visualizeTreatment=$false; plugins=@($sourceManifest.plugins | ForEach-Object { @{name=$_.name; version=(Read-ChromeJson (Join-Path $Plan.SourceMarketplace ($_.source.path + '/.codex-plugin/plugin.json')) -Trusted).version} }) }
    Write-RepairJson $Plan.Marker $key
    $bridge = Join-Path $Plan.Cache $Plan.BridgeRelative
    New-Item -ItemType Directory -Path (Split-Path -Parent $Plan.Manifest) -Force | Out-Null
    Write-RepairJson $Plan.Manifest @{name=$Plan.HostName;path=$bridge;type='stdio';allowed_origins=$Plan.Origins}
    Write-RepairJson $Plan.RegistryFile @{KeyExists=$true;ValueExists=$true;Value=$Plan.Manifest;Kind='String'}
    $entry = @{channel='fixture';entryId='fixture-entry';installId='fixture-install';updatedAt='2026-10-03T00:00:00Z';extensionBuildChannels=@('fixture');schemaVersion=2;appServerProtocolVersion=2;nativeHostProtocolVersion=2;appVersion=$Plan.Version;cliVersion=$Plan.Version;nativeHostVersion=$Plan.Version;proxyHost='127.0.0.1';proxyPort=0;nativeHostNames=@($Plan.HostName);extensionIds=$Plan.ExtensionIds;paths=@{nodeModuleDirs=@((Join-Path $Plan.Runtime 'bin\node_modules'));codexHome=$Plan.CodexHome;resourcesPath=$Plan.Resources;extensionHostPath=$bridge;browserClientPath=(Join-Path $Plan.Latest 'scripts\browser-client.mjs');browserServicePath=(Join-Path $Plan.Latest 'scripts\browser-service.mjs');nodePath=(Join-Path $Plan.Runtime 'bin\node.exe');nodeReplPath=(Join-Path $Plan.Runtime 'bin\node_repl.exe');codexCliPath=(Join-Path $Plan.Resources 'codex.exe')}}
    foreach ($path in $Plan.V2Files) { Write-RepairJson $path @{schemaVersion=2;entries=@($entry)} }
}
