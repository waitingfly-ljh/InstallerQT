#Requires -Version 5.1
<#
.SYNOPSIS
  QIFW 打包环境健康检查。退出码 0 = 可用，非 0 = 不可用。

.DESCRIPTION
  检查分三级：
    1. 前置条件：OS 位数、MSVC 2022、CMake、VC 运行时 —— 缺失项只报告，
       但 Qt/QIFW 运行所必需的 VC 运行时与 64 位 OS 会阻断结论。
    2. 工具存在性：binarycreator / installerbase / archivegen / repogen
       可执行，并输出路径与版本。
    3. 版本一致性：可执行的工具若返回版本，与 manifest 登记值核对。
  另做路径守卫检查：toolchainRoot 解析后必须落在本仓库内。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\check-env.ps1
  # 仅看 JSON 结果
  powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\check-env.ps1 -Json
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [string]$ManifestPath = ''
)

. "$PSScriptRoot\_common.ps1"

# -Json 供脚本消费：stdout 必须只有 JSON。Write-Host（含 Write-Log）不经过 PowerShell
# 5.1 的 stdout 重定向，会被直接打进管道，因此 JSON 模式下把进度行改成写 stderr。
if ($Json) {
    $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    function Write-Log {
        param([string]$Message, [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO')
        [Console]::Error.WriteLine(("[" + (Get-Date).ToString('HH:mm:ss') + "] [" + $Level + "] " + $Message))
    }
}

$RepoRoot = Get-RepoRoot
$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param([string]$Group, [string]$Name, [bool]$Ok, [string]$Detail, [string]$Fix = '', [switch]$Blocking)
    $results.Add([pscustomobject]@{
            Group    = $Group
            Name     = $Name
            Ok       = $Ok
            Detail   = $Detail
            Fix      = $Fix
            Blocking = [bool]$Blocking
        })
}

# --- 1. 前置条件 ----------------------------------------------------------
Write-Log '== 前置条件 ==' 'STEP'

$os64 = [Environment]::Is64BitOperatingSystem
Add-Result '前置条件' 'OS 64 位' $os64 ($(if ($os64) { "$([Environment]::OSVersion.VersionString)" } else { '32 位系统' })) '安装 64 位 Windows 10/11' -Blocking

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$msvcOk = $false; $msvcDetail = 'vswhere 不存在'
if (Test-Path -LiteralPath $vswhere) {
    $vs = & $vswhere -latest -version '[17.0,18.0)' -products * -format json 2>$null | ConvertFrom-Json
    if ($vs) {
        $msvcDetail = "$($vs.displayName) $($vs.installationVersion)"
        $toolset = Join-Path $vs.installationPath 'VC\Tools\MSVC'
        $msvcOk = Test-Path -LiteralPath $toolset
        if (-not $msvcOk) { $msvcDetail += '（未找到 VC\Tools\MSVC）' }
    }
    else { $msvcDetail = '未发现 VS 2022' }
}
Add-Result '前置条件' 'MSVC 2022' $msvcOk $msvcDetail '安装 Visual Studio 2022（含 C++ 生成工具）'

$cmake = Get-Command cmake -ErrorAction SilentlyContinue
$cmakeOk = [bool]$cmake
Add-Result '前置条件' 'CMake' $cmakeOk ($(if ($cmakeOk) { (& cmake --version 2>$null | Select-Object -First 1) } else { '未在 PATH 中' })) '安装 CMake 并加入 PATH'

$vcr = @('vcruntime140.dll', 'vcruntime140_1.dll') | ForEach-Object { Join-Path $env:SystemRoot "System32\$_" }
$vcrMissing = $vcr | Where-Object { -not (Test-Path -LiteralPath $_) }
$vcrOk = $vcrMissing.Count -eq 0
Add-Result '前置条件' 'VC++ 运行时' $vcrOk ($(if ($vcrOk) { 'vcruntime140 / vcruntime140_1 存在' } else { "缺失: $($vcrMissing -join ', ')" })) '安装 Microsoft Visual C++ 2015-2022 可再发行组件' -Blocking

$sevenZip = Get-Command 7z -ErrorAction SilentlyContinue
if (-not $sevenZip) { $sevenZip = @(Get-Item 'C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe' -ErrorAction SilentlyContinue) | Select-Object -First 1 }
$sevenZipPath = if ($sevenZip) { if ($sevenZip.Source) { $sevenZip.Source } else { $sevenZip.FullName } } else { '' }
Add-Result '前置条件' '7-Zip CLI（可选）' ([bool]$sevenZip) ($(if ($sevenZip) { $sevenZipPath } else { '未安装；binarycreator 内置 7z 归档，冒烟阶段不需要' })) '' -Blocking:$false

# --- 2. 路径守卫 ----------------------------------------------------------
Write-Log '== 路径守卫 ==' 'STEP'

$ManifestOk = $false; $Manifest = $null; $ToolchainRoot = $null
try {
    $mPath = if ($ManifestPath) { $ManifestPath } else { Resolve-RepoPath 'packaging/qifw/toolchain/manifest.json' $RepoRoot }
    $Manifest = Get-Content -LiteralPath $mPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ToolchainRoot = Resolve-RepoPath -RelativePath $Manifest.toolchainRoot -RepoRoot $RepoRoot
    $ManifestOk = $true
    Add-Result '路径守卫' 'manifest 可读且工具根在仓库内' $true "toolchainRoot=$ToolchainRoot"
}
catch {
    Add-Result '路径守卫' 'manifest 可读且工具根在仓库内' $false $_.Exception.Message '修正 manifest.json 的 toolchainRoot 为本仓库内相对路径' -Blocking
}

# --- 3. 工具存在性 --------------------------------------------------------
Write-Log '== 工具 ==' 'STEP'

$toolFindings = @()
$expectedIfwRoot = $null
if ($ManifestOk) {
    $expectedIfwRoot = Resolve-RepoPath $Manifest.ifw.installDir $RepoRoot
    foreach ($tool in $Manifest.tools) {
        $found = $null
        $searched = @()

        # 优先 manifest 声明的相对路径，其次在工具根下按名字查找
        $declared = if ($tool.relativePath) { Join-Path $ToolchainRoot ($tool.relativePath -replace '/', '\') } else { $null }
        if ($declared) {
            $searched += $declared
            $direct = Get-Item -LiteralPath $declared -ErrorAction SilentlyContinue
            if ($direct) { $found = $direct }
        }
        if (-not $found) {
            $rel = if ($tool.relativePath) { $tool.relativePath } else { "$($tool.name).exe" }
            $leaf = Split-Path -Leaf $rel
            $hit = Get-ChildItem -LiteralPath $ToolchainRoot -Recurse -File -Filter $leaf -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { $found = $hit }
        }

        if (-not $found) {
            $expectHint = if ($tool.relativePath) { Join-Path $ToolchainRoot ($tool.relativePath -replace '/', '\') } else { "$ToolchainRoot\bin\$($tool.name).exe" }
            Add-Result '工具' $tool.name $false "未找到；期望位于 $expectHint" '运行 install-toolchain.ps1 获取工具链' -Blocking
            $toolFindings += $tool.name
            continue
        }

        # 可执行性判定：
        #   - 启动失败（缺 DLL / 不是有效 Win32 程序）→ 不可用；
        #   - 能启动但报参数错误（"Unknown option" / "Usage:" / 缺 config）→ 可用。
        #   因此只看是否产生了"进程能运行"的证据，不看退出码。
        $probeText = ''
        $runnable = $false
        $argList = @($tool.versionArgs | Where-Object { $_ })
        try {
            $out = & $found.FullName @argList 2>&1
            $exit = $LASTEXITCODE
            $probeText = ($out | Out-String).Trim()
            $startsUp = $probeText -match 'Usage:|Error:|--help|Options:|Cannot execute|unknown option'
            $loadFailure = $probeText -match '0xc000007b|0xc0000135|is not recognized|not a valid Win32'
            $runnable = $startsUp -and -not $loadFailure
        }
        catch {
            $probeText = $_.Exception.Message
            $runnable = $false
        }

        $detail = $found.FullName
        $firstLine = ($probeText -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($firstLine) { $detail += " | $firstLine" }
        Add-Result '工具' $tool.name $runnable $detail '检查 VC++ 运行时是否齐全，或重新获取工具链' -Blocking

        # --- 4. 版本一致性 ---
        # QIFW 工具都不自报版本号（--help 只打印 Usage，其中的路径恰好含版本目录名，
        # 那不是工具自报的版本）。因此版本一致性改为两条独立核对：
        #   a) 工具实际落盘的目录名必须是 manifest.ifw.version；
        #   b) 工具必须在 manifest.ifw.installDir 之内。
        # 两者同源时会同时通过；只改其一（改 manifest 版本、换目录、换 tools[].relativePath）
        # 都会被报出来。
        $actualVer = [regex]::Match($found.FullName, 'QtInstallerFramework\\(\d+\.\d+(?:\.\d+)?)').Groups[1].Value
        $foundRelToRoot = $found.FullName.Substring($ToolchainRoot.Length).TrimStart('\') -replace '\\', '/'
        $declaredRel = if ($tool.relativePath) { $tool.relativePath } else { '' }
        $samePath = ($foundRelToRoot -eq $declaredRel)
        if (-not $samePath) {
            Add-Result '版本' $tool.name $false "期望 $($Manifest.ifw.version) / 实际 $(if ($actualVer) { $actualVer } else { 'unknown' })（实际路径 $($found.FullName)）" '更新 manifest 的 ifw.version / installDir / tools[].relativePath，或重新获取对应版本的工具链' -Blocking
        }
        elseif ($actualVer -and $actualVer -ne $Manifest.ifw.version) {
            Add-Result '版本' $tool.name $false "期望 $($Manifest.ifw.version) / 实际 $actualVer（$($found.FullName)）" '更新 manifest.ifw.version 与 installDir，或重新获取对应版本的工具链' -Blocking
        }
        elseif ($expectedIfwRoot -and -not $found.FullName.StartsWith($expectedIfwRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            Add-Result '版本' $tool.name $false "期望 $($Manifest.ifw.version) / 实际 $(if ($actualVer) { $actualVer } else { 'unknown' })（不在 $expectedIfwRoot 之下）" '更新 manifest.ifw.installDir，或重新获取对应版本的工具链' -Blocking
        }
    }
}

# --- 5. 总体结论 ----------------------------------------------------------
$failedBlocking = @($results | Where-Object { -not $_.Ok -and $_.Blocking })
$failedWarn = @($results | Where-Object { -not $_.Ok -and -not $_.Blocking })
$available = $failedBlocking.Count -eq 0

if ($Json) {
    [pscustomobject]@{
        available = $available
        repoRoot  = $RepoRoot
        checks    = $results
    } | ConvertTo-Json -Depth 5
}
else {
    Write-Host ''
    Write-Log '== 结果 ==' 'STEP'
    foreach ($g in ($results | Group-Object Group)) {
        Write-Host "  [$($g.Name)]"
        foreach ($r in $g.Group) {
            $mark = if ($r.Ok) { 'OK  ' } else { if ($r.Blocking) { 'FAIL' } else { 'WARN' } }
            $color = if ($r.Ok) { 'Green' } elseif ($r.Blocking) { 'Red' } else { 'Yellow' }
            Write-Host ("    {0} {1,-28} {2}" -f $mark, $r.Name, $r.Detail) -ForegroundColor $color
            if (-not $r.Ok -and $r.Fix) { Write-Host ("         -> $($r.Fix)") -ForegroundColor DarkYellow }
        }
    }
    Write-Host ''
    if ($failedBlocking.Count -gt 0) {
        Write-Log "缺失/不匹配（阻断）: $($failedBlocking.Count) 项" 'ERROR'
    }
    if ($failedWarn.Count -gt 0) {
        Write-Log "可选缺失（不阻断）: $($failedWarn.Count) 项" 'WARN'
    }
    if ($available) { Write-Log '总体结论：可用' 'OK' } else { Write-Log '总体结论：不可用' 'ERROR' }
}

exit $(if ($available) { 0 } else { 1 })
