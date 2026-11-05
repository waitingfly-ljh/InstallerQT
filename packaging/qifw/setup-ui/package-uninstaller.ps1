#Requires -Version 5.1
<#
.SYNOPSIS
  Generate the self-contained branded uninstaller OrbbecSlicerUninstaller.exe.

.DESCRIPTION
  Same single-file layout as package-setup.ps1, but the bundle contains only ui/ (shell exe + Qt runtime),
  no payload:

    [launcher exe][bundle.zip: ui/][trailer index OSUI1]

  The launcher extracts to %TEMP%\OrbbecSlicerSetup\<hash>\ and runs ui\OrbbecSlicerSetup.exe with --uninstall;
  after it exits, the temp directory is deleted and, in uninstaller mode, its own directory is deleted with a delay (%LOCALAPPDATA%\...\uninstaller\).

.PARAMETER LauncherExe
  The OrbbecSlicerSetupLauncher.exe produced by build-setup.ps1 (does not depend on Qt).

.PARAMETER UiDir
  The deployed shell directory (dist/).

.PARAMETER OutputPath
  Output path; defaults to <UiDir>\..\build\OrbbecSlicerUninstaller.exe.

.PARAMETER Version
  Version written into the trailer index (4-byte ASCII).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LauncherExe,
    [Parameter(Mandatory = $true)][string]$UiDir,
    [string]$OutputPath = '',
    [string]$Version = '1.0.0'
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

function Fail([string]$Message) {
    Write-Host "[uninstaller] ERROR $Message" -ForegroundColor Red
    exit 1
}

$LauncherExe = (Resolve-Path -LiteralPath $LauncherExe).ProviderPath
$UiDir = (Resolve-Path -LiteralPath $UiDir).ProviderPath
if (-not (Test-Path -LiteralPath (Join-Path $UiDir 'OrbbecSlicerSetup.exe'))) {
    Fail "OrbbecSlicerSetup.exe not found in UiDir: $UiDir"
}
if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path -Parent $UiDir) 'build\OrbbecSlicerUninstaller.exe'
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null

$verBytes = [System.Text.Encoding]::ASCII.GetBytes($Version)
$ver4 = New-Object byte[] 4
[Array]::Copy($verBytes, $ver4, [Math]::Min(4, $verBytes.Length))

Write-Host "[uninstaller] Launcher: $LauncherExe"
Write-Host "[uninstaller] UI directory: $UiDir"
Write-Host "[uninstaller] Output: $OutputPath"

$work = Join-Path (Split-Path -Parent $OutputPath) ('.uninstaller-bundle-' + [guid]::NewGuid().ToString('N'))
$uiStage = Join-Path $work 'ui'
New-Item -ItemType Directory -Force -Path $uiStage | Out-Null
try {
    Copy-Item -Path (Join-Path $UiDir '*') -Destination $uiStage -Recurse -Force

    $bundle = Join-Path $work 'bundle.zip'
    # 必须用 Windows 自带的 tar（bsdtar，支持 -a 按扩展名出 zip）；
    # 若 PATH 里 Git 的 tar（MSYS/GNU tar）在前，-a 会把它当远程主机名而失败，
    # 因此显式取 System32\bsdtar.exe，其次在 PATH 中挑非 Git 的 Win32 tar。
    $tarExe = Join-Path $env:SystemRoot 'System32\bsdtar.exe'
    if (-not (Test-Path -LiteralPath $tarExe)) { $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe' }
    if (-not (Test-Path -LiteralPath $tarExe)) {
        $cand = Get-Command tar.exe -All -ErrorAction SilentlyContinue |
            Where-Object { $_.Source -notmatch '[\\/](git|usr|mingw|msys)[\\/]' } |
            Select-Object -First 1
        if (-not $cand) { Fail '找不到 Windows 自带的 tar.exe（System32\bsdtar.exe），无法打包 bundle' }
        $tarExe = $cand.Source
    }
    $tar = Start-Process -FilePath $tarExe `
        -ArgumentList @('-a', '-c', '-f', $bundle, '-C', $work, 'ui') `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $work 'tar.log') -RedirectStandardError (Join-Path $work 'tar.err')
    if ($tar.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $bundle)) {
        Get-Content -LiteralPath (Join-Path $work 'tar.err') -Encoding UTF8 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host $_ }
        Fail "Failed to package bundle (tar exit $($tar.ExitCode))"
    }
    $bundleLen = (Get-Item -LiteralPath $bundle).Length

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bundleHash = $sha.ComputeHash([System.IO.File]::ReadAllBytes($bundle)) } finally { $sha.Dispose() }

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

    # Self-check: parse the trailer index and recompute the bundle hash
    $trailerSize = 8 + 8 + 8 + 32 + 4
    $check = [System.IO.File]::OpenRead($OutputPath)
    try {
        $setupLen = $check.Length
        if ($setupLen -ne ($launcherLen + $bundleLen + $trailerSize)) { Fail "Output size mismatch: $setupLen" }
        $check.Seek($setupLen - $trailerSize, [System.IO.SeekOrigin]::Begin) | Out-Null
        $trailer = New-Object byte[] $trailerSize
        if ($check.Read($trailer, 0, $trailerSize) -ne $trailerSize) { Fail 'Trailer index read incomplete' }
        if ([System.Text.Encoding]::ASCII.GetString($trailer, 0, 5) -ne 'OSUI1') { Fail 'Trailer magic mismatch' }
        if ([BitConverter]::ToInt64($trailer, 8) -ne $launcherLen -or
            [BitConverter]::ToInt64($trailer, 16) -ne $bundleLen) { Fail 'Trailer index offset/length mismatch' }
        $expect = New-Object byte[] 32
        [Array]::Copy($trailer, 24, $expect, 0, 32)
        if ([BitConverter]::ToString($expect) -ne [BitConverter]::ToString($bundleHash)) { Fail 'bundle SHA-256 self-check failed' }
    } finally {
        $check.Dispose()
    }

    $size = (Get-Item -LiteralPath $OutputPath).Length
    Write-Host ("[uninstaller] Done: {0} = {1:N0} B (launcher {2:N0} B + bundle {3:N0} B)" -f `
            [System.IO.Path]::GetFileName($OutputPath), $size, $launcherLen, $bundleLen)
    [ordered]@{
        launcherExe = $LauncherExe
        uiDir       = $UiDir
        outputPath  = $OutputPath
        version     = $Version
        launcherBytes = $launcherLen
        bundleBytes = $bundleLen
        uninstallerBytes = $size
        bundleSha256 = [BitConverter]::ToString($bundleHash).Replace('-', '').ToLower()
    } | ConvertTo-Json -Depth 3
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
exit 0
