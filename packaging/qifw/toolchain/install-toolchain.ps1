#Requires -Version 5.1
<#
.SYNOPSIS
  幂等获取 Qt 与 Qt Installer Framework（QIFW）到仓库内工具根。

.DESCRIPTION
  1. 读取 packaging/qifw/toolchain/manifest.json
  2. Qt：调用 fetch-qt-archives.ps1（curl 并发下载 + 官方 sha256 + py7zr 解包）
  3. QIFW：调用 fetch-ifw.ps1（同上，直接取 ifw channel 的归档）
  4. 校验工具落盘，写安装记录到 packaging/qifw/out/

  为什么不直接用 aqt install-qt / install-tool：
    - aqt 3.3.0 的下载器在 download.qt.io 302 跳到 CDN 时，大归档会 read timeout，
      且不复用已下载文件；
    - QIFW 4.11 在 windows_x86/ifw/ channel，aqt 的 target 白名单不含 ifw。
  本脚本的下载源与校验值都来自官方站点，结果与 aqt 等价。

  前提：Python 3.8+，且已安装 py7zr（pip install py7zr）。
  所有写入都在 D:\Orbbec\install-qt 之内，不触碰原项目。

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

Write-Log "仓库根: $RepoRoot" 'INFO'
Write-Log "工具根: $ToolchainRoot" 'INFO'
Write-Log "Qt $($Manifest.qt.version) ($($Manifest.qt.architecture)) / QIFW $($Manifest.ifw.version)" 'INFO'

# --- 0. 依赖检查 ----------------------------------------------------------
$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) { throw '未找到 python（3.8+）。请安装并加入 PATH。' }
# Start-Process 的 -ArgumentList 会按空格切分，内联 -c 代码会被拆散；用 -m 形式探测
$pyCheck = Invoke-Native -FilePath $python -ArgumentList @('-I', '-m', 'py7zr', '--help')
if ($pyCheck.ExitCode -ne 0) {
    Write-Log '缺少 py7zr，开始安装...' 'STEP'
    $r = Invoke-Native -FilePath $python -ArgumentList @('-m', 'pip', 'install', '--disable-pip-version-check', 'py7zr')
    if ($r.ExitCode -ne 0) { throw 'pip install py7zr 失败' }
}
Write-Log "py7zr OK" 'OK'

$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
if (-not $curl) { throw '未找到 curl.exe（Windows 10 1803+ 自带）。' }

# --- 1. Qt ----------------------------------------------------------------
$qtBin = Join-Path $ToolchainRoot ("{0}\{1}\bin\Qt6Core.dll" -f $Manifest.qt.version, $Manifest.qt.archDir)
if ((Test-Path -LiteralPath $qtBin) -and -not $Force) {
    Write-Log "Qt $($Manifest.qt.version) 已就绪，跳过: $qtBin" 'OK'
}
elseif ($SkipQt) {
    Write-Log '跳过 Qt（-SkipQt）' 'WARN'
}
else {
    Write-Log '== 获取 Qt ==' 'STEP'
    & powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $PSScriptRoot 'fetch-qt-archives.ps1')
    if ($LASTEXITCODE -ne 0) { throw "fetch-qt-archives.ps1 失败 (exit $LASTEXITCODE)" }
    if (-not (Test-Path -LiteralPath $qtBin)) { throw "Qt 解包后仍找不到 $qtBin" }
}

# --- 2. QIFW --------------------------------------------------------------
$ifwBin = Join-Path $ToolchainRoot 'Tools\QtInstallerFramework'
if ((Test-Path -LiteralPath $ifwBin) -and -not $Force) {
    $have = Get-ChildItem -LiteralPath $ifwBin -Directory | Where-Object Name -like "$($Manifest.ifw.version)*"
    if ($have) { Write-Log "QIFW $($Manifest.ifw.version) 已就绪，跳过: $($have[0].FullName)" 'OK' }
}
if ($SkipIfw) {
    Write-Log '跳过 QIFW（-SkipIfw）' 'WARN'
}
elseif (-not (Test-Path -LiteralPath (Join-Path $ifwBin "$($Manifest.ifw.version)\bin\binarycreator.exe"))) {
    Write-Log '== 获取 QIFW ==' 'STEP'
    & powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $PSScriptRoot 'fetch-ifw.ps1') -Force:$Force
    if ($LASTEXITCODE -ne 0) { throw "fetch-ifw.ps1 失败 (exit $LASTEXITCODE)" }
}

# --- 3. 校验落盘 ----------------------------------------------------------
Write-Log '校验工具...' 'STEP'
$missing = @()
$toolchainRel = $Manifest.toolchainRoot.TrimEnd('/')  # manifest.tools[].relativePath 相对工具根
foreach ($tool in $Manifest.tools) {
    $guard = Resolve-RepoPath -RelativePath ("$toolchainRel/$($tool.relativePath)") -RepoRoot $RepoRoot
    if (Test-Path -LiteralPath $guard) { Write-Log ("  {0,-16} {1}" -f $tool.name, $guard) 'OK' }
    else { Write-Log ("  {0,-16} 缺失 ({1})" -f $tool.name, $guard) 'ERROR'; $missing += $tool.name }
}
if ($missing.Count -gt 0) { throw "以下工具未落盘: $($missing -join ', ')" }

# --- 4. 记录 --------------------------------------------------------------
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
Write-Log "安装记录: $reportPath" 'OK'
Write-Log '工具链获取完成。' 'OK'
exit 0
