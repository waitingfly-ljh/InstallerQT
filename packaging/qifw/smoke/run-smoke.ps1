#Requires -Version 5.1
<#
.SYNOPSIS
  QIFW 冒烟回路：打包 → 静默安装 → 哈希校验 → 静默卸载 → 校验清理。

.DESCRIPTION
  用 smoke/ 下的最小包把 binarycreator / installerbase / maintenancetool
  这条链路完整跑一遍，把 QIFW 本身的问题与真实 528 MB 产品树的问题解耦。

  每一步的耗时、归档格式、压缩级别与实际生效值都写入
  out/smoke/<时间戳>/run-smoke.log 与 result.json。

  安装目标与产物都在本仓库内的 out/smoke/<时间戳>/ 下；
  卸载后用 maintenancetool --purge，若目录仍残留（Windows 上进程占用会导致
  删不掉自身的 maintenancetool.exe），落盘的残留清单会记为 WARN，不算失败。

.PARAMETER Compression
  传给 binarycreator --ac 的压缩级别。QIFW 只接受 0/1/3/5/7/9，默认 5。

.PARAMETER ArchiveFormat
  传给 binarycreator --af 的归档格式，默认 7z。

.PARAMETER SkipUninstall
  只打包与安装，不卸载（用于手工查看安装结果）。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\packaging\qifw\smoke\run-smoke.ps1
  # 非默认压缩级别
  powershell -ExecutionPolicy Bypass -File .\packaging\qifw\smoke\run-smoke.ps1 -Compression 9
#>
[CmdletBinding()]
param(
    [ValidateSet(0, 1, 3, 5, 7, 9)][int]$Compression = 5,
    [ValidateSet('7z', 'zip', 'tar', 'tar.gz', 'tar.bz2', 'tar.xz', 'qbsp')][string]$ArchiveFormat = '7z',
    [switch]$SkipUninstall
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'toolchain\_common.ps1')

# 子进程输出与日志统一 UTF-8（无 BOM），避免其它工具把中文读成乱码
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$RepoRoot = Get-RepoRoot -StartDir $PSScriptRoot
$Manifest = Get-ToolchainManifest -RepoRoot $RepoRoot
$ToolchainRoot = Get-ToolchainRoot -Manifest $Manifest -RepoRoot $RepoRoot
$IfwBin = Resolve-RepoPath -RelativePath $Manifest.ifw.installDir -RepoRoot $RepoRoot | ForEach-Object { Join-Path $_ 'bin' }

$SmokeDir = Resolve-RepoPath 'packaging/qifw/smoke' -RepoRoot $RepoRoot
$ConfigXml = Join-Path $SmokeDir 'config\config.xml'
$PackagesDir = Join-Path $SmokeDir 'packages'
$DataDir = Join-Path $PackagesDir 'com.orbbec.smoke\data'

$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutDir = Resolve-RepoPath "packaging/qifw/out/smoke/$Stamp" -RepoRoot $RepoRoot
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$LogPath = Join-Path $OutDir 'run-smoke.log'
$InstallerPath = Join-Path $OutDir 'SmokeInstaller.exe'
$InstallDir = Join-Path $OutDir 'install'
# IFW 默认把元数据缓存写到 %LOCALAPPDATA%\cache\qt-installer-framework\<guid>，
# 那是仓库之外的位置。所有安装/卸载调用都用 --cp 指到本次输出目录。
$CacheDir = Join-Path $OutDir 'cache'
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null

$steps = New-Object System.Collections.Generic.List[object]
$failures = New-Object System.Collections.Generic.List[string]

function Add-Step {
    param([string]$Name, [bool]$Ok, [string]$Detail, [double]$Seconds = 0)
    $steps.Add([pscustomobject]@{ Step = $Name; Ok = $Ok; Detail = $Detail; Seconds = [math]::Round($Seconds, 2) })
    if ($Ok) { Write-Both ("{0} 完成（{1}s）" -f $Name, [math]::Round($Seconds, 2)) 'OK' }
    else {
        Write-Both ("{0} 失败：{1}" -f $Name, $Detail) 'ERROR'
        $failures.Add("${Name}: $Detail")
    }
}

function Write-Both {
    param([string]$Message, [string]$Level = 'INFO')
    Write-Log $Message $Level
    $line = "[{0}] [{1}] {2}" -f (Get-Date).ToString('HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

Write-Both "仓库根: $RepoRoot" 'INFO'
Write-Both "工具根: $ToolchainRoot" 'INFO'
Write-Both "输出目录: $OutDir" 'INFO'

# --- 0. 前置 --------------------------------------------------------------
$binarycreator = Join-Path $IfwBin 'binarycreator.exe'
$installerbase = Join-Path $IfwBin 'installerbase.exe'
foreach ($exe in @($binarycreator, $installerbase)) {
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Both "缺少 $exe，先运行 toolchain\install-toolchain.ps1" 'ERROR'
        exit 1
    }
}
if (-not (Test-Path -LiteralPath $ConfigXml)) { Write-Both "缺少 $ConfigXml" 'ERROR'; exit 1 }

# 预期文件清单：优先用随包入库的 manifest（固定基准，缺少文件时能报出是哪个），
# 没有 manifest 时才回退到"以 data/ 现状为准"。
$payloadManifest = Join-Path $SmokeDir 'expected-payload.json'
if (Test-Path -LiteralPath $payloadManifest) {
    $manifestDoc = Get-Content -LiteralPath $payloadManifest -Raw -Encoding UTF8 | ConvertFrom-Json
    $expected = @(foreach ($f in $manifestDoc.files) {
            [pscustomobject]@{ Rel = $f.path; Hash = $f.sha256.ToLower(); Size = $f.size }
        })
    Write-Both "预期文件 $($expected.Count) 个（来自 expected-payload.json）" 'INFO'
}
else {
    $expected = @(Get-ChildItem -LiteralPath $DataDir -Recurse -File | ForEach-Object {
            [pscustomobject]@{
                Rel  = $_.FullName.Substring($DataDir.Length).TrimStart('\')
                Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower()
                Size = $_.Length
            }
        })
    Write-Both "预期文件 $($expected.Count) 个（来自 data/ 现状，未找到 expected-payload.json）" 'WARN'
}
if ($expected.Count -lt 3) { Write-Both '预期清单少于 3 个文件，冒烟包不足以验证' 'ERROR'; exit 1 }

# --- 1. 打包 --------------------------------------------------------------
Write-Both '== 1. binarycreator 打包 ==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
# -c 要指向 config.xml 文件本身（指向目录会直接打印用法并退出 1）
# -t 必须显式给出 installerbase.exe
$r = Invoke-Native -FilePath $binarycreator -ArgumentList @(
    '--offline-only', '-c', $ConfigXml, '-p', $PackagesDir, '-t', $installerbase,
    '--af', $ArchiveFormat, '--ac', "$Compression", '-v', $InstallerPath
) -LogPath $LogPath
$sw.Stop()
$built = (Test-Path -LiteralPath $InstallerPath)
$size = if ($built) { (Get-Item -LiteralPath $InstallerPath).Length } else { 0 }
Add-Step '打包' ($r.ExitCode -eq 0 -and $built) "exit=$($r.ExitCode), 产物=$(if ($built) { "$size B" } else { '不存在' })" $sw.Elapsed.TotalSeconds
if (-not ($r.ExitCode -eq 0 -and $built)) {
    Write-Both '打包失败，后续步骤跳过。完整输出见 run-smoke.log' 'ERROR'
    exit 1
}

# binarycreator -v 不回显实际压缩级别，只回显归档路径与大小；
# 压缩级别以"传入参数 + 产物字节数 + SHA-256"三者一起记录，由调用方横向比较。
$archiveEcho = ($r.Combined -split "`r?`n" | Where-Object { $_ -match 'Appending|Creating the binary' } | Select-Object -First 3) -join ' | '
Write-Both "调用参数: --offline-only --af $ArchiveFormat --ac $Compression" 'INFO'
Write-Both "binarycreator 回显: $(if ($archiveEcho) { $archiveEcho } else { '（无归档信息回显）' })" 'INFO'
Write-Both ("产物: {0} = {1:N0} B" -f (Split-Path -Leaf $InstallerPath), $size) 'INFO'

# --- 2. 静默安装 ----------------------------------------------------------
Write-Both '== 2. 静默安装 ==' 'STEP'
if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$sw = [System.Diagnostics.Stopwatch]::StartNew()
# --platform minimal + -c --confirm-command --accept-licenses --accept-messages 为无头约定
$r = Invoke-Native -FilePath $InstallerPath -ArgumentList @(
    '--platform', 'minimal', 'in', '-c', '--confirm-command', '--accept-licenses', '--accept-messages',
    '--cp', $CacheDir, '-t', $InstallDir
) -LogPath $LogPath
$sw.Stop()
Add-Step '安装' ($r.ExitCode -eq 0) "exit=$($r.ExitCode)" $sw.Elapsed.TotalSeconds
if ($r.ExitCode -ne 0) {
    Write-Both '安装失败，后续步骤跳过。' 'ERROR'
    exit 1
}

# --- 3. 校验安装结果 ------------------------------------------------------
Write-Both '== 3. 校验安装结果 ==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$missing = New-Object System.Collections.Generic.List[string]
$mismatch = New-Object System.Collections.Generic.List[string]
foreach ($e in $expected) {
    $target = Join-Path $InstallDir ($e.Rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $target)) { $missing.Add($e.Rel); continue }
    $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $e.Hash) { $mismatch.Add("$($e.Rel) 期望 $($e.Hash) / 实际 $actual") }
}
$sw.Stop()
$problems = @()
if ($missing.Count) { $problems += ("缺失 " + $missing.Count + " 个: " + ($missing -join ', ')) }
if ($mismatch.Count) { $problems += ("哈希不符 " + $mismatch.Count + " 个: " + ($mismatch -join '; ')) }
# 快捷方式：installscript.qs 会在 @StartMenuDir@ 下建一个 .lnk，安装后必须存在、卸载后必须消失。
# 注意 QIFW 卸载只删它自己登记的快捷方式，不会清空整个 StartMenuDir 目录。
$shortcutDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\OrbbecSlicerQifwSmoke'
$shortcutPath = Join-Path $shortcutDir 'OrbbecSlicer QIFW Smoke.lnk'
$shortcutExistedBefore = Test-Path -LiteralPath $shortcutPath

Add-Step '校验安装结果' ($problems.Count -eq 0) ($(if ($problems.Count -eq 0) { "$($expected.Count) 个文件全部匹配" } else { $problems -join ' / ' })) $sw.Elapsed.TotalSeconds
$shortcutMade = Test-Path -LiteralPath $shortcutPath
Add-Step '校验快捷方式' $shortcutMade ($(if ($shortcutMade) { $shortcutPath } else { "未创建: $shortcutPath" }))
if ($problems.Count -gt 0) {
    if ($missing.Count) { Write-Both ("缺失的相对路径: " + ($missing -join ', ')) 'ERROR' }
    if ($mismatch.Count) { $mismatch | ForEach-Object { Write-Both "哈希不符: $_" 'ERROR' } }
    Write-Both '安装结果与 data/ 不一致，跳过卸载以便保留现场。' 'ERROR'
    Write-Both "现场目录: $InstallDir" 'ERROR'
    Write-JsonFile -Path (Join-Path $OutDir 'result.json') -InputObject $steps -Depth 4
    exit 1
}

# --- 4. 静默卸载 ----------------------------------------------------------
$uninstallSeconds = 0
$residue = @()
if ($SkipUninstall) {
    Write-Both '按要求跳过卸载（-SkipUninstall），安装目录保留' 'WARN'
    Add-Step '卸载' $true '跳过（-SkipUninstall）'
}
else {
    Write-Both '== 4. 静默卸载 ==' 'STEP'
    $mt = Join-Path $InstallDir 'maintenancetool.exe'
    if (-not (Test-Path -LiteralPath $mt)) {
        Add-Step '卸载' $false "找不到 $mt"
    }
    else {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Native -FilePath $mt -ArgumentList @(
            '--platform', 'minimal', 'pr', '-c', '--confirm-command', '--accept-licenses', '--accept-messages',
            '--cp', $CacheDir
        ) -LogPath $LogPath
        $sw.Stop()
        $uninstallSeconds = $sw.Elapsed.TotalSeconds

        # purge 后 maintenancetool 可能因自身被占用而残留一小段时间
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline) {
            $left = @(Get-ChildItem -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue)
            if ($left.Count -eq 0) { break }
            Start-Sleep -Milliseconds 500
        }
        $left = @(Get-ChildItem -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName.Substring($InstallDir.Length).TrimStart('\') })
        $payloadLeft = @($left | Where-Object { $_ -like 'payload*' })
        Add-Step '卸载' ($r.ExitCode -eq 0 -and $payloadLeft.Count -eq 0) "exit=$($r.ExitCode), 残留 $($left.Count) 项" $uninstallSeconds
        if ($left.Count -gt 0) {
            $residue = $left
            Write-Both ("残留（多为进程占用自身 exe）: " + ($left -join ', ')) 'WARN'
        }

        Write-Both '== 5. 校验清理 ==' 'STEP'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $badLeft = @($expected | Where-Object { Test-Path -LiteralPath (Join-Path $InstallDir ($_.Rel -replace '/', '\')) })
        Add-Step '校验清理' ($badLeft.Count -eq 0) ($(if ($badLeft.Count) { "仍存在: " + (($badLeft | ForEach-Object Rel) -join ', ') } else { '预期文件已全部清除' })) $sw.Elapsed.TotalSeconds
        $shortcutLeft = Test-Path -LiteralPath $shortcutPath
        Add-Step '校验快捷方式清除' (-not $shortcutLeft) ($(if ($shortcutLeft) { "仍存在: $shortcutPath" } else { '快捷方式已删除' }))
    }
}

# --- 6. 摘要 --------------------------------------------------------------
$result = [ordered]@{
    timestamp        = (Get-Date).ToString('o')
    repoRoot         = $RepoRoot
    qifwVersion      = $Manifest.ifw.version
    binarycreator    = $binarycreator
    archiveFormat    = $ArchiveFormat
    compression      = $Compression
    installerPath    = $InstallerPath
    installerBytes   = $size
    installerSha256  = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLower()
    installDir       = $InstallDir
    shortcutPath     = $shortcutPath
    shortcutExistedBefore = $shortcutExistedBefore
    expectedFiles    = $expected.Count
    uninstallSeconds = [math]::Round($uninstallSeconds, 2)
    residue          = $residue
    steps            = $steps
    failures         = $failures
    log              = $LogPath
}
$resultPath = Join-Path $OutDir 'result.json'
Write-JsonFile -Path $resultPath -InputObject ([pscustomobject]$result)

Write-Both "结果: $resultPath" 'INFO'
if ($failures.Count -gt 0) {
    Write-Both "冒烟回路失败 $($failures.Count) 个步骤" 'ERROR'
    exit 1
}
Write-Both '冒烟回路全部通过' 'OK'
exit 0
