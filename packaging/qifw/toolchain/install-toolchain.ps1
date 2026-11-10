#Requires -Version 5.1
<#
.SYNOPSIS
  Idempotently fetch Qt and Qt Installer Framework (QIFW) into the in-repo tool root.

.DESCRIPTION
  1. Read packaging/qifw/toolchain/manifest.json
  2. Qt: call fetch-qt-archives.ps1 (curl parallel download + official sha256 + py7zr extract)
  3. QIFW: call fetch-ifw.ps1 (same, taking the archive from the ifw channel directly)
  4. Verify the tools landed, write the install record to packaging/qifw/out/

  Why not use aqt install-qt / install-tool directly:
    - aqt 3.3.0's downloader hits a read timeout on large archives when download.qt.io 302-redirects to the CDN,
      and does not reuse already-downloaded files;
    - QIFW 4.11 is in the windows_x86/ifw/ channel, and aqt's target allowlist does not include ifw.
  This script's download sources and checksums all come from the official site; the result is equivalent to aqt.

  Prerequisite: Python 3.8+, with py7zr installed (pip install py7zr).
  All writes stay inside D:\Orbbec\install-qt and never touch the original project.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\install-toolchain.ps1
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipQt,
    [switch]$SkipIfw
)

. "$PSScriptRoot\_common.ps1"

$RepoRoot = Get-RepoRoot
$Manifest = Get-ToolchainManifest -RepoRoot $RepoRoot
$ToolchainRoot = Get-ToolchainRoot -Manifest $Manifest -RepoRoot $RepoRoot
$OutDir = Resolve-RepoPath 'packaging/qifw/out' -RepoRoot $RepoRoot
New-Item -ItemType Directory -Force -Path $ToolchainRoot, $OutDir | Out-Null

Write-Log "Repository root: $RepoRoot" 'INFO'
Write-Log "Tool root: $ToolchainRoot" 'INFO'
Write-Log "Qt $($Manifest.qt.version) ($($Manifest.qt.architecture)) / QIFW $($Manifest.ifw.version)" 'INFO'

# --- 0. Dependency check --------------------------------------------------
$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { throw 'python not found (3.8+). Install it and add it to PATH.' }
# Start-Process -ArgumentList splits on spaces and would break inline -c code; probe with the -m form
$pyCheck = Invoke-Native -FilePath $python -ArgumentList @('-I', '-m', 'py7zr', '--help')
if ($pyCheck.ExitCode -ne 0) {
    Write-Log 'py7zr missing, installing...' 'STEP'
    $r = Invoke-Native -FilePath $python -ArgumentList @('-m', 'pip', 'install', '--disable-pip-version-check', 'py7zr')
    if ($r.ExitCode -ne 0) { throw 'pip install py7zr failed' }
}
Write-Log "py7zr OK" 'OK'

$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
if (-not $curl) { throw 'curl.exe not found (bundled with Windows 10 1803+).' }

# The sub-scripts take [switch]$Force, so -Force:$Force must not be passed: when calling the
# native powershell.exe, PowerShell renders it as the string "-Force:False", which the sub-script
# then rejects as an unconvertible type.
$forceArg = @()
if ($Force) { $forceArg += '-Force' }

# --- 1. Qt ----------------------------------------------------------------
$qtBin = Join-Path $ToolchainRoot ("{0}\{1}\bin\Qt6Core.dll" -f $Manifest.qt.version, $Manifest.qt.archDir)
if ((Test-Path -LiteralPath $qtBin) -and -not $Force) {
    Write-Log "Qt $($Manifest.qt.version) already present, skipping: $qtBin" 'OK'
}
elseif ($SkipQt) {
    Write-Log 'Skipping Qt (-SkipQt)' 'WARN'
}
else {
    Write-Log '== Fetching Qt ==' 'STEP'
    & powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $PSScriptRoot 'fetch-qt-archives.ps1') @forceArg
    if ($LASTEXITCODE -ne 0) { throw "fetch-qt-archives.ps1 failed (exit $LASTEXITCODE)" }
    if (-not (Test-Path -LiteralPath $qtBin)) { throw "Qt still missing $qtBin after extraction" }
}

# --- 2. QIFW --------------------------------------------------------------
$ifwBin = Join-Path $ToolchainRoot 'Tools\QtInstallerFramework'
if ((Test-Path -LiteralPath $ifwBin) -and -not $Force) {
    $have = Get-ChildItem -LiteralPath $ifwBin -Directory | Where-Object Name -like "$($Manifest.ifw.version)*"
    if ($have) { Write-Log "QIFW $($Manifest.ifw.version) already present, skipping: $($have[0].FullName)" 'OK' }
}
if ($SkipIfw) {
    Write-Log 'Skipping QIFW (-SkipIfw)' 'WARN'
}
elseif (-not (Test-Path -LiteralPath (Join-Path $ifwBin "$($Manifest.ifw.version)\bin\binarycreator.exe"))) {
    Write-Log '== Fetching QIFW ==' 'STEP'
    & powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $PSScriptRoot 'fetch-ifw.ps1') @forceArg
    if ($LASTEXITCODE -ne 0) { throw "fetch-ifw.ps1 failed (exit $LASTEXITCODE)" }
}

# --- 3. Verify what landed ------------------------------------------------
Write-Log 'Verifying tools...' 'STEP'
$missing = @()
$toolchainRel = $Manifest.toolchainRoot.TrimEnd('/')  # manifest.tools[].relativePath is relative to the tool root
foreach ($tool in $Manifest.tools) {
    $guard = Resolve-RepoPath -RelativePath ("$toolchainRel/$($tool.relativePath)") -RepoRoot $RepoRoot
    if (Test-Path -LiteralPath $guard) { Write-Log ("  {0,-16} {1}" -f $tool.name, $guard) 'OK' }
    else { Write-Log ("  {0,-16} missing ({1})" -f $tool.name, $guard) 'ERROR'; $missing += $tool.name }
}
if ($missing.Count -gt 0) { throw "The following tools did not land: $($missing -join ', ')" }

# --- 4. Record ------------------------------------------------------------
$report = [ordered]@{
    generatedAt   = (Get-Date).ToString('o')
    repoRoot      = $RepoRoot
    toolchainRoot = $ToolchainRoot
    qt            = $Manifest.qt.version
    ifw           = $Manifest.ifw.version
    layout        = (Get-ChildItem -LiteralPath $ToolchainRoot -Directory | Select-Object -ExpandProperty Name)
}
$reportPath = Join-Path $OutDir 'toolchain-install.json'
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Log "Install record: $reportPath" 'OK'
Write-Log 'Toolchain fetch complete.' 'OK'
exit 0
