#Requires -Version 5.1
<#
.SYNOPSIS
  把 OrbbecSlicer 的 staging 树打成 QIFW 离线安装程序，并生成 SHA-256 校验。

.DESCRIPTION
  只读引用原项目的两个位置：
    - <StageRoot>           产品 staging 树（默认 <UpstreamRepo>\build\presets\windows-release\OrbbecSlicer）
    - <UpstreamRepo>\version.inc 的 set(SLICER_APP_VERSION "...")

  本仓库的写入只有 out/product/<时间戳>/ 与 out/staging-work/<时间戳>/：
    staging-work 是 staging 树的副本（QIFW 要求 packages/<id>/data/ 作为数据目录，
    直接在原树上构建会要求在原项目里建目录，因此先复制再打包）。

  步骤：
    1. 解析版本（缺少版本来源 ⇒ 失败，不生成产物）
    2. 对 staging 树做前后快照（文件数 + 内容摘要），不一致即中止
    3. 生成 config.xml / package.xml（含图标、StartMenuDir、TargetDir）
    4. binarycreator --offline-only 打包
    5. 生成 <产物>.sha256，重新计算并比对
    6. 静默安装到临时目录，逐文件比对安装结果与 staging（差异清单必须为空）

.PARAMETER StageRoot
  staging 树路径。必须是绝对路径且存在；只读。
  留空（默认）时解析为 <UpstreamRepo>\build\presets\windows-release\OrbbecSlicer，
  即原项目 CMake preset 的安装产物（原项目已不再提供 packaging\windows\dist）。

.PARAMETER UpstreamRepo
  原项目根（用于读 version.inc）。只读。

.PARAMETER Compression
  binarycreator --ac 级别，只接受 0/1/3/5/7/9，默认 5。

.PARAMETER SkipInstallVerify
  跳过第 6 步（安装后逐文件比对）。528 MB / 1.3 万文件时该步骤耗时较长。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\packaging\qifw\product\build-product.ps1
  powershell -ExecutionPolicy Bypass -File .\packaging\qifw\product\build-product.ps1 -Compression 9 -SkipInstallVerify
#>
[CmdletBinding()]
param(
    # 留空 ⇒ 依次取环境变量 ORBBEC_STAGE_ROOT、<UpstreamRepo>\build\presets\windows-release\OrbbecSlicer（在下方解析）
    [string]$StageRoot = '',
    # 留空 ⇒ 取环境变量 ORBBEC_UPSTREAM_REPO，都没有才回落到 D:\Orbbec\orbbecslicer（在下方解析）
    [string]$UpstreamRepo = '',
    [ValidateSet(0, 1, 3, 5, 7, 9)][int]$Compression = 5,
    [string]$ArchiveFormat = '7z',
    [switch]$SkipInstallVerify,
    # 8.4：不构建外壳，直接交付 QIFW 原生包（deliverable = "qifw-native"）。
    [switch]$WithoutSetupUi
)

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'toolchain\_common.ps1')

# 子进程与日志统一 UTF-8，避免其它工具把中文读成乱码
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$RepoRoot = Get-RepoRoot -StartDir $PSScriptRoot
$Manifest = Get-ToolchainManifest -RepoRoot $RepoRoot
$IfwBin = Join-Path (Resolve-RepoPath -RelativePath $Manifest.ifw.installDir -RepoRoot $RepoRoot) 'bin'
$binarycreator = Join-Path $IfwBin 'binarycreator.exe'
$installerbase = Join-Path $IfwBin 'installerbase.exe'

# 路径解析顺序：显式参数 > 环境变量 > 向上查找 version.inc（仓库被放进上游仓库时）> 本机默认值。
# 换一台机器、或把本仓库挪进 orbbecslicer 目录下，命令本身都不用改。
if ([string]::IsNullOrWhiteSpace($UpstreamRepo)) {
    if (-not [string]::IsNullOrWhiteSpace($env:ORBBEC_UPSTREAM_REPO)) {
        $UpstreamRepo = $env:ORBBEC_UPSTREAM_REPO
    }
    else {
        # 从仓库根向上找含 version.inc 的目录（本仓库被放进上游仓库时的常见摆放）
        $UpstreamRepo = Find-UpstreamRepo -StartDir $RepoRoot
        if ([string]::IsNullOrWhiteSpace($UpstreamRepo)) { $UpstreamRepo = 'D:\Orbbec\orbbecslicer' }
    }
}
# 默认 staging = 原项目 CMake preset 的安装产物（原项目已删除 packaging\windows\dist）
if ([string]::IsNullOrWhiteSpace($StageRoot)) {
    $StageRoot = if (-not [string]::IsNullOrWhiteSpace($env:ORBBEC_STAGE_ROOT)) { $env:ORBBEC_STAGE_ROOT }
    else { Join-Path $UpstreamRepo 'build\presets\windows-release\OrbbecSlicer' }
}
$UpstreamRepo = $UpstreamRepo.TrimEnd('\')
$StageRoot = $StageRoot.TrimEnd('\')

$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutDir = Resolve-RepoPath "packaging/qifw/out/product/$Stamp" -RepoRoot $RepoRoot
$WorkRoot = Resolve-RepoPath "packaging/qifw/out/staging-work/$Stamp" -RepoRoot $RepoRoot
New-Item -ItemType Directory -Force -Path $OutDir, $WorkRoot | Out-Null
$LogPath = Join-Path $OutDir 'build-product.log'

$steps = New-Object System.Collections.Generic.List[object]
$failures = New-Object System.Collections.Generic.List[string]

function Write-Both {
    param([string]$Message, [string]$Level = 'INFO')
    Write-Log $Message $Level
    Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value ("[{0}] [{1}] {2}" -f (Get-Date).ToString('HH:mm:ss'), $Level, $Message)
}

function Add-Step {
    param([string]$Name, [bool]$Ok, [string]$Detail, [double]$Seconds = 0)
    $steps.Add([pscustomobject]@{ Step = $Name; Ok = $Ok; Detail = $Detail; Seconds = [math]::Round($Seconds, 2) })
    if ($Ok) { Write-Both ("{0} 完成（{1}s）" -f $Name, [math]::Round($Seconds, 2)) 'OK' }
    else { Write-Both ("{0} 失败：{1}" -f $Name, $Detail) 'ERROR'; $failures.Add("${Name}: $Detail") }
}

function Exit-Fail {
    param([string]$Why)
    Write-Both $Why 'ERROR'
    Write-JsonFile -Path (Join-Path $OutDir 'result.json') -InputObject ([pscustomobject]@{ steps = $steps; failures = $failures }) -Depth 4
    exit 1
}

function Get-TreeDigest {
    <# 对目录做内容摘要：按相对路径排序后逐个累加 SHA-256，最后取整体 SHA-256。只读。 #>
    param([Parameter(Mandatory)][string]$Path)
    $sb = New-Object System.Text.StringBuilder
    $files = Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Sort-Object FullName
    $total = [int64]0
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($Path.Length).TrimStart('\') -replace '\\', '/'
        $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
        [void]$sb.AppendLine("$rel`t$($f.Length)`t$h")
        $total += $f.Length
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sb.ToString()))).Replace('-', '').ToLower()
    }
    finally { $sha.Dispose() }
    return [pscustomobject]@{ Path = $Path; FileCount = @($files).Count; TotalBytes = $total; Digest = $digest }
}

function Get-ChangedFileList {
    <# 对比打包前明细与给定目录，列出 删除/大小变化/内容变化/新增 的文件（相对 staging 的路径）。只读。 #>
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][hashtable]$Before, [Parameter(Mandatory)][string]$BeforeRoot)
    $out = New-Object System.Collections.Generic.List[string]
    $now = @{ }
    foreach ($f in (Get-ChildItem -LiteralPath $Dir -Recurse -File -Force)) {
        $now[$f.FullName.Substring($Dir.Length).TrimStart('\')] = $f
    }
    foreach ($p in $Before.Keys) {
        $rel = $p.Substring($BeforeRoot.Length).TrimStart('\')
        if (-not $now.ContainsKey($rel)) { $out.Add("删除 $($rel -replace '\\', '/')"); continue }
        $f = $now[$rel]
        if ($f.Length -ne $Before[$p].Size) { $out.Add("大小变化 $($rel -replace '\\', '/')"); continue }
        $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
        if ($h -ne $Before[$p].Hash) { $out.Add("内容变化 $($rel -replace '\\', '/')") }
    }
    foreach ($rel in $now.Keys) {
        if (-not $Before.ContainsKey((Join-Path $BeforeRoot $rel))) { $out.Add("新增 $($rel -replace '\\', '/')") }
    }
    return , $out
}

Write-Both "仓库根: $RepoRoot" 'INFO'
Write-Both "staging: $StageRoot" 'INFO'
Write-Both "输出: $OutDir" 'INFO'

# --- 0. 前置（含工具链登记门禁）--------------------------------------------
foreach ($exe in @($binarycreator, $installerbase)) {
    if (-not (Test-Path -LiteralPath $exe)) { Exit-Fail "缺少 $exe；先运行 toolchain\install-toolchain.ps1" }
}
if (-not (Test-Path -LiteralPath $StageRoot)) { Exit-Fail "staging 树不存在: $StageRoot" }
if (-not [System.IO.Path]::IsPathRooted($StageRoot)) { Exit-Fail "StageRoot 必须是绝对路径: $StageRoot" }

# 构建只认 manifest 登记的工具链：版本与登记值不符、或工具缺失即中止（不放行"能用就行"）
Write-Both '== 0. 工具链登记核对 ==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$toolchain = Get-QifwToolchainStatus -Manifest $Manifest -RepoRoot $RepoRoot
$sw.Stop()
Add-Step '工具链核对' $toolchain.Available (
    "Qt $($toolchain.QtVersion) $($toolchain.Architecture) / QIFW $($toolchain.IfwVersion)（清单 sha256 $($toolchain.ArchiveSha256)）" +
    $(if ($toolchain.Reason) { " | 不可用: $($toolchain.Reason)" } else { '' })) $sw.Elapsed.TotalSeconds
if ($toolchain.Warning) { Write-Both "可选缺失（不阻断）: $($toolchain.Warning)" 'WARN' }
if (-not $toolchain.Available) { Exit-Fail '工具链与 manifest 登记不一致，已中止（不打默认版本、不换路径凑合）' }

# --- 1. 版本（5.1）--------------------------------------------------------
Write-Both '== 1. 解析版本 ==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$versionInc = Join-Path $UpstreamRepo 'version.inc'
if (-not (Test-Path -LiteralPath $versionInc)) {
    Exit-Fail "找不到版本来源: $versionInc（不使用硬编码默认版本）"
}
# 锚定行首的 set(SLICER_APP_VERSION "x")，避免误匹配 SLICER_APP_VERSION_MATCH 之类的派生行
$versionLine = Select-String -Path $versionInc -Pattern '^\s*set\(\s*SLICER_APP_VERSION\s+"([^"]+)"\s*\)' |
    Select-Object -First 1
if (-not $versionLine) { Exit-Fail "version.inc 中未找到 set(SLICER_APP_VERSION \"...\"): $versionInc" }
$appVersion = $versionLine.Matches[0].Groups[1].Value.Trim()
$sw.Stop()
Add-Step '解析版本' ($appVersion -ne '') "SLICER_APP_VERSION=$appVersion（$versionInc 第 $($versionLine.LineNumber) 行，只读）" $sw.Elapsed.TotalSeconds

$productName = 'OrbbecSlicer'
$componentId = 'com.orbbec.orbbecslicer'
$archTag = 'x64'
# 产物名：产品名-版本-架构-Installer.exe；版本里允许 -beta.N
$installerName = "{0}-{1}-{2}-Installer.exe" -f $productName, $appVersion, $archTag
if ($installerName -notmatch '^[A-Za-z0-9._-]+\.exe$') { Exit-Fail "产物名含非法字符: $installerName" }
$installerPath = Join-Path $OutDir $installerName

# --- 2. 打包前快照（5.2）--------------------------------------------------
Write-Both '== 2. staging 树快照（打包前）==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$snapBefore = Get-TreeDigest -Path $StageRoot
$sw.Stop()
Add-Step '快照（前）' $true ("{0} 文件 / {1:N0} B / {2}" -f $snapBefore.FileCount, $snapBefore.TotalBytes, $snapBefore.Digest) $sw.Elapsed.TotalSeconds
# 逐文件明细用于打包后定位"改动的是哪个文件"（快照本身不进 result.json，太大）
$filesBefore = @{}
foreach ($f in (Get-ChildItem -LiteralPath $StageRoot -Recurse -File -Force)) {
    $filesBefore[$f.FullName] = [pscustomobject]@{ Size = $f.Length; Hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower() }
}

# --- 3. 装配 packages（5.2）------------------------------------------------
Write-Both '== 3. 复制 staging 到 packages/<id>/data ==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$packagesDir = Join-Path $WorkRoot 'packages'
$pkgDir = Join-Path $packagesDir $componentId
$metaDir = Join-Path $pkgDir 'meta'
$dataDir = Join-Path $pkgDir 'data'
$configDir = Join-Path $WorkRoot 'config'
# 先建 data/ 再复制：打包后它才是已存在目录，Get-TreeDigest 才能对它做校验
New-Item -ItemType Directory -Force -Path $dataDir, $metaDir, $configDir | Out-Null
# robocopy 比 Copy-Item 快得多，且 /MIR 保证 data/ 与 staging 完全一致
$rc = Invoke-Native -FilePath 'robocopy.exe' -ArgumentList @($StageRoot, $dataDir, '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:2', '/W:1') -LogPath $LogPath
# robocopy: 0-7 为成功
if ($rc.ExitCode -gt 7) { Exit-Fail "robocopy 复制 staging 失败 (exit $($rc.ExitCode))" }
$sw.Stop()
$copied = Get-ChildItem -LiteralPath $dataDir -Recurse -File -Force
Add-Step '复制 staging' ($copied.Count -eq $snapBefore.FileCount) ("{0} 文件（源 {1}）" -f $copied.Count, $snapBefore.FileCount) $sw.Elapsed.TotalSeconds

# 图标从 staging 树里取（只读），拷进 config/ 供 installerbase 使用
$iconSrc = Join-Path $StageRoot 'resources\images\app_logo.ico'
$iconName = ''
if (Test-Path -LiteralPath $iconSrc) {
    Copy-Item -LiteralPath $iconSrc -Destination (Join-Path $configDir 'app_logo.ico') -Force
    $iconName = 'app_logo'
}
$iconXml = if ($iconName) { "    <InstallerApplicationIcon>$iconName</InstallerApplicationIcon>`r`n" } else { '' }

$configXmlPath = Join-Path $configDir 'config.xml'
$configXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<Installer>
    <Name>$productName</Name>
    <Version>$appVersion</Version>
    <Title>$productName $appVersion</Title>
    <Publisher>Orbbec</Publisher>
    <StartMenuDir>$productName</StartMenuDir>
    <TargetDir>@ApplicationsDir@/$productName</TargetDir>
$iconXml    <!-- 离线安装器：不配置 RemoteRepositories -->
    <AllowNonAsciiCharacters>true</AllowNonAsciiCharacters>
    <AllowSpaceInPath>true</AllowSpaceInPath>
</Installer>
"@
[System.IO.File]::WriteAllText($configXmlPath, $configXml, (New-Object System.Text.UTF8Encoding($false)))

$packageXmlPath = Join-Path $metaDir 'package.xml'
$packageXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<Package>
    <DisplayName>$productName</DisplayName>
    <Description>$productName 桌面应用（含 OCCT 与运行时 DLL）。</Description>
    <Version>$appVersion</Version>
    <ReleaseDate>$(Get-Date -Format 'yyyy-MM-dd')</ReleaseDate>
    <Name>$componentId</Name>
    <Default>true</Default>
    <ForcedInstallation>true</ForcedInstallation>
</Package>
"@
[System.IO.File]::WriteAllText($packageXmlPath, $packageXml, (New-Object System.Text.UTF8Encoding($false)))
Write-Both "config.xml / package.xml 已生成（图标: $(if ($iconName) { 'app_logo.ico' } else { '无' })）" 'INFO'

# --- 4. 打包（5.3）--------------------------------------------------------
Write-Both '== 4. binarycreator 打包 ==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-Native -FilePath $binarycreator -ArgumentList @(
    '--offline-only', '-c', $configXmlPath, '-p', $packagesDir, '-t', $installerbase,
    '--af', $ArchiveFormat, '--ac', "$Compression", $installerPath
) -LogPath $LogPath
$sw.Stop()
$built = Test-Path -LiteralPath $installerPath
Add-Step '打包' ($r.ExitCode -eq 0 -and $built) "exit=$($r.ExitCode), 产物=$(if ($built) { "{0:N0} B" -f (Get-Item $installerPath).Length } else { '不存在' })" $sw.Elapsed.TotalSeconds
if (-not ($r.ExitCode -eq 0 -and $built)) { Exit-Fail '打包失败' }
$installerBytes = (Get-Item -LiteralPath $installerPath).Length
$buildSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)

# --- 5. 打包后快照（5.2）--------------------------------------------------
Write-Both '== 5. staging 树快照（打包后）==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$snapAfter = Get-TreeDigest -Path $StageRoot
$same = ($snapBefore.FileCount -eq $snapAfter.FileCount) -and
        ($snapBefore.TotalBytes -eq $snapAfter.TotalBytes) -and
        ($snapBefore.Digest -eq $snapAfter.Digest)
if ($same) {
    $sw.Stop()
    Add-Step '快照（后）并比对' $true ("{0} 文件 / {1:N0} B / {2}" -f $snapAfter.FileCount, $snapAfter.TotalBytes, $snapAfter.Digest) $sw.Elapsed.TotalSeconds
}
else {
    # 指出具体被改动的文件：新增 / 删除 / 大小或内容变化
    $changed = Get-ChangedFileList -Dir $StageRoot -Before $filesBefore -BeforeRoot $StageRoot
    $sw.Stop()
    $changedPath = Join-Path $OutDir 'staging-changes.txt'
    $changed | Set-Content -LiteralPath $changedPath -Encoding UTF8
    Remove-Item -LiteralPath $installerPath, "$installerPath.sha256" -Force -ErrorAction SilentlyContinue
    Add-Step '快照（后）并比对' $false ("{0} 文件 / {1:N0} B / {2}；改动 {3} 项{4}（清单 {5}）" -f `
            $snapAfter.FileCount, $snapAfter.TotalBytes, $snapAfter.Digest, $changed.Count,
        $(if ($changed.Count) { ': ' + (($changed | Select-Object -First 10) -join '; ') } else { '' }), $changedPath) $sw.Elapsed.TotalSeconds
    Exit-Fail 'staging 树在打包前后发生变化（脚本不应写入原项目），已中止；产物作废，请先查明改动来源'
}

# --- 5b. 工作副本核对 -------------------------------------------------------
# packages/ 里那份 data/ 才是真正进产物的内容，staging 没变不代表它没变。
# 复制完成到打包结束之间若被改动（或复制本身出错），产物内容就与 staging 不符，
# 必须按「输入树被意外改动」同样处理：非零退出、指出文件、作废产物。
Write-Both '== 5b. 工作副本 data/ 核对 ==' 'STEP'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$snapWork = Get-TreeDigest -Path $dataDir
$sameWork = ($snapWork.FileCount -eq $snapBefore.FileCount) -and
            ($snapWork.TotalBytes -eq $snapBefore.TotalBytes) -and
            ($snapWork.Digest -eq $snapBefore.Digest)
if ($sameWork) {
    $sw.Stop()
    Add-Step '工作副本核对' $true ("{0} 文件 / {1:N0} B / {2}（与 staging 一致）" -f $snapWork.FileCount, $snapWork.TotalBytes, $snapWork.Digest) $sw.Elapsed.TotalSeconds
}
else {
    $workChanged = Get-ChangedFileList -Dir $dataDir -Before $filesBefore -BeforeRoot $StageRoot
    $sw.Stop()
    $changedPath = Join-Path $OutDir 'staging-changes.txt'
    $workChanged | Set-Content -LiteralPath $changedPath -Encoding UTF8
    Add-Step '工作副本核对' $false ("{0} 文件 / {1:N0} B / {2}；与 staging 差异 {3} 项{4}（清单 {5}）" -f `
            $snapWork.FileCount, $snapWork.TotalBytes, $snapWork.Digest, $workChanged.Count,
        $(if ($workChanged.Count) { ': ' + (($workChanged | Select-Object -First 10) -join '; ') } else { '' }), $changedPath) $sw.Elapsed.TotalSeconds
    # 作废本次产物与校验文件，避免"退出非零但 exe 还在、被误拿去发布"
    Remove-Item -LiteralPath $installerPath, "$installerPath.sha256" -Force -ErrorAction SilentlyContinue
    Exit-Fail '工作副本 data/ 在打包过程中被改动，产物已作废；请查明改动来源后重跑'
}

# --- 6. SHA-256（5.4）-----------------------------------------------------
Write-Both '== 6. 生成并复核 SHA-256 ==' 'STEP'
$sha1 = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLower()
$shaFile = "$installerPath.sha256"
# 与 Qt 官方 .sha256 相同的格式：<hash> *<文件名>
[System.IO.File]::WriteAllText($shaFile, "$sha1 *$installerName`n", (New-Object System.Text.ASCIIEncoding))
$recomputed = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash.ToLower()
$fromFile = (Get-Content -LiteralPath $shaFile -Raw).Split(' ')[0].Trim().ToLower()
Add-Step 'SHA-256' ($sha1 -eq $recomputed -and $sha1 -eq $fromFile) ("$sha1（文件 $shaFile）")
$nameOk = ($installerName -match [regex]::Escape($productName)) -and ($installerName -match [regex]::Escape($appVersion)) -and ($installerName -match [regex]::Escape($archTag))
Add-Step '产物命名' $nameOk $installerName

# --- 6b. 构建外壳（8.1）与合成交付物（8.2）---------------------------------
$setupPath = $null
$setupName = $null
$setupBytes = 0
if ($WithoutSetupUi) {
    Write-Both '按要求跳过外壳（-WithoutSetupUi）：交付 QIFW 原生包' 'WARN'
    $deliverable = 'qifw-native'
} else {
    Write-Both '== 6b. 构建安装器外壳 ==' 'STEP'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $shellScript = Join-Path $RepoRoot 'packaging\qifw\setup-ui\build-setup.ps1'
    if (-not (Test-Path -LiteralPath $shellScript)) {
        Add-Step '构建外壳' $false "找不到 build-setup.ps1: $shellScript" 0
        Exit-Fail '外壳源码不完整，已中止（不产出 Setup.exe）'
    }
    $r = Invoke-Native -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $shellScript,
        '-Version', $appVersion, '-Selftest'
    ) -LogPath $LogPath
    $sw.Stop()
    $shellExe = Join-Path $RepoRoot 'packaging\qifw\setup-ui\dist\OrbbecSlicerSetup.exe'
    $shellOk = ($r.ExitCode -eq 0) -and (Test-Path -LiteralPath $shellExe)
    Add-Step '构建外壳' $shellOk "exit=$($r.ExitCode), exe=$(if ($shellOk) { "{0:N0} B" -f (Get-Item $shellExe).Length } else { '不存在' })" $sw.Elapsed.TotalSeconds
    if (-not $shellOk) {
        # 外壳构建失败：默认中止，且不产出 Setup.exe（Installer.exe 作为中间产物保留）。
        Exit-Fail "外壳构建失败（日志见 $LogPath）"
    }

    Write-Both '== 6c. 合成单文件 Setup.exe ==' 'STEP'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $setupName = "{0}-{1}-{2}-Setup.exe" -f $productName, $appVersion, $archTag
    $setupPath = Join-Path $OutDir $setupName
    $packScript = Join-Path $RepoRoot 'packaging\qifw\setup-ui\package-setup.ps1'
    $launcherExe = Join-Path $RepoRoot 'packaging\qifw\setup-ui\build\OrbbecSlicerSetupLauncher.exe'
    $uninstallerExe = Join-Path $RepoRoot 'packaging\qifw\setup-ui\build\OrbbecSlicerUninstaller.exe'
    $uiDir = Join-Path $RepoRoot 'packaging\qifw\setup-ui\dist'
    if (-not (Test-Path -LiteralPath $launcherExe)) {
        Add-Step '合成交付物' $false "找不到启动器: $launcherExe" 0
        Exit-Fail '启动器缺失，已中止（不产出 Setup.exe）'
    }
    if (-not (Test-Path -LiteralPath $uninstallerExe)) {
        Add-Step '合成交付物' $false "找不到卸载器: $uninstallerExe" 0
        Exit-Fail '卸载器缺失，已中止（不产出 Setup.exe）'
    }
    $r = Invoke-Native -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $packScript,
        '-LauncherExe', $launcherExe, '-UiDir', $uiDir, '-InstallerExe', $installerPath,
        '-UninstallerExe', $uninstallerExe,
        '-OutputPath', $setupPath, '-Version', $appVersion
    ) -LogPath $LogPath
    $sw.Stop()
    $setupOk = ($r.ExitCode -eq 0) -and (Test-Path -LiteralPath $setupPath)
    if ($setupOk) { $setupBytes = (Get-Item -LiteralPath $setupPath).Length }
    Add-Step '合成交付物' $setupOk "exit=$($r.ExitCode), 产物=$(if ($setupOk) { "{0:N0} B" -f $setupBytes } else { '不存在' })" $sw.Elapsed.TotalSeconds
    if (-not $setupOk) {
        Remove-Item -LiteralPath $setupPath, "$setupPath.sha256" -Force -ErrorAction SilentlyContinue
        Exit-Fail "合成 Setup.exe 失败（日志见 $LogPath）"
    }
    $setupSha = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLower()
    [System.IO.File]::WriteAllText("$setupPath.sha256", "$setupSha *$setupName`n", (New-Object System.Text.ASCIIEncoding))
    $deliverable = 'setup-shell'
    Write-Both ("交付物: {0} = {1:N0} B（Installer {2:N0} B，差值 {3:N0} B）" -f `
            $setupName, $setupBytes, $installerBytes, ($setupBytes - $installerBytes)) 'INFO'
}

# --- 7. 安装后逐文件比对（5.3）--------------------------------------------
$installSeconds = 0
$installOk = $null
$diffCount = $null
$uninstallSeconds = 0
if ($SkipInstallVerify) {
    Write-Both '按要求跳过安装后逐文件比对（-SkipInstallVerify）' 'WARN'
}
else {
    Write-Both '== 7. 静默安装并逐文件比对 ==' 'STEP'
    $instDir = Join-Path $OutDir 'install'
    $cacheDir = Join-Path $OutDir 'cache'
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    # 原生安装偶尔会被外部进程（安全软件/资源扫描）在解压途中终止：exit=-1、
    # 安装目录缺文件、maintenancetool.exe 没写出来。清理目标目录后重试一次。
    $installComplete = $false
    $installAttempts = 0
    while (-not $installComplete -and $installAttempts -lt 2) {
        $installAttempts++
        if (Test-Path -LiteralPath $instDir) {
            Start-Sleep -Milliseconds 500
            Remove-Item -LiteralPath $instDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Native -FilePath $installerPath -ArgumentList @(
            '--platform', 'minimal', 'in', '-c', '--confirm-command', '--accept-licenses', '--accept-messages',
            '--cp', $cacheDir, '-t', $instDir
        ) -LogPath $LogPath
        $sw.Stop()
        $installSeconds += [math]::Round($sw.Elapsed.TotalSeconds, 2)
        $installComplete = ($r.ExitCode -eq 0) -and (Test-Path -LiteralPath (Join-Path $instDir 'maintenancetool.exe'))
        if (-not $installComplete -and $installAttempts -lt 2) {
            Write-Both "静默安装未完成（exit=$($r.ExitCode)），清理目标目录后重试一次" 'WARN'
        }
    }
    Add-Step '静默安装' $installComplete "exit=$($r.ExitCode)，尝试 $installAttempts 次" $installSeconds

    Write-Both '== 8. 差异清单 ==' 'STEP'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $diff = New-Object System.Collections.Generic.List[string]
    $stageFiles = Get-ChildItem -LiteralPath $StageRoot -Recurse -File -Force
    foreach ($f in $stageFiles) {
        $rel = $f.FullName.Substring($StageRoot.Length).TrimStart('\')
        $t = Join-Path $instDir $rel
        if (-not (Test-Path -LiteralPath $t)) { $diff.Add("缺失 $rel"); continue }
        if ((Get-Item -LiteralPath $t).Length -ne $f.Length) { $diff.Add("大小不符 $rel"); continue }
    }
    $sw.Stop()
    $diffCount = $diff.Count
    Add-Step '差异清单' ($diff.Count -eq 0) ($(if ($diff.Count) { "差异 $($diff.Count) 项，前 10: " + (($diff | Select-Object -First 10) -join '; ') } else { "新增 $(@(Get-ChildItem -LiteralPath $instDir -Recurse -File -Force).Count - $stageFiles.Count) 个安装器自身文件，staging 侧 $($stageFiles.Count) 个文件全部就位" })) $sw.Elapsed.TotalSeconds
    $diff | Set-Content -LiteralPath (Join-Path $OutDir 'install-diff.txt') -Encoding UTF8
    $installOk = ($diff.Count -eq 0) -and $installComplete

    Write-Both '== 9. 卸载 ==' 'STEP'
    $mt = Join-Path $instDir 'maintenancetool.exe'
    if (Test-Path -LiteralPath $mt) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ru = Invoke-Native -FilePath $mt -ArgumentList @(
            '--platform', 'minimal', 'pr', '-c', '--confirm-command', '--accept-licenses', '--accept-messages', '--cp', $cacheDir
        ) -LogPath $LogPath
        $sw.Stop()
        $uninstallSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        # QIFW 的 pr 删不掉正在运行的 maintenancetool.exe，原生回路必然残留元数据，
        # 因此这里只断言退出码，并把残留清单落盘供诊断；"目录整体不存在"的强断言放在
        # 9c 的外壳回路（由外壳在子进程退出后补删）。
        $nativeResidual = @()
        if (Test-Path -LiteralPath $instDir) {
            $nativeResidual = @(
                Get-ChildItem -LiteralPath $instDir -Recurse -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.FullName.Substring($instDir.Length).TrimStart('\') } |
                    Select-Object -First 20
            )
            if ($nativeResidual.Count -gt 0) {
                $nativeResidual | Set-Content -LiteralPath (Join-Path $OutDir 'install-uninstall-residual.txt') -Encoding UTF8
            }
        }
        $nativeDetail = "exit=$($ru.ExitCode)"
        if ($nativeResidual.Count -gt 0) {
            $nativeDetail += "；QIFW 自删限制，残留 $($nativeResidual.Count) 项（前 5：" + (($nativeResidual | Select-Object -First 5) -join '; ') + "）"
        } else {
            $nativeDetail += '；安装目录已清空'
        }
        Add-Step '卸载' ($ru.ExitCode -eq 0) $nativeDetail $uninstallSeconds
    }
}

# --- 9b. 外壳全回路验证（8.3）---------------------------------------------
$setupInstallOk = $null
$setupDiffCount = $null
$setupUninstallOk = $null
$uninstallerEntryOk = $null
$uninstallerPath = $null
$uninstallerBytes = 0
$setupShellLog = Join-Path $OutDir 'setup-shell.log'

function Find-OrbbecUninstallEntry([string]$dir) {
    $want = [System.IO.Path]::GetFullPath($dir)
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $v = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $v -or $v.DisplayName -ne $productName) { continue }
            try { $loc = [System.IO.Path]::GetFullPath($v.InstallLocation) } catch { continue }
            if ($loc -ieq $want) { return $v }
        }
    }
    return $null
}

function Find-OrbbecEntriesForDir([string]$dir) {
    $want = [System.IO.Path]::GetFullPath($dir)
    $res = New-Object System.Collections.Generic.List[object]
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $v = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $v -or $v.DisplayName -ne $productName) { continue }
            try { $loc = [System.IO.Path]::GetFullPath($v.InstallLocation) } catch { continue }
            if ($loc -ieq $want) { $res.Add($v) }
        }
    }
    return $res.ToArray()
}

function Find-AllOrbbecEntries {
    $res = New-Object System.Collections.Generic.List[object]
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $v = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($null -ne $v -and $v.DisplayName -eq $productName) {
                $v | Add-Member -NotePropertyName '_KeyPath' -NotePropertyValue $k.PSPath -Force
                $res.Add($v)
            }
        }
    }
    return $res.ToArray()
}

$iconProbeSrc = @"
using System;
using System.Runtime.InteropServices;
public static class IconProbe {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr LoadLibraryExW(string file, IntPtr h, uint flags);
    [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr h);
    delegate bool EnumProc(IntPtr h, IntPtr type, IntPtr name, IntPtr param);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumResourceNamesW(IntPtr h, IntPtr type, EnumProc cb, IntPtr param);
    static bool _found;
    static bool Cb(IntPtr h, IntPtr type, IntPtr name, IntPtr param) { _found = true; return false; }
    public static bool HasGroupIcon(string path) {
        IntPtr h = LoadLibraryExW(path, IntPtr.Zero, 0x00000002);
        if (h == IntPtr.Zero) return false;
        _found = false;
        EnumResourceNamesW(h, new IntPtr(14), Cb, IntPtr.Zero);
        FreeLibrary(h);
        return _found;
    }
}
"@
if (-not ('IconProbe' -as [type])) { Add-Type $iconProbeSrc }

if ($setupPath -and -not $SkipInstallVerify) {
    # 测试钩子：把卸载器的部署位置与数据清理根都重定向到 out/，不碰本机真实用户数据。
    $dataRoot = Join-Path $OutDir 'data-root'
    $env:ORBBEC_SETUP_DATA_ROOT = $dataRoot
    New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null

    Write-Both '== 9b. 外壳静默安装 ==' 'STEP'
    $setupInstDir = Join-Path $OutDir 'install-setup'
    # 与外层原生安装相同的重试策略：被外部终止/缺 maintenancetool 时清理后重试一次。
    $setupInstallComplete = $false
    $setupInstallAttempts = 0
    $setupInstallSeconds = 0
    while (-not $setupInstallComplete -and $setupInstallAttempts -lt 2) {
        $setupInstallAttempts++
        if (Test-Path -LiteralPath $setupInstDir) {
            Start-Sleep -Milliseconds 500
            Remove-Item -LiteralPath $setupInstDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Native -FilePath $setupPath -ArgumentList @(
            '--log', $setupShellLog, '--with-options', '--silent', 'in', '-t', $setupInstDir
        ) -LogPath $LogPath
        $sw.Stop()
        $setupInstallSeconds += [math]::Round($sw.Elapsed.TotalSeconds, 2)
        $setupInstallComplete = ($r.ExitCode -eq 0) -and (Test-Path -LiteralPath (Join-Path $setupInstDir 'maintenancetool.exe'))
        if (-not $setupInstallComplete -and $setupInstallAttempts -lt 2) {
            Write-Both "外壳静默安装未完成（exit=$($r.ExitCode)），清理目标目录后重试一次" 'WARN'
        }
    }
    Add-Step '外壳静默安装' $setupInstallComplete "exit=$($r.ExitCode)，尝试 $setupInstallAttempts 次（外壳日志 $setupShellLog）" $setupInstallSeconds

    $setupDiff = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $setupInstDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $StageRoot -Recurse -File -Force)) {
            $rel = $f.FullName.Substring($StageRoot.Length).TrimStart('\')
            $t = Join-Path $setupInstDir $rel
            if (-not (Test-Path -LiteralPath $t)) { $setupDiff.Add("缺失 $rel"); continue }
            if ((Get-Item -LiteralPath $t).Length -ne $f.Length) { $setupDiff.Add("大小不符 $rel") }
        }
    } else {
        $setupDiff.Add('安装目录不存在')
    }
    $setupDiffCount = $setupDiff.Count
    if ($setupDiffCount -gt 0) {
        $setupDiff | Set-Content -LiteralPath (Join-Path $OutDir 'install-setup-diff.txt') -Encoding UTF8
    }
    Add-Step '外壳安装差异' ($setupDiffCount -eq 0) ($(if ($setupDiffCount) { "差异 $setupDiffCount 项，前 10: " + (($setupDiff | Select-Object -First 10) -join '; ') } else { "staging 侧 $(@(Get-ChildItem -LiteralPath $StageRoot -Recurse -File -Force).Count) 个文件全部就位" }))

    $desktopDir = [Environment]::GetFolderPath('Desktop')
    $desktopLnk = Join-Path $desktopDir 'OrbbecSlicer.lnk'
    $desktopCreated = Test-Path -LiteralPath $desktopLnk
    $assocCreated = (Get-ItemProperty 'HKCU:\Software\Classes\.3mf' -ErrorAction SilentlyContinue).'(default)' -eq 'OrbbecSlicer.3mf'
    Add-Step '安装选项落地' ($desktopCreated -and $assocCreated) ("桌面快捷方式=$(if ($desktopCreated) { '有' } else { '无' })；.3mf 关联=$(if ($assocCreated) { '已设置' } else { '未设置' })")

    Write-Both '== 9b2. 卸载入口检查 ==' 'STEP'
    $entry = Find-OrbbecUninstallEntry $setupInstDir
    $uninstallerEntryOk = $false
    $uninstallerEntryCount = @(Find-OrbbecEntriesForDir $setupInstDir).Count
    if ($entry) {
        $uninstallerPath = $entry.DisplayIcon
        if (Test-Path -LiteralPath $uninstallerPath) { $uninstallerBytes = (Get-Item -LiteralPath $uninstallerPath).Length }
        $fieldsOk = $entry.Publisher -and $entry.DisplayVersion -and $entry.InstallLocation -and
                    $entry.DisplayIcon -and $entry.UninstallString -match 'OrbbecSlicerUninstaller\.exe' -and
                    $entry.QuietUninstallString -match '--uninstall' -and
                    (Test-Path -LiteralPath $entry.DisplayIcon) -and ([int]$entry.EstimatedSize -gt 0)
        $uninstallerEntryOk = $fieldsOk -and ($uninstallerEntryCount -eq 1)
    }
    Add-Step '卸载入口检查' $uninstallerEntryOk ($(if ($entry) { "条目数=$uninstallerEntryCount；UninstallString=$($entry.UninstallString)；DisplayIcon=$($entry.DisplayIcon)；EstimatedSize=$($entry.EstimatedSize)KB" } else { '没有找到指向品牌化卸载器的卸载登记' }))

    Write-Both '== 9b3. 图标检查 ==' 'STEP'
    $iconsVerified = [IconProbe]::HasGroupIcon($setupPath)
    if ($uninstallerPath) { $iconsVerified = $iconsVerified -and [IconProbe]::HasGroupIcon($uninstallerPath) }
    Add-Step '图标检查' $iconsVerified ("Setup.exe=$(if ($iconsVerified) { '有图标' } else { '缺图标' })；卸载器=$uninstallerPath")

    Write-Both '== 9c. 从卸载入口静默卸载 ==' 'STEP'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $uninstallExit = -1
    if ($entry -and (Test-Path -LiteralPath $entry.DisplayIcon)) {
        $r = Invoke-Native -FilePath $entry.DisplayIcon -ArgumentList @(
            '--uninstall', '--install-dir', $setupInstDir, '--silent'
        ) -LogPath $LogPath
        $uninstallExit = $r.ExitCode
    }
    $sw.Stop()
    # 卸载器的自删除与登记清理有延迟（启动器要等 UI 退出再删目录）：最多轮询 10 秒。
    $uninstDir = Join-Path $dataRoot 'Local\Orbbec\OrbbecSlicer\uninstaller'
    $lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\OrbbecSlicer\卸载 OrbbecSlicer.lnk'
    $uninstallCleanupVerified = $false
    $dirGone = $false
    for ($i = 0; $i -lt 20; $i++) {
        # 安装目录必须整体消失：只检查 maintenancetool.exe 会漏掉 components.xml、
        # installerResources、network.xml 等 QIFW 元数据残留。
        $dirGone = -not (Test-Path -LiteralPath $setupInstDir)
        $entryGone = -not (Find-OrbbecUninstallEntry $setupInstDir)
        $uninstGone = -not (Test-Path -LiteralPath $uninstDir)
        $lnkGone = -not (Test-Path -LiteralPath $lnk)
        $desktopGone = -not (Test-Path -LiteralPath $desktopLnk)
        $assoc = (Get-ItemProperty 'HKCU:\Software\Classes\.3mf' -ErrorAction SilentlyContinue).'(default)'
        $assocReverted = ($assoc -ne 'OrbbecSlicer.3mf')
        $progGone = -not (Test-Path -LiteralPath 'HKCU:\Software\Classes\OrbbecSlicer.3mf')
        $entryCountAfter = @(Find-OrbbecEntriesForDir $setupInstDir).Count
        $uninstallCleanupVerified = $dirGone -and $entryGone -and $uninstGone -and $lnkGone -and
                                    $desktopGone -and $assocReverted -and $progGone -and ($entryCountAfter -eq 0)
        if ($uninstallCleanupVerified) { break }
        Start-Sleep -Milliseconds 500
    }
    # 目录残留时把清单落盘并写进步骤详情，便于直接判断是哪个文件没删掉。
    $uninstallResidual = @()
    if (-not $dirGone -and (Test-Path -LiteralPath $setupInstDir)) {
        $uninstallResidual = @(
            Get-ChildItem -LiteralPath $setupInstDir -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName.Substring($setupInstDir.Length).TrimStart('\') } |
                Select-Object -First 20
        )
        if ($uninstallResidual.Count -gt 0) {
            $uninstallResidual | Set-Content -LiteralPath (Join-Path $OutDir 'uninstall-residual.txt') -Encoding UTF8
        }
    }
    $setupUninstallOk = ($uninstallExit -eq 0) -and $uninstallCleanupVerified
    $dirDetail = if ($dirGone) { '已删除' } elseif ($uninstallResidual.Count -gt 0) {
        '残留：' + ($uninstallResidual -join '; ')
    } else { '残留' }
    Add-Step '从卸载入口静默卸载' $setupUninstallOk ("exit=$uninstallExit；安装目录 $dirDetail；登记 $(if ($entryGone) { '已删除' } else { '残留' })；卸载器 $(if ($uninstGone) { '已删除' } else { '残留' })；开始菜单 $(if ($lnkGone) { '已删除' } else { '残留' })；桌面快捷方式 $(if ($desktopGone) { '已删除' } else { '残留' })；.3mf 关联 $(if ($assocReverted) { '已还原' } else { '仍是 OrbbecSlicer.3mf' })；ProgId $(if ($progGone) { '已删除' } else { '残留' })；剩余条目 $entryCountAfter") $sw.Elapsed.TotalSeconds

    $setupInstallOk = $setupInstallComplete -and ($setupDiffCount -eq 0) -and $uninstallerEntryOk -and $setupUninstallOk
    if (-not $setupInstallOk) {
        # 失败即作废 Setup.exe 与校验文件，避免被误拿去发布。
        Remove-Item -LiteralPath $setupPath, "$setupPath.sha256" -Force -ErrorAction SilentlyContinue
        Add-Step '外壳全回路' $false "外壳静默/卸载入口回路失败，Setup.exe 与校验文件已作废；日志：$LogPath / $setupShellLog"
        Exit-Fail "外壳全回路失败（日志：$LogPath / $setupShellLog）"
    }
    Add-Step '外壳全回路' $true "静默安装 → 逐文件比对 → 卸载入口检查 → 从入口静默卸载 → 清理 全部通过"
    Remove-Item Env:\ORBBEC_SETUP_DATA_ROOT -ErrorAction SilentlyContinue
} elseif ($setupPath) {
    Write-Both '按要求跳过外壳静默回路（-SkipInstallVerify）' 'WARN'
}

# --- 10. 摘要 -------------------------------------------------------------
$nsisBaseline = 159936312
$deliverable = 'qifw-native'
if (-not $WithoutSetupUi) { $deliverable = 'setup-shell' }
$result = [ordered]@{
    timestamp         = (Get-Date).ToString('o')
    product           = $productName
    version           = $appVersion
    componentId       = $componentId
    architecture      = $archTag
    stageRoot         = $StageRoot
    upstreamRepo      = $UpstreamRepo
    versionSource     = "$versionInc : $($versionLine.LineNumber)"
    toolchain         = [ordered]@{
        qtVersion     = $toolchain.QtVersion
        architecture  = $toolchain.Architecture
        ifwVersion    = $toolchain.IfwVersion
        archiveSha256 = $toolchain.ArchiveSha256
        binarycreator = $binarycreator
        available     = $toolchain.Available
        manifest      = $Manifest._manifestPath
    }
    staging           = [ordered]@{ fileCount = $snapBefore.FileCount; totalBytes = $snapBefore.TotalBytes; digestBefore = $snapBefore.Digest; digestAfter = $snapAfter.Digest; unchanged = $same }
    workCopy          = [ordered]@{ fileCount = $snapWork.FileCount; totalBytes = $snapWork.TotalBytes; digest = $snapWork.Digest; matchesStaging = $sameWork }
    archiveFormat     = $ArchiveFormat
    compression       = $Compression
    binarycreatorArgs = "--offline-only -c <config.xml> -p <packages> -t <installerbase> --af $ArchiveFormat --ac $Compression"
    installerPath     = $installerPath
    installerBytes    = $installerBytes
    installerSha256   = $sha1
    deliverable       = $deliverable
    setupPath         = $setupPath
    setupBytes        = $setupBytes
    setupVsInstallerBytes = $(if ($setupBytes -gt 0) { $setupBytes - $installerBytes } else { 0 })
    setupVsNsis       = $(if ($setupBytes -gt 0) { [math]::Round(($setupBytes - $nsisBaseline) / $nsisBaseline, 4) } else { $null })
    setupInstallVerified = $setupInstallOk
    uninstallerPath   = $uninstallerPath
    uninstallerBytes  = $uninstallerBytes
    uninstallerEntryVerified = $uninstallerEntryOk
    iconsVerified     = $iconsVerified
    uninstallEntryCount = $uninstallerEntryCount
    uninstallCleanupVerified = $uninstallCleanupVerified
    nsisBaselineBytes = $nsisBaseline
    sizeVsNsis        = [math]::Round(($installerBytes - $nsisBaseline) / $nsisBaseline, 4)
    buildSeconds      = $buildSeconds
    installSeconds    = $installSeconds
    uninstallSeconds  = $uninstallSeconds
    installVerified   = $installOk
    diffCount         = $diffCount
    steps             = $steps
    failures          = $failures
    log               = $LogPath
}
Write-JsonFile -Path (Join-Path $OutDir 'result.json') -InputObject ([pscustomobject]$result)

Write-Both ("产物: {0} = {1:N0} B（NSIS 基线 {2:N0} B，相对 {3:P1}）" -f $installerName, $installerBytes, $nsisBaseline, (($installerBytes - $nsisBaseline) / $nsisBaseline)) 'INFO'
Write-Both "结果: $(Join-Path $OutDir 'result.json')" 'INFO'
if ($failures.Count -gt 0) { Write-Both "打包流程失败 $($failures.Count) 个步骤" 'ERROR'; exit 1 }

# 通过后清掉其它批次的工作副本（每份 ~0.5 GB）：日志随结果目录保留，缓存目录为 --cp 共享，均不清
$workParent = Split-Path -Parent $WorkRoot
foreach ($d in (Get-ChildItem -LiteralPath $workParent -Directory -ErrorAction SilentlyContinue)) {
    if ($d.FullName -ne $WorkRoot) {
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Both "清理旧工作副本: $($d.FullName)" 'INFO'
    }
}
Write-Both '产品打包全部通过' 'OK'
exit 0
