#Requires -Version 5.1
<#
.SYNOPSIS
  Offline-install Qt into the tool root from verified archives (without aqt's downloader).

.DESCRIPTION
  Background: aqt 3.3.0's downloader triggers a read timeout on large archives when download.qt.io 302-redirects
  to the CDN, and does not support reusing already-downloaded files. This script instead:
    1. Uses curl to download the archives listed in the manifest in parallel (--parallel enabled by the caller)
    2. Verifies each one against the official .sha256
    3. Extracts with py7zr into the target directory expected by aqt

  The archive source is still the official download.qt.io, and the checksums also come from the official site, so this is equivalent to downloading directly with aqt.

.EXAMPLE
  .\fetch-qt-archives.ps1            # download + verify + extract
  .\fetch-qt-archives.ps1 -VerifyOnly
#>
[CmdletBinding()]
param(
    [string]$QtVersion = '6.8.3',
    [string]$Arch = 'win64_msvc2022_64',
    [string]$ArchTag = '6.8.3-0-202503201308',
    [string]$PackageFolder = 'qt6_683/qt6_683/qt.qt6.683.win64_msvc2022_64',
    [switch]$VerifyOnly
)

. "$PSScriptRoot\_common.ps1"

$RepoRoot = Get-RepoRoot
$ToolchainRoot = Resolve-RepoPath 'packaging/qifw/toolchain/qt' $RepoRoot
$ArchiveDir = Resolve-RepoPath 'packaging/qifw/out/archives' $RepoRoot
New-Item -ItemType Directory -Force -Path $ArchiveDir, $ToolchainRoot | Out-Null

$officialBase = "https://download.qt.io/online/qtsdkrepository/windows_x86/desktop/$PackageFolder"

# archive -> extract target (relative to the tool root), matching aqt's archive_install_path
$archives = @(
    @{ Name = 'qtbase-Windows-Windows_11_23H2-MSVC2022-Windows-Windows_11_23H2-X86_64.7z'; Dest = "$QtVersion/msvc2022_64" }
    @{ Name = 'qtsvg-Windows-Windows_11_23H2-MSVC2022-Windows-Windows_11_23H2-X86_64.7z'; Dest = "$QtVersion/msvc2022_64" }
    @{ Name = 'qtdeclarative-Windows-Windows_11_23H2-MSVC2022-Windows-Windows_11_23H2-X86_64.7z'; Dest = "$QtVersion/msvc2022_64" }
    @{ Name = 'qttools-Windows-Windows_11_23H2-MSVC2022-Windows-Windows_11_23H2-X86_64.7z'; Dest = "$QtVersion/msvc2022_64" }
    @{ Name = 'qttranslations-Windows-Windows_11_23H2-MSVC2022-Windows-Windows_11_23H2-X86_64.7z'; Dest = "$QtVersion/msvc2022_64" }
    @{ Name = 'd3dcompiler_47-x64.7z'; Dest = "$QtVersion/msvc2022_64/bin" }
    @{ Name = 'opengl32sw-64-mesa_11_2_2-signed_sha256.7z'; Dest = "$QtVersion/msvc2022_64/bin" }
)

# --- 1. Download ----------------------------------------------------------
if (-not $VerifyOnly) {
    Write-Log "Downloading Qt $QtVersion archives to $ArchiveDir" 'STEP'
    foreach ($a in $archives) {
        $file = "$ArchTag$($a.Name)"
        $dest = Join-Path $ArchiveDir $file
        $sha = "$dest.sha256"
        if ((Test-Path $dest) -and (Test-Path $sha)) { Write-Log "  already present: $file" 'OK'; continue }
        Write-Log "  download: $file" 'INFO'
        Invoke-Native -FilePath 'curl.exe' -ArgumentList @(
            '-sL', '--retry', '5', '--retry-delay', '2', '--fail',
            '-o', $dest, "$officialBase/$file"
        ) | Out-Null
        if (-not (Test-Path $dest)) { throw "download failed: $file" }
        Invoke-Native -FilePath 'curl.exe' -ArgumentList @('-sL', '--fail', '-o', $sha, "$officialBase/$file.sha256") | Out-Null
    }
}

# --- 2. Verify ------------------------------------------------------------
Write-Log 'Verifying SHA-256 (against official .sha256)' 'STEP'
$bad = @()
foreach ($a in $archives) {
    $file = "$ArchTag$($a.Name)"
    $path = Join-Path $ArchiveDir $file
    $shaPath = "$path.sha256"
    if (-not (Test-Path $path)) { $bad += "$file (missing)"; continue }
    if (-not (Test-Path $shaPath)) { $bad += "$file (missing .sha256)"; continue }
    $expected = (Get-Content -LiteralPath $shaPath -Raw).Split(' ')[0].Trim().ToLower()
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { $bad += "$file (expected $expected / actual $actual)"; continue }
    Write-Log ("  OK {0}" -f $a.Name) 'OK'
}
if ($bad.Count -gt 0) {
    $bad | ForEach-Object { Write-Log "  FAIL $_" 'ERROR' }
    throw "Archive verification failed, extraction aborted."
}

if ($VerifyOnly) { Write-Log 'Verification complete.' 'OK'; exit 0 }

# --- 3. Extract -----------------------------------------------------------
Write-Log 'Extracting to tool root' 'STEP'
$py = (Get-Command python).Source
# Written to a temp script file: Start-Process -ArgumentList splits on spaces and would break inline -c code
$extractScript = Join-Path ([System.IO.Path]::GetTempPath()) 'qifw_extract_7z.py'
@'
import sys
import py7zr

with py7zr.SevenZipFile(sys.argv[1], "r") as archive:
    archive.extractall(path=sys.argv[2])
'@ | Set-Content -LiteralPath $extractScript -Encoding UTF8

try {
    foreach ($a in $archives) {
        $file = "$ArchTag$($a.Name)"
        $path = Join-Path $ArchiveDir $file
        $target = Join-Path $ToolchainRoot ($a.Dest -replace '/', '\')
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Write-Log "  extract: $($a.Name) -> $($a.Dest)" 'INFO'
        $r = Invoke-Native -FilePath $py -ArgumentList @('-I', $extractScript, $path, $target)
        if ($r.ExitCode -ne 0) { throw "extract failed: $($a.Name)" }
    }
}
finally {
    Remove-Item -LiteralPath $extractScript -Force -ErrorAction SilentlyContinue
}

# aqt's layout convention: Qt/<version>/<arch>
$expectedDir = Join-Path $ToolchainRoot ("Qt\{0}\msvc2022_64" -f $QtVersion)
Write-Log "Done. Qt located at: $expectedDir" 'OK'
exit 0
