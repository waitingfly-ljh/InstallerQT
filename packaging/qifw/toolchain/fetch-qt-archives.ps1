#Requires -Version 5.1
<#
.SYNOPSIS
  从已核验的归档离线安装 Qt 到工具根（不依赖 aqt 的下载器）。

.DESCRIPTION
  背景：aqt 3.3.0 的下载器在 download.qt.io 302 跳转到 CDN 时，会对大归档触发
  read timeout，且不支持复用已下载文件。本脚本改为：
    1. 用 curl 并发下载 manifest 列出的归档（--parallel 由调用方开启）
    2. 用官方 .sha256 逐个核验
    3. 用 py7zr 解包到 aqt 约定的目标目录

  归档来源仍为官方 download.qt.io，校验值也来自官方，因此与 aqt 直接下载等价。

.EXAMPLE
  .\fetch-qt-archives.ps1            # 下载 + 核验 + 解包
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

# 归档 -> 解包目标（相对工具根），与 aqt 的 archive_install_path 一致
$archives = @(
    @{ Name = 'qtbase-Windows-Windows_11_23H2-MSVC2022-Windows-Windows_11_23H2-X86_64.7z'; Dest = "$QtVersion/msvc2022_64" }
    @{ Name = 'qtsvg-Windows-Windows_11_23H2-MSVC2022-Windows-Windows_11_23H2-X86_64.7z'; Dest = "$QtVersion/msvc2022_64" }
    @{ Name = 'qtdeclarative-Windows-Windows_11_23H2-MSVC2022-Windows-Windows_11_23H2-X86_64.7z'; Dest = "$QtVersion/msvc2022_64" }
    @{ Name = 'qttools-Windows-Windows_11_23H2-MSVC2022-Windows-Windows_11_23H2-X86_64.7z'; Dest = "$QtVersion/msvc2022_64" }
    @{ Name = 'qttranslations-Windows-Windows_11_23H2-MSVC2022-Windows-Windows_11_23H2-X86_64.7z'; Dest = "$QtVersion/msvc2022_64" }
    @{ Name = 'd3dcompiler_47-x64.7z'; Dest = "$QtVersion/msvc2022_64/bin" }
    @{ Name = 'opengl32sw-64-mesa_11_2_2-signed_sha256.7z'; Dest = "$QtVersion/msvc2022_64/bin" }
)

# --- 1. 下载 --------------------------------------------------------------
if (-not $VerifyOnly) {
    Write-Log "下载 Qt $QtVersion 归档到 $ArchiveDir" 'STEP'
    foreach ($a in $archives) {
        $file = "$ArchTag$($a.Name)"
        $dest = Join-Path $ArchiveDir $file
        $sha = "$dest.sha256"
        if ((Test-Path $dest) -and (Test-Path $sha)) { Write-Log "  已存在: $file" 'OK'; continue }
        Write-Log "  下载: $file" 'INFO'
        Invoke-Native -FilePath 'curl.exe' -ArgumentList @(
            '-sL', '--retry', '5', '--retry-delay', '2', '--fail',
            '-o', $dest, "$officialBase/$file"
        ) | Out-Null
        if (-not (Test-Path $dest)) { throw "下载失败: $file" }
        Invoke-Native -FilePath 'curl.exe' -ArgumentList @('-sL', '--fail', '-o', $sha, "$officialBase/$file.sha256") | Out-Null
    }
}

# --- 2. 核验 --------------------------------------------------------------
Write-Log '核验 SHA-256（对照官方 .sha256）' 'STEP'
$bad = @()
foreach ($a in $archives) {
    $file = "$ArchTag$($a.Name)"
    $path = Join-Path $ArchiveDir $file
    $shaPath = "$path.sha256"
    if (-not (Test-Path $path)) { $bad += "$file (缺失)"; continue }
    if (-not (Test-Path $shaPath)) { $bad += "$file (缺 .sha256)"; continue }
    $expected = (Get-Content -LiteralPath $shaPath -Raw).Split(' ')[0].Trim().ToLower()
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
    if ($expected -ne $actual) { $bad += "$file (期望 $expected / 实际 $actual)"; continue }
    Write-Log ("  OK {0}" -f $a.Name) 'OK'
}
if ($bad.Count -gt 0) {
    $bad | ForEach-Object { Write-Log "  FAIL $_" 'ERROR' }
    throw "归档核验失败，已中止解包。"
}

if ($VerifyOnly) { Write-Log '核验完成。' 'OK'; exit 0 }

# --- 3. 解包 --------------------------------------------------------------
Write-Log '解包到工具根' 'STEP'
$py = (Get-Command python).Source
# 写成临时脚本文件调用：Start-Process 的 -ArgumentList 会按空格切分，内联 -c 代码会被拆散
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
        Write-Log "  解包: $($a.Name) -> $($a.Dest)" 'INFO'
        $r = Invoke-Native -FilePath $py -ArgumentList @('-I', $extractScript, $path, $target)
        if ($r.ExitCode -ne 0) { throw "解包失败: $($a.Name)" }
    }
}
finally {
    Remove-Item -LiteralPath $extractScript -Force -ErrorAction SilentlyContinue
}

# aqt 的布局约定：Qt/<version>/<arch>
$expectedDir = Join-Path $ToolchainRoot ("Qt\{0}\msvc2022_64" -f $QtVersion)
Write-Log "完成。Qt 位于: $expectedDir" 'OK'
exit 0
