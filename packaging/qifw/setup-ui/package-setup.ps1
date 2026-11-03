#Requires -Version 5.1
<#
.SYNOPSIS
  合成单文件安装程序 Setup.exe（启动器 + ui/Qt 运行时 + QIFW 安装包）。

.DESCRIPTION
  数据布局（与 src/launcher.cpp、src/setuphost.cpp 一致，全部小端）：

    [启动器 exe][bundle.zip][尾部索引]
    尾部索引 = magic 8B "OSUI1\0\0\0" | offset 8B | length 8B | sha256 32B | version 4B

  bundle.zip 内容：
    ui/        build-setup.ps1 的 dist/（外壳 exe + Qt 运行时 + qml/ + qt.conf）
    payload/installer.exe   QIFW 安装包

  运行时由启动器解到 %TEMP%\OrbbecSlicerSetup\<hash>\，再以 --payload 指向释放出来的
  安装包运行 ui/OrbbecSlicerSetup.exe。

  写完会重新打开输出文件解析索引并重算哈希，任何不一致即非零退出。

.PARAMETER LauncherExe
  构建脚本产出的 OrbbecSlicerSetupLauncher.exe（不依赖 Qt）。

.PARAMETER UiDir
  部署后的外壳目录（dist/）。

.PARAMETER InstallerExe
  binarycreator 产出的 QIFW 安装包。

.PARAMETER OutputPath
  输出 Setup.exe 路径；缺省与 InstallerExe 同目录，文件名把 -Installer.exe 换成 -Setup.exe。

.PARAMETER Version
  payload 版本（写入索引的 4 字节）；缺省从 InstallerExe 文件名解析。
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
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Fail "文件不存在: $p" }
}
if (-not (Test-Path -LiteralPath (Join-Path $UiDir 'OrbbecSlicerSetup.exe'))) {
    Fail "UiDir 里没有 OrbbecSlicerSetup.exe: $UiDir"
}

if (-not $Version) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($InstallerExe)
    $parts = $base -split '-'
    if ($parts.Count -ge 3) { $Version = $parts[1] }
}
if (-not $Version) { Fail '无法确定版本：请显式传 -Version' }
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
    if ($OutputPath -eq $p) { Fail '输出路径不能与输入文件相同' }
}

Write-Host "[package] 启动器: $LauncherExe"
Write-Host "[package] 界面目录: $UiDir"
if ($UninstallerExe) {
    $UninstallerExe = (Resolve-Path -LiteralPath $UninstallerExe).ProviderPath
    if (-not (Test-Path -LiteralPath $UninstallerExe -PathType Leaf)) { Fail "卸载器不存在: $UninstallerExe" }
    Write-Host "[package] 卸载器: $UninstallerExe"
} else {
    Write-Host "[package] 卸载器: （无，跳过部署）" -ForegroundColor Yellow
}
Write-Host "[package] 负载: $InstallerExe"
Write-Host "[package] 输出: $OutputPath"
Write-Host "[package] 版本: $Version"

# --- 1. 组装 bundle 目录并打成 zip ------------------------------------------
$work = Join-Path (Split-Path -Parent $OutputPath) ('.setup-bundle-' + [guid]::NewGuid().ToString('N'))
$uiStage = Join-Path $work 'ui'
$payloadStage = Join-Path $work 'payload'
$uninstStage = Join-Path $work 'uninstaller'
New-Item -ItemType Directory -Force -Path $uiStage, $payloadStage | Out-Null
try {
    Copy-Item -Path (Join-Path $UiDir '*') -Destination $uiStage -Recurse -Force
    Copy-Item -LiteralPath $InstallerExe -Destination (Join-Path $payloadStage 'installer.exe') -Force

    $tarItems = @('ui', 'payload')
    if ($UninstallerExe) {
        New-Item -ItemType Directory -Force -Path $uninstStage | Out-Null
        Copy-Item -LiteralPath $UninstallerExe -Destination (Join-Path $uninstStage 'OrbbecSlicerUninstaller.exe') -Force
        $tarItems += 'uninstaller'
    }

    $bundle = Join-Path $work 'bundle.zip'
    # Windows 自带的 tar.exe（bsdtar）支持 -a 按扩展名生成 zip。
    $tar = Start-Process -FilePath 'tar.exe' `
        -ArgumentList (@('-a', '-c', '-f', $bundle, '-C', $work) + $tarItems) `
        -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput (Join-Path $work 'tar.log') -RedirectStandardError (Join-Path $work 'tar.err')
    if ($tar.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $bundle)) {
        Get-Content -LiteralPath (Join-Path $work 'tar.err') -Encoding UTF8 -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host $_ }
        Fail "打包 bundle 失败（tar exit $($tar.ExitCode)）"
    }
    $bundleLen = (Get-Item -LiteralPath $bundle).Length
    Write-Host ("[package] bundle.zip: {0:N0} B" -f $bundleLen)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bundleHash = $sha.ComputeHash([System.IO.File]::ReadAllBytes($bundle)) } finally { $sha.Dispose() }

    # --- 2. 启动器 + bundle + 尾部索引 -------------------------------------
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

    # --- 3. 自检：解析尾部并重算 bundle 哈希 ------------------------------
    $trailerSize = 8 + 8 + 8 + 32 + 4
    $check = [System.IO.File]::OpenRead($OutputPath)
    try {
        $setupLen = $check.Length
        $expectLen = $launcherLen + $bundleLen + $trailerSize
        if ($setupLen -ne $expectLen) { Fail "输出大小不符: $setupLen（期望 $expectLen）" }
        $check.Seek($setupLen - $trailerSize, [System.IO.SeekOrigin]::Begin) | Out-Null
        $trailer = New-Object byte[] $trailerSize
        if ($check.Read($trailer, 0, $trailerSize) -ne $trailerSize) { Fail '尾部索引读取不完整' }
        if ([System.Text.Encoding]::ASCII.GetString($trailer, 0, 5) -ne 'OSUI1') { Fail '尾部 magic 不符' }
        $readOffset = [BitConverter]::ToInt64($trailer, 8)
        $readLength = [BitConverter]::ToInt64($trailer, 16)
        if ($readOffset -ne $launcherLen -or $readLength -ne $bundleLen) {
            Fail "尾部索引不符: offset=$readOffset/$launcherLen length=$readLength/$bundleLen"
        }
        $expect = New-Object byte[] 32
        [Array]::Copy($trailer, 24, $expect, 0, 32)
        if ([BitConverter]::ToString($expect) -ne [BitConverter]::ToString($bundleHash)) {
            Fail 'bundle SHA-256 自检失败'
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
    Write-Host ("[package] 完成: {0} = {1:N0} B（启动器 {2:N0} B + bundle {3:N0} B + 索引 {4} B）" -f `
            [System.IO.Path]::GetFileName($OutputPath), $result.setupBytes, $launcherLen, $bundleLen, $trailerSize)
    $result | ConvertTo-Json -Depth 3
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
exit 0
