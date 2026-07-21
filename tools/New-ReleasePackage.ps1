#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$version = ([IO.File]::ReadAllText((Join-Path $repositoryRoot 'VERSION'))).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "VERSION must use semantic version format, for example 1.0.0. Found: $version"
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repositoryRoot 'dist'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$packageName = "Codex-Computer-Use-Repair-v$version"
$zipPath = Join-Path $OutputDirectory "$packageName.zip"
$checksumPath = "$zipPath.sha256"

$requiredFiles = @(
    'repair-codex-computer-use.ps1',
    'Run-Codex-Computer-Use-Repair.cmd',
    'README.md',
    'VERSION',
    'LICENSE'
)

foreach ($relativePath in $requiredFiles) {
    $sourcePath = Join-Path $repositoryRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required package file is missing: $relativePath"
    }
}

$temporaryRoot = Join-Path $OutputDirectory ('.staging-' + [Guid]::NewGuid().ToString('N'))
$outputPrefix = $OutputDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $temporaryRoot.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to use a staging directory outside the output directory: $temporaryRoot"
}
$stagingRoot = Join-Path $temporaryRoot $packageName
try {
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    foreach ($relativePath in $requiredFiles) {
        Copy-Item -LiteralPath (Join-Path $repositoryRoot $relativePath) -Destination (Join-Path $stagingRoot $relativePath)
    }

    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    if (Test-Path -LiteralPath $checksumPath) {
        Remove-Item -LiteralPath $checksumPath -Force
    }

    Compress-Archive -LiteralPath $stagingRoot -DestinationPath $zipPath -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($checksumPath, "$hash  $packageName.zip`n", $encoding)

    Write-Host "Created: $zipPath"
    Write-Host "SHA-256: $hash"
    Write-Host "Checksum: $checksumPath"
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
