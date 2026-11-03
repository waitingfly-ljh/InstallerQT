#Requires -Version 5.1
<#
.SYNOPSIS
  获取 QIFW 4.11.0 到工具根（仓库内）。

.DESCRIPTION
  为什么不用 aqt：QIFW 4.11 只在 windows_x86/ifw/ channel 发布，而 aqt 3.3.0 的
  target 白名单只有 {desktop, winrt, android, ios, wasm, qt}，`aqt install-tool`
  无法访问该 channel。这里直接按 manifest 登记的 archiveUrl 下载，用官方
  .sha256 核验，再用 py7zr 解包。

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
    Write-Log "QIFW $($Manifest.ifw.version) 已存在: $ifwDir" 'OK'
    exit 0
}

$archiveName = $Manifest.ifw.archive
$archivePath = Join-Path $ArchiveDir $archiveName
$shaPath = "$archivePath.sha256"

# --- 1. 下载 + 官方校验值 -------------------------------------------------
if (-not (Test-Path -LiteralPath $archivePath)) {
    Write-Log "下载 $archiveName" 'STEP'
    $r = Invoke-Native -FilePath 'curl.exe' -ArgumentList @(
        '-sL', '--retry', '5', '--retry-delay', '2', '--fail', '-o', $archivePath, $Manifest.ifw.archiveUrl
    )
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $archivePath)) { throw "下载失败: $($Manifest.ifw.archiveUrl)" }
}
if (-not (Test-Path -LiteralPath $shaPath)) {
    Invoke-Native -FilePath 'curl.exe' -ArgumentList @('-sL', '--fail', '-o', $shaPath, "$($Manifest.ifw.archiveUrl).sha256") | Out-Null
}

# --- 2. 核验 --------------------------------------------------------------
Write-Log '核验 SHA-256' 'STEP'
$expected = if ($Manifest.ifw.archiveSha256) { $Manifest.ifw.archiveSha256.ToLower() }
elseif (Test-Path -LiteralPath $shaPath) { (Get-Content -LiteralPath $shaPath -Raw).Split(' ')[0].Trim().ToLower() }
else { '' }
$actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLower()
if (-not $expected) { throw '缺少期望校验值：manifest.ifw.archiveSha256 与 .sha256 文件均不可用。' }
if ($expected -ne $actual) { throw "校验失败：期望 $expected / 实际 $actual" }
Write-Log "  OK $actual" 'OK'

# --- 3. 解包 --------------------------------------------------------------
Write-Log "解包到 $ifwDir" 'STEP'
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
    if ($r.ExitCode -ne 0) { throw '解包失败' }
}
finally {
    Remove-Item -LiteralPath $extractScript -Force -ErrorAction SilentlyContinue
}

foreach ($t in $Manifest.tools) {
    $p = Join-Path $ifwDir (Split-Path -Leaf $t.relativePath)
    if (-not (Test-Path -LiteralPath $p)) { throw "工具缺失: $($t.name)" }
    Write-Log ("  {0,-16} {1}" -f $t.name, $p) 'OK'
}

Write-Log "QIFW $($Manifest.ifw.version) 就绪。" 'OK'
exit 0
