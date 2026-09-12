#Requires -Version 5.1
# Shared implementation; dot-source from the supported entry points.
Set-StrictMode -Version Latest
$script:VerifiedSourceRoot = ''
$script:SourceInventories = @{}

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
    Assert-NoReparsePath $pathFull
}

function Assert-NoReparsePath {
    param([string]$Path)
    $current = Get-FullPath $Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse points are not supported in repair paths: $current"
            }
        }
        $current = Split-Path -Parent $current
    }
}

function Assert-SourcePath {
    param([string]$Path)
    $anchor = $script:VerifiedSourceRoot.TrimEnd('\')
    $current = Get-FullPath $Path
    if (-not $anchor -or -not $current.StartsWith($anchor + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Source is outside the verified package: $current"
    }
    # Store may place the registered package itself on another volume via a
    # junction. Trust that registered root only, never links inside resources.
    while ($current -ne $anchor) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point inside package resources: $current" }
        }
        $current = Split-Path -Parent $current
    }
}

function Get-SafeTreeFiles {
    param([string]$Root)
    if ($script:VerifiedSourceRoot -and (Get-FullPath $Root).StartsWith($script:VerifiedSourceRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { Assert-SourcePath $Root }
    else { Assert-NoReparsePath $Root }
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($Root)
    while ($pending.Count) {
        foreach ($entry in [IO.DirectoryInfo]::new($pending.Dequeue()).EnumerateFileSystemInfos()) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse point found in resource tree: $($entry.FullName)"
            }
            if ($entry -is [IO.DirectoryInfo]) { $pending.Enqueue($entry.FullName) }
            else { $entry }
        }
    }
}

function Get-CachedFileHash {
    param([IO.FileInfo]$File)
    $key = $File.FullName
    $stamp = "$($File.Length):$($File.LastWriteTimeUtc.Ticks)"
    $cached = $script:HashCache[$key]
    $current = $script:NextHashCache[$key]
    if ($current -and $current.Stamp -eq $stamp) { return $current.Hash }
    if (-not $script:FullHashCheck -and $cached -and $cached.Stamp -eq $stamp) {
        $hash = $cached.Hash
    }
    else { $hash = (Get-FileHash -LiteralPath $key -Algorithm SHA256).Hash }
    $script:NextHashCache[$key] = @{ Stamp = $stamp; Hash = $hash }
    return $hash
}

function Get-TreeInventory {
    param([string]$Root)
    $prefix = (Get-FullPath $Root).TrimEnd('\') + '\'
    $isSource = $script:VerifiedSourceRoot -and $prefix.StartsWith($script:VerifiedSourceRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
    if ($isSource -and $script:SourceInventories.ContainsKey($prefix)) { return $script:SourceInventories[$prefix] }
    $inventory = @{}
    foreach ($file in Get-SafeTreeFiles $Root) {
        $relative = $file.FullName.Substring($prefix.Length)
        $inventory[$relative] = @{ Length = $file.Length; Hash = (Get-CachedFileHash $file) }
    }
    if ($isSource) { $script:SourceInventories[$prefix] = $inventory }
    return $inventory
}

function Get-TreeStats {
    param([string]$Root)

    $files = @(Get-SafeTreeFiles $Root)
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
            Write-Warning "Verification key is missing: $relativePath"
            return $false
        }

        $sourceHash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destinationFile -Algorithm SHA256).Hash
        if ($sourceHash -ne $destinationHash) {
            Write-Warning "Verification key hash mismatch: $relativePath"
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

    $sourceInventory = Get-TreeInventory $Source
    $destinationInventory = Get-TreeInventory $Destination
    if ($sourceInventory.Count -ne $destinationInventory.Count) {
        Write-Warning "Tree file count mismatch: $Destination"
        return $false
    }
    foreach ($relativePath in $sourceInventory.Keys) {
        $destinationFile = $destinationInventory[$relativePath]
        if (-not $destinationFile -or
            $destinationFile.Length -ne $sourceInventory[$relativePath].Length -or
            $destinationFile.Hash -ne $sourceInventory[$relativePath].Hash) {
            Write-Warning "Destination file missing or changed: $relativePath"
            return $false
        }
    }

    return Test-KeyFilesMatch -Source $Source -Destination $Destination -KeyRelativePaths $KeyRelativePaths
}

function Move-RepairDirectory {
    param([string]$Source, [string]$Destination, [string]$AllowedParent)
    Assert-PathWithin $Source $AllowedParent
    Assert-PathWithin $Destination $AllowedParent
    for ($attempt = 0; $attempt -lt 11; $attempt++) {
        if ($attempt) { & $script:RepairGuard }
        try { [IO.Directory]::Move($Source, $Destination); return }
        catch {
            $failure = $_.Exception
            while ($failure.InnerException) { $failure = $failure.InnerException }
            $win32 = $failure.HResult -band 0xffff
            # Antivirus/indexing can briefly hold a freshly verified staging
            # directory. Retry for at most one second, never bypass app checks.
            if ($attempt -eq 10 -or $win32 -notin @(5, 32, 33) -or
                -not (Test-Path -LiteralPath $Source -PathType Container) -or
                (Test-Path -LiteralPath $Destination)) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
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
    Move-RepairDirectory $Path $backup $AllowedParent
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

    $stage = Join-Path $AllowedParent ('.staging-' + (Split-Path -Leaf $Final) + '-' + [Guid]::NewGuid().ToString('N'))
    try {
        Assert-PathWithin -Path $stage -Parent $AllowedParent
        New-Item -ItemType Directory -Path $stage | Out-Null

        $files = @(Get-SafeTreeFiles $Source)
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

        # Keep the live tree in place throughout copying and verification.
        & $script:RepairGuard
        if (Test-Path -LiteralPath $Final) {
            $backup = Move-ExistingToBackup -Path $Final -AllowedParent $AllowedParent -Timestamp $Timestamp
            Write-Host "$Label existing directory moved to: $backup"
            $script:RepairBackups.Add($backup)
        }
        & $script:RepairGuard
        Move-RepairDirectory $stage $Final $AllowedParent
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
        return [pscustomobject]@{ Root = (Get-FullPath $ExplicitRoot); Identity = 'isolated-fixture'; Version = 'test'; Family = 'test' }
    }

    $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PackageFamilyName -eq 'OpenAI.Codex_2p2nqsd0c76g0' -and
            $_.PublisherId -eq '2p2nqsd0c76g0' -and
            [string]$_.SignatureKind -eq 'Store' -and
            [string]$_.Status -eq 'Ok'
        } |
        Sort-Object { [version]$_.Version } -Descending |
        Select-Object -First 1
    if ($null -ne $package -and $package.InstallLocation) {
        return [pscustomobject]@{ Root = (Get-FullPath $package.InstallLocation); Identity = [string]$package.PackageFullName; Version = [string]$package.Version; Family = [string]$package.PackageFamilyName }
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
        if ($line -match '^\s*\[([^\]]+)\]\s*(?:#.*)?$') {
            $skip = $managed.Contains($Matches[1])
        }
        elseif ($line -match '^\s*\[') { $skip = $false }
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
        [string]$Timestamp,
        [switch]$PreservePluginPreferences
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
    $original = $content
    if ($PreservePluginPreferences) { $managedSections = @('marketplaces.openai-bundled') }
    $content = Remove-ManagedTomlSections -Content $content -SectionNames $managedSections
    $marketplaceToml = $MarketplacePath.Replace('\', '\\').Replace('"', '\"')
    $updated = @(
        $content,
        '',
        '[marketplaces.openai-bundled]',
        "last_updated = `"$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))`"",
        'source_type = "local"',
        "source = `"$marketplaceToml`"",
        ''
    ) -join "`r`n"
    foreach ($name in @('browser', 'chrome', 'computer-use')) {
        $section = 'plugins."' + $name + '@openai-bundled"'
        if (-not $PreservePluginPreferences -or -not (Get-ConfigSection $original $section)) {
            $updated += "`r`n[$section]`r`nenabled = true`r`n"
        }
    }

    $encoding = New-Object Text.UTF8Encoding($false)
    & $script:RepairGuard
    Assert-NoReparsePath $configPath
    $stagedConfigPath = "$configPath.staging-$([Guid]::NewGuid().ToString('N'))"
    [IO.File]::WriteAllText($stagedConfigPath, $updated, $encoding)
    if ($hasExistingConfig) {
        [IO.File]::Replace($stagedConfigPath, $configPath, $backupPath)
        $script:RepairBackups.Add($backupPath)
        Write-Host "Configuration backup: $backupPath"
    }
    else {
        [IO.File]::Move($stagedConfigPath, $configPath)
    }
    Write-Host "Configuration updated: $configPath"
}
