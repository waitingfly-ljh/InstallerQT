#Requires -Version 5.1
<#
.SYNOPSIS
  Fetch QIFW 4.11.0 into the tool root (inside the repository).

.DESCRIPTION
  Why not aqt: QIFW 4.11 is only published in the windows_x86/ifw/ channel, and aqt 3.3.0's
  target allowlist only has {desktop, winrt, android, ios, wasm, qt}, so `aqt install-tool`
  cannot reach that channel. This script instead downloads directly from the archiveUrl registered in the manifest,
  verifies with the official .sha256, and extracts with py7zr.

.EXAMPLE
  .\fetch-ifw.ps1
#>
[CmdletBinding()]
param([switch]$Force)

. "$PSScriptRoot\_common.ps1"

$RepoRoot = Get-RepoRoot
$Manifest = Get-ToolchainManifest -RepoRoot $RepoRoot
$OutDir = Resolve-RepoPath 'packaging/qifw/out' $RepoRoot
$ArchiveDir = Join-Path $OutDir 'archives'
New-Item -ItemType Directory -Force -Path $ArchiveDir | Out-Null

$ifwDir = Resolve-RepoPath -RelativePath $Manifest.ifw.installDir -RepoRoot $RepoRoot
$binarycreator = Join-Path $ifwDir 'bin\binarycreator.exe'

if ((Test-Path -LiteralPath $binarycreator) -and -not $Force) {
    Write-Log "QIFW $($Manifest.ifw.version) already present: $ifwDir" 'OK'
    exit 0
}

$archiveName = $Manifest.ifw.archive
$archivePath = Join-Path $ArchiveDir $archiveName
$shaPath = "$archivePath.sha256"

# --- 1. Download + official checksum --------------------------------------
if (-not (Test-Path -LiteralPath $shaPath)) {
    Invoke-Native -FilePath 'curl.exe' -ArgumentList @('-sL', '--fail', '-o', $shaPath, "$($Manifest.ifw.archiveUrl).sha256") | Out-Null
}
$expected = if ($Manifest.ifw.archiveSha256) { $Manifest.ifw.archiveSha256.ToLower() }
elseif (Test-Path -LiteralPath $shaPath) { (Get-Content -LiteralPath $shaPath -Raw).Split(' ')[0].Trim().ToLower() }
else { '' }
if (-not $expected) { throw 'Missing expected checksum: neither manifest.ifw.archiveSha256 nor the .sha256 file is available.' }

# An interrupted download leaves a partial .7z behind; skipping merely because the file exists
# would make every later run fail verification.
if (Test-Path -LiteralPath $archivePath) {
    $existing = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLower()
    if ($existing -ne $expected) {
        Write-Log "Existing archive checksum mismatch (likely a partial file from an interrupted download), deleting and re-downloading: $existing" 'WARN'
        Remove-Item -LiteralPath $archivePath -Force
    }
}
if (-not (Test-Path -LiteralPath $archivePath)) {
    Write-Log "Downloading $archiveName" 'STEP'
    $r = Invoke-Native -FilePath 'curl.exe' -ArgumentList @(
        '-sL', '--retry', '5', '--retry-delay', '2', '--fail', '-o', $archivePath, $Manifest.ifw.archiveUrl
    )
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $archivePath)) { throw "download failed: $($Manifest.ifw.archiveUrl)" }
}

# --- 2. Verify ------------------------------------------------------------
Write-Log 'Verifying SHA-256' 'STEP'
$actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLower()
if ($expected -ne $actual) { throw "Verification failed: expected $expected / actual $actual" }
Write-Log "  OK $actual" 'OK'

# --- 3. Extract -----------------------------------------------------------
Write-Log "Extracting to $ifwDir" 'STEP'
New-Item -ItemType Directory -Force -Path $ifwDir | Out-Null
$extractScript = Join-Path ([System.IO.Path]::GetTempPath()) 'qifw_extract_7z.py'
@'
import sys
import py7zr

with py7zr.SevenZipFile(sys.argv[1], "r") as archive:
    archive.extractall(path=sys.argv[2])
'@ | Set-Content -LiteralPath $extractScript -Encoding UTF8
try {
    $r = Invoke-Native -FilePath (Get-Command python).Source -ArgumentList @('-I', $extractScript, $archivePath, $ifwDir)
    if ($r.ExitCode -ne 0) { throw 'extract failed' }
}
finally {
    Remove-Item -LiteralPath $extractScript -Force -ErrorAction SilentlyContinue
}

foreach ($t in $Manifest.tools) {
    # manifest's relativePath is relative to the tool root (qt/); strip the Tools/QtInstallerFramework/<ver>/
    # prefix before joining under ifwDir, otherwise it would look for 4.11.0\binarycreator.exe
    # (which actually lives in 4.11.0\bin\).
    $rel = $t.relativePath -replace '^Tools/QtInstallerFramework/[^/]+/', ''
    $p = Join-Path $ifwDir ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $p)) { throw "tool missing: $($t.name) ($p)" }
    Write-Log ("  {0,-16} {1}" -f $t.name, $p) 'OK'
}

Write-Log "QIFW $($Manifest.ifw.version) ready." 'OK'
exit 0
