#Requires -Version 5.1
<#
.SYNOPSIS
  Assemble the single-file installer Setup.exe (launcher + ui/Qt runtime + QIFW installer package).

.DESCRIPTION
  Data layout (matches src/launcher.cpp and src/setuphost.cpp, all little-endian):

    [launcher exe][bundle.zip][trailer index]
    trailer index = magic 8B "OSUI1\0\0\0" | offset 8B | length 8B | sha256 32B | version 4B

  bundle.zip contents:
    ui/        dist/ from build-setup.ps1 (shell exe + Qt runtime + qml/ + qt.conf)
    ui/version.txt          full payload version (the 4-byte trailer field truncates it)
    payload/installer.exe   QIFW installer package

  At runtime the launcher extracts to %TEMP%\OrbbecSlicerSetup\<hash>\ and then runs
  ui/OrbbecSlicerSetup.exe with --payload pointing at the extracted installer package.

  After writing, the output file is reopened to parse the index and recompute the hash; any mismatch exits non-zero.

.PARAMETER LauncherExe
  The OrbbecSlicerSetupLauncher.exe produced by the build script (does not depend on Qt).

.PARAMETER UiDir
  The deployed shell directory (dist/).

.PARAMETER InstallerExe
  The QIFW installer package produced by binarycreator.

.PARAMETER OutputPath
  Output Setup.exe path; defaults to the same directory as InstallerExe, with -Installer.exe replaced by -Setup.exe in the file name.

.PARAMETER Version
  payload version (the 4 bytes written into the index); defaults to parsing it from the InstallerExe file name.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LauncherExe,
    [Parameter(Mandatory = $true)][string]$UiDir,
    [Parameter(Mandatory = $true)][string]$InstallerExe,
    [string]$UninstallerExe = '',
    [string]$OutputPath = '',
    [string]$Version = ''
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

function Fail([string]$Message) {
    Write-Host "[package] ERROR $Message" -ForegroundColor Red
    exit 1
}

$LauncherExe = (Resolve-Path -LiteralPath $LauncherExe).ProviderPath
$UiDir = (Resolve-Path -LiteralPath $UiDir).ProviderPath
$InstallerExe = (Resolve-Path -LiteralPath $InstallerExe).ProviderPath
foreach ($p in @($LauncherExe, $InstallerExe)) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Fail "File does not exist: $p" }
}
if (-not (Test-Path -LiteralPath (Join-Path $UiDir 'OrbbecSlicerSetup.exe'))) {
    Fail "OrbbecSlicerSetup.exe not found in UiDir: $UiDir"
}

if (-not $Version) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($InstallerExe)
    $parts = $base -split '-'
    if ($parts.Count -ge 3) { $Version = $parts[1] }
}
if (-not $Version) { Fail 'Cannot determine version: pass -Version explicitly' }
$verBytes = [System.Text.Encoding]::ASCII.GetBytes($Version)
$ver4 = New-Object byte[] 4
[Array]::Copy($verBytes, $ver4, [Math]::Min(4, $verBytes.Length))

if (-not $OutputPath) {
    $dir = Split-Path -Parent $InstallerExe
    $name = [System.IO.Path]::GetFileName($InstallerExe) -replace '-Installer\.exe$', '-Setup.exe'
    $OutputPath = Join-Path $dir $name
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
foreach ($p in @($LauncherExe, $InstallerExe)) {
    if ($OutputPath -eq $p) { Fail 'Output path must not be the same as an input file' }
}

Write-Host "[package] Launcher: $LauncherExe"
Write-Host "[package] UI directory: $UiDir"
if ($UninstallerExe) {
    $UninstallerExe = (Resolve-Path -LiteralPath $UninstallerExe).ProviderPath
    if (-not (Test-Path -LiteralPath $UninstallerExe -PathType Leaf)) { Fail "Uninstaller does not exist: $UninstallerExe" }
    Write-Host "[package] Uninstaller: $UninstallerExe"
} else {
    Write-Host "[package] Uninstaller: (none, skipping deployment)" -ForegroundColor Yellow
}
Write-Host "[package] Payload: $InstallerExe"
Write-Host "[package] Output: $OutputPath"
Write-Host "[package] Version: $Version"

# --- 1. Assemble the bundle directory and pack it into a zip ------------------------------------------
$work = Join-Path (Split-Path -Parent $OutputPath) ('.setup-bundle-' + [guid]::NewGuid().ToString('N'))
$uiStage = Join-Path $work 'ui'
$payloadStage = Join-Path $work 'payload'
$uninstStage = Join-Path $work 'uninstaller'
New-Item -ItemType Directory -Force -Path $uiStage, $payloadStage | Out-Null
try {
    Copy-Item -Path (Join-Path $UiDir '*') -Destination $uiStage -Recurse -Force
    # The trailer index only stores 4 bytes of the version ("0.4.0-beta.1" -> "0.4."), which made the
    # maintenance screen read a same-version re-install as a downgrade. Ship the full version with the
    # UI so SetupHost can use it and only fall back to the trailer for older packages.
    [System.IO.File]::WriteAllText((Join-Path $uiStage 'version.txt'), $Version,
        (New-Object System.Text.UTF8Encoding($false)))
    Copy-Item -LiteralPath $InstallerExe -Destination (Join-Path $payloadStage 'installer.exe') -Force

    $tarItems = @('ui', 'payload')
    if ($UninstallerExe) {
        New-Item -ItemType Directory -Force -Path $uninstStage | Out-Null
        Copy-Item -LiteralPath $UninstallerExe -Destination (Join-Path $uninstStage 'OrbbecSlicerUninstaller.exe') -Force
        $tarItems += 'uninstaller'
    }

    $bundle = Join-Path $work 'bundle.zip'
    # The built-in Windows tar.exe (bsdtar) supports -a to create a zip based on the extension.
    $tar = Start-Process -FilePath 'tar.exe' `
        -ArgumentList (@('-a', '-c', '-f', $bundle, '-C', $work) + $tarItems) `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $work 'tar.log') -RedirectStandardError (Join-Path $work 'tar.err')
    if ($tar.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $bundle)) {
        Get-Content -LiteralPath (Join-Path $work 'tar.err') -Encoding UTF8 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host $_ }
        Fail "Failed to package bundle (tar exit $($tar.ExitCode))"
    }
    $bundleLen = (Get-Item -LiteralPath $bundle).Length
    Write-Host ("[package] bundle.zip: {0:N0} B" -f $bundleLen)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bundleHash = $sha.ComputeHash([System.IO.File]::ReadAllBytes($bundle)) } finally { $sha.Dispose() }

    # --- 2. Launcher + bundle + trailer index -------------------------------------
    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }
    $launcherLen = (Get-Item -LiteralPath $LauncherExe).Length
    $out = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try {
        $lin = [System.IO.File]::OpenRead($LauncherExe)
        try { $lin.CopyTo($out) } finally { $lin.Dispose() }
        $bin = [System.IO.File]::OpenRead($bundle)
        try { $bin.CopyTo($out) } finally { $bin.Dispose() }

        $magic = [System.Text.Encoding]::ASCII.GetBytes("OSUI1`0`0`0")
        $out.Write($magic, 0, 8)
        $out.Write([BitConverter]::GetBytes([int64]$launcherLen), 0, 8)
        $out.Write([BitConverter]::GetBytes([int64]$bundleLen), 0, 8)
        $out.Write($bundleHash, 0, 32)
        $out.Write($ver4, 0, 4)
    } finally {
        $out.Dispose()
    }

    # --- 3. Self-check: parse the trailer and recompute the bundle hash ------------------------------
    $trailerSize = 8 + 8 + 8 + 32 + 4
    $check = [System.IO.File]::OpenRead($OutputPath)
    try {
        $setupLen = $check.Length
        $expectLen = $launcherLen + $bundleLen + $trailerSize
        if ($setupLen -ne $expectLen) { Fail "Output size mismatch: $setupLen (expected $expectLen)" }
        $check.Seek($setupLen - $trailerSize, [System.IO.SeekOrigin]::Begin) | Out-Null
        $trailer = New-Object byte[] $trailerSize
        if ($check.Read($trailer, 0, $trailerSize) -ne $trailerSize) { Fail 'Trailer index read incomplete' }
        if ([System.Text.Encoding]::ASCII.GetString($trailer, 0, 5) -ne 'OSUI1') { Fail 'Trailer magic mismatch' }
        $readOffset = [BitConverter]::ToInt64($trailer, 8)
        $readLength = [BitConverter]::ToInt64($trailer, 16)
        if ($readOffset -ne $launcherLen -or $readLength -ne $bundleLen) {
            Fail "Trailer index mismatch: offset=$readOffset/$launcherLen length=$readLength/$bundleLen"
        }
        $expect = New-Object byte[] 32
        [Array]::Copy($trailer, 24, $expect, 0, 32)
        if ([BitConverter]::ToString($expect) -ne [BitConverter]::ToString($bundleHash)) {
            Fail 'bundle SHA-256 self-check failed'
        }
        $readVer = [System.Text.Encoding]::ASCII.GetString($trailer, 56, 4).Trim([char]0x00, [char]0x20)
    } finally {
        $check.Dispose()
    }

    $result = [ordered]@{
        launcherExe    = $LauncherExe
        uiDir          = $UiDir
        installerExe   = $InstallerExe
        outputPath     = $OutputPath
        version        = $Version
        trailerVersion = $readVer
        payloadOffset  = $launcherLen
        bundleBytes    = $bundleLen
        launcherBytes  = $launcherLen
        setupBytes     = (Get-Item -LiteralPath $OutputPath).Length
        bundleSha256   = [BitConverter]::ToString($bundleHash).Replace('-', '').ToLower()
        uninstallerExe = $UninstallerExe
        trailerSize    = $trailerSize
    }
    Write-Host ("[package] Done: {0} = {1:N0} B (launcher {2:N0} B + bundle {3:N0} B + index {4} B)" -f `
            [System.IO.Path]::GetFileName($OutputPath), $result.setupBytes, $launcherLen, $bundleLen, $trailerSize)
    $result | ConvertTo-Json -Depth 3
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
exit 0
