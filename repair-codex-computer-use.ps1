#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$PackageRoot = '',
    [string]$TestRoot = '',
    [switch]$SkipProcessCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-FullPath {
    param([string]$Path)
    return [IO.Path]::GetFullPath($Path)
}

function Get-RelativePath {
    param(
        [string]$BasePath,
        [string]$ChildPath
    )

    $baseFull = (Get-FullPath $BasePath).TrimEnd('\') + '\'
    $childFull = Get-FullPath $ChildPath
    if (-not $childFull.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the expected source tree: $childFull"
    }
    return $childFull.Substring($baseFull.Length)
}

function Assert-PathWithin {
    param(
        [string]$Path,
        [string]$Parent
    )

    $parentFull = (Get-FullPath $Parent).TrimEnd('\') + '\'
    $pathFull = Get-FullPath $Path
    if (-not $pathFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside the intended repair directory: $pathFull"
    }
}

function Get-TreeStats {
    param([string]$Root)

    $files = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force)
    $measure = $files | Measure-Object -Property Length -Sum
    $byteCount = if ($null -eq $measure.Sum) { 0 } else { $measure.Sum }
    [pscustomobject]@{
        Count = $files.Count
        Bytes = [int64]$byteCount
    }
}

function Test-KeyFilesMatch {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$KeyRelativePaths
    )

    foreach ($relativePath in $KeyRelativePaths) {
        $sourceFile = Join-Path $Source $relativePath
        $destinationFile = Join-Path $Destination $relativePath
        if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf) -or
            -not (Test-Path -LiteralPath $destinationFile -PathType Leaf)) {
            return $false
        }

        $sourceHash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destinationFile -Algorithm SHA256).Hash
        if ($sourceHash -ne $destinationHash) {
            return $false
        }
    }

    return $true
}

function Test-TreeMatches {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$KeyRelativePaths
    )

    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        return $false
    }

    $sourceStats = Get-TreeStats $Source
    $destinationStats = Get-TreeStats $Destination
    if ($sourceStats.Count -ne $destinationStats.Count -or $sourceStats.Bytes -ne $destinationStats.Bytes) {
        return $false
    }

    foreach ($sourceFile in @(Get-ChildItem -LiteralPath $Source -File -Recurse -Force)) {
        $relativePath = Get-RelativePath -BasePath $Source -ChildPath $sourceFile.FullName
        $destinationFile = Join-Path $Destination $relativePath
        if (-not (Test-Path -LiteralPath $destinationFile -PathType Leaf)) {
            return $false
        }
        if ((Get-Item -LiteralPath $destinationFile -Force).Length -ne $sourceFile.Length) {
            return $false
        }
    }

    return Test-KeyFilesMatch -Source $Source -Destination $Destination -KeyRelativePaths $KeyRelativePaths
}

function Move-ExistingToBackup {
    param(
        [string]$Path,
        [string]$AllowedParent,
        [string]$Timestamp
    )

    Assert-PathWithin -Path $Path -Parent $AllowedParent
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $backup = "$Path.before-computer-use-repair-$Timestamp"
    if (Test-Path -LiteralPath $backup) {
        $backup = "$backup-$([Guid]::NewGuid().ToString('N'))"
    }
    Assert-PathWithin -Path $backup -Parent $AllowedParent
    [IO.Directory]::Move($Path, $backup)
    return $backup
}

function Copy-TreeByDecryptedStream {
    param(
        [string]$Source,
        [string]$Final,
        [string]$AllowedParent,
        [string]$Label,
        [string[]]$KeyRelativePaths,
        [string]$Timestamp
    )

    Assert-PathWithin -Path $Final -Parent $AllowedParent
    if (Test-TreeMatches -Source $Source -Destination $Final -KeyRelativePaths $KeyRelativePaths) {
        Write-Host "$Label is already complete; structure and key hashes verified."
        return
    }

    New-Item -ItemType Directory -Path $AllowedParent -Force | Out-Null
    $backup = $null
    if (Test-Path -LiteralPath $Final) {
        $backup = Move-ExistingToBackup -Path $Final -AllowedParent $AllowedParent -Timestamp $Timestamp
        Write-Host "$Label existing directory moved to: $backup"
    }

    $stage = Join-Path $AllowedParent ('.staging-' + (Split-Path -Leaf $Final) + '-' + [Guid]::NewGuid().ToString('N'))
    try {
        Assert-PathWithin -Path $stage -Parent $AllowedParent
        New-Item -ItemType Directory -Path $stage | Out-Null

        $directories = @(Get-ChildItem -LiteralPath $Source -Directory -Recurse -Force)
        foreach ($directory in $directories) {
            $relativePath = Get-RelativePath -BasePath $Source -ChildPath $directory.FullName
            New-Item -ItemType Directory -Path (Join-Path $stage $relativePath) -Force | Out-Null
        }

        $files = @(Get-ChildItem -LiteralPath $Source -File -Recurse -Force)
        $copied = 0
        foreach ($file in $files) {
            $relativePath = Get-RelativePath -BasePath $Source -ChildPath $file.FullName
            $destination = Join-Path $stage $relativePath
            $destinationDirectory = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $destinationDirectory)) {
                New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
            }

            $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $inputStream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
            try {
                $outputStream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $inputStream.CopyTo($outputStream, 1048576)
                }
                finally {
                    $outputStream.Dispose()
                }
            }
            finally {
                $inputStream.Dispose()
            }

            $copied++
            if (($copied % 500) -eq 0) {
                Write-Host "${Label}: copied $copied/$($files.Count) files..."
            }
        }

        if (-not (Test-TreeMatches -Source $Source -Destination $stage -KeyRelativePaths $KeyRelativePaths)) {
            throw "$Label verification failed; staging directory retained at $stage"
        }

        [IO.Directory]::Move($stage, $Final)
        $stats = Get-TreeStats $Final
        Write-Host "$Label restored; structure and key hashes verified: $($stats.Count) files, $($stats.Bytes) bytes."
    }
    catch {
        if ($backup -and -not (Test-Path -LiteralPath $Final) -and (Test-Path -LiteralPath $backup)) {
            [IO.Directory]::Move($backup, $Final)
            Write-Warning "$Label did not complete. The previous directory was restored automatically. Staging directory: $stage"
        }
        else {
            Write-Warning "$Label did not complete. No existing backup was deleted. Staging directory: $stage"
        }
        throw
    }
}

function Get-RuntimeDirectoryHash {
    param([string]$RuntimeSource)

    $items = @(
        @{ Name = 'manifest.json'; Path = (Join-Path $RuntimeSource 'manifest.json') },
        @{ Name = 'bin/node.exe'; Path = (Join-Path $RuntimeSource 'bin\node.exe') },
        @{ Name = 'bin/node_repl.exe'; Path = (Join-Path $RuntimeSource 'bin\node_repl.exe') }
    )

    $memory = New-Object IO.MemoryStream
    try {
        foreach ($item in $items) {
            $nameBytes = [Text.Encoding]::UTF8.GetBytes($item.Name)
            $memory.Write($nameBytes, 0, $nameBytes.Length)
            $memory.WriteByte(0)
            $digest = (Get-FileHash -LiteralPath $item.Path -Algorithm SHA256).Hash.ToLowerInvariant()
            $digestBytes = [Text.Encoding]::UTF8.GetBytes($digest)
            $memory.Write($digestBytes, 0, $digestBytes.Length)
            $memory.WriteByte(0)
        }
        $memory.Position = 0
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = ([BitConverter]::ToString($sha.ComputeHash($memory))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
        }
    }
    finally {
        $memory.Dispose()
    }
    return $hash.Substring(0, 16)
}

function Resolve-CodexPackageRoot {
    param([string]$ExplicitRoot)

    if ($ExplicitRoot) {
        return Get-FullPath $ExplicitRoot
    }

    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PackageFamilyName -eq 'OpenAI.Codex_2p2nqsd0c76g0' -and
            $_.PublisherId -eq '2p2nqsd0c76g0' -and
            [string]$_.SignatureKind -eq 'Store' -and
            [string]$_.Status -eq 'Ok'
        } |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -ne $package -and $package.InstallLocation) {
        return Get-FullPath $package.InstallLocation
    }

    throw 'Could not locate a healthy Microsoft Store package with identity OpenAI.Codex_2p2nqsd0c76g0.'
}

function Remove-ManagedTomlSections {
    param(
        [string]$Content,
        [string[]]$SectionNames
    )

    $managed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($sectionName in $SectionNames) {
        $null = $managed.Add($sectionName)
    }

    $result = [Collections.Generic.List[string]]::new()
    $skip = $false
    foreach ($line in [regex]::Split($Content, '\r?\n')) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') {
            $skip = $managed.Contains($Matches[1])
        }
        if (-not $skip) {
            $result.Add($line)
        }
    }

    while ($result.Count -gt 0 -and [string]::IsNullOrWhiteSpace($result[$result.Count - 1])) {
        $result.RemoveAt($result.Count - 1)
    }
    return ($result -join "`r`n")
}

function Update-CodexConfig {
    param(
        [string]$CodexHome,
        [string]$MarketplacePath,
        [string]$Timestamp
    )

    New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null
    $configPath = Join-Path $CodexHome 'config.toml'
    $content = if (Test-Path -LiteralPath $configPath) {
        [IO.File]::ReadAllText($configPath)
    }
    else {
        ''
    }

    $hasExistingConfig = Test-Path -LiteralPath $configPath
    $backupPath = $null
    if ($hasExistingConfig) {
        $backupPath = Join-Path $CodexHome "config.toml.before-computer-use-repair-$Timestamp"
        if (Test-Path -LiteralPath $backupPath) {
            $backupPath = "$backupPath-$([Guid]::NewGuid().ToString('N'))"
        }
    }

    $managedSections = @(
        'marketplaces.openai-bundled',
        'plugins."browser@openai-bundled"',
        'plugins."chrome@openai-bundled"',
        'plugins."computer-use@openai-bundled"'
    )
    $content = Remove-ManagedTomlSections -Content $content -SectionNames $managedSections
    $marketplaceToml = $MarketplacePath.Replace('\', '\\').Replace('"', '\"')
    $updated = @(
        $content,
        '',
        '[marketplaces.openai-bundled]',
        "last_updated = `"$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))`"",
        'source_type = "local"',
        "source = `"$marketplaceToml`"",
        '',
        '[plugins."browser@openai-bundled"]',
        'enabled = true',
        '',
        '[plugins."chrome@openai-bundled"]',
        'enabled = true',
        '',
        '[plugins."computer-use@openai-bundled"]',
        'enabled = true',
        ''
    ) -join "`r`n"

    $encoding = New-Object Text.UTF8Encoding($false)
    $stagedConfigPath = "$configPath.staging-$([Guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($stagedConfigPath, $updated, $encoding)
    if ($hasExistingConfig) {
        [IO.File]::Replace($stagedConfigPath, $configPath, $backupPath)
        Write-Host "Configuration backup: $backupPath"
    }
    else {
        [IO.File]::Move($stagedConfigPath, $configPath)
    }
    Write-Host "Configuration updated: $configPath"
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if ($PackageRoot -and -not $TestRoot) {
    throw '-PackageRoot is restricted to isolated -TestRoot validation runs.'
}

if (-not $SkipProcessCheck -and -not $TestRoot) {
    $running = @(Get-Process -Name 'Codex' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        throw 'Codex is still running. Fully quit it from the system tray, then run this repair again.'
    }
}

Write-Step 'Locating the signed Codex package'
$resolvedPackageRoot = Resolve-CodexPackageRoot -ExplicitRoot $PackageRoot
$runtimeSource = Join-Path $resolvedPackageRoot 'app\resources\cua_node'
$marketplaceSource = Join-Path $resolvedPackageRoot 'app\resources\plugins\openai-bundled'
if (-not (Test-Path -LiteralPath (Join-Path $runtimeSource 'bin\node_repl.exe') -PathType Leaf)) {
    throw "The package does not contain cua_node/node_repl: $resolvedPackageRoot"
}
if (-not (Test-Path -LiteralPath (Join-Path $marketplaceSource '.agents\plugins\marketplace.json') -PathType Leaf)) {
    throw "The package does not contain the openai-bundled marketplace: $resolvedPackageRoot"
}
Write-Host "Package: $resolvedPackageRoot"

if ($TestRoot) {
    $testRootFull = Get-FullPath $TestRoot
    $codexHome = Join-Path $testRootFull '.codex'
    $localCodexRoot = Join-Path $testRootFull 'LocalAppData\OpenAI\Codex'
}
else {
    $codexHome = Join-Path $env:USERPROFILE '.codex'
    $localCodexRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'
}

$runtimeHash = Get-RuntimeDirectoryHash -RuntimeSource $runtimeSource
$runtimeParent = Join-Path $localCodexRoot 'runtimes\cua_node'
$runtimeTarget = Join-Path $runtimeParent $runtimeHash
$marketplaceParent = Join-Path $codexHome '.tmp\bundled-marketplaces'
$marketplaceTarget = Join-Path $marketplaceParent 'openai-bundled'

Write-Step 'Restoring the official cua_node runtime through decrypted byte streams'
$runtimeKeys = @(
    'manifest.json',
    'bin\node.exe',
    'bin\node_repl.exe',
    'bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe',
    'bin\node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js'
)
Copy-TreeByDecryptedStream `
    -Source $runtimeSource `
    -Final $runtimeTarget `
    -AllowedParent $runtimeParent `
    -Label 'Official Computer Use runtime' `
    -KeyRelativePaths $runtimeKeys `
    -Timestamp $timestamp

Write-Step 'Restoring the official bundled plugin marketplace'
$marketplaceKeys = @(
    '.agents\plugins\marketplace.json',
    'plugins\browser\.codex-plugin\plugin.json',
    'plugins\browser\scripts\browser-client.mjs',
    'plugins\chrome\.codex-plugin\plugin.json',
    'plugins\computer-use\.codex-plugin\plugin.json',
    'plugins\computer-use\scripts\computer-use-client.mjs'
)
Copy-TreeByDecryptedStream `
    -Source $marketplaceSource `
    -Final $marketplaceTarget `
    -AllowedParent $marketplaceParent `
    -Label 'OpenAI bundled marketplace' `
    -KeyRelativePaths $marketplaceKeys `
    -Timestamp $timestamp

Write-Step 'Priming Browser, Chrome, and Computer Use plugin caches'
$cacheRoot = Join-Path $codexHome 'plugins\cache\openai-bundled'
foreach ($pluginName in @('browser', 'chrome', 'computer-use')) {
    $pluginSource = Join-Path $marketplaceTarget "plugins\$pluginName"
    $manifestPath = Join-Path $pluginSource '.codex-plugin\plugin.json'
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    $pluginParent = Join-Path $cacheRoot $pluginName
    $pluginTarget = Join-Path $pluginParent ([string]$manifest.version)
    Copy-TreeByDecryptedStream `
        -Source $pluginSource `
        -Final $pluginTarget `
        -AllowedParent $pluginParent `
        -Label "Plugin cache: $pluginName" `
        -KeyRelativePaths @('.codex-plugin\plugin.json') `
        -Timestamp $timestamp
}

Write-Step 'Backing up and updating Codex plugin configuration'
Update-CodexConfig -CodexHome $codexHome -MarketplacePath $marketplaceTarget -Timestamp $timestamp

Write-Step 'Final verification'
$coreFiles = @(
    'bin\node_repl.exe',
    'bin\node.exe',
    'bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe'
)
foreach ($relativePath in $coreFiles) {
    $sourceHash = (Get-FileHash -LiteralPath (Join-Path $runtimeSource $relativePath) -Algorithm SHA256).Hash
    $targetHash = (Get-FileHash -LiteralPath (Join-Path $runtimeTarget $relativePath) -Algorithm SHA256).Hash
    if ($sourceHash -ne $targetHash) {
        throw "Final hash mismatch: $relativePath"
    }
}
$nodeVersion = (& (Join-Path $runtimeTarget 'bin\node.exe') --version 2>&1 | Out-String).Trim()

Write-Host "Runtime target: $runtimeTarget"
Write-Host "Marketplace target: $marketplaceTarget"
Write-Host "Node runtime: $nodeVersion"
Write-Host ''
Write-Host 'Repair completed successfully.' -ForegroundColor Green
Write-Host 'Reopen Codex, start a new task, and test Computer Use with list_apps/list_windows.'
Write-Host 'If the app still reports unavailable, keep the backup paths printed above and share the newest Codex log.'
