#Requires -Version 5.1
<#
.SYNOPSIS
  构建安装器外壳（Qt Quick 界面），并部署其运行时到 dist/。

.DESCRIPTION
  产物布局：
    build/          CMake + MSVC 的编译目录（可随时删除）
    dist/           可运行的 OrbbecSlicerSetup.exe + Qt 运行时 + QML 模块 + qt.conf

  本脚本只写 setup-ui/ 下的 build/ 与 dist/，不触碰原项目。
  用到的 Qt 通过 manifest 登记（toolchain/qt/<ver>/msvc2022_64），
  MSVC 通过 vswhere 定位，CMake 取 PATH 中的版本。

.PARAMETER QtRoot
  覆盖 Qt 根目录；默认从 packaging/qifw/manifest.json 读取。

.PARAMETER ConfigureOnly
  只跑 CMake 配置，不编译（排查工具链问题时用）。

.PARAMETER SkipDeploy
  跳过 windeployqt（只想拿 exe 做快速验证时用；此时 dist/ 不可独立运行）。

.PARAMETER Selftest
  构建完成后运行 dist\OrbbecSlicerSetup.exe --selftest，退出码非 0 即失败。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\packaging\qifw\setup-ui\build-setup.ps1 -Selftest
#>
[CmdletBinding()]
param(
    [string]$QtRoot = '',
    [string]$Version = '1.0.0',
    [switch]$ConfigureOnly,
    [switch]$SkipDeploy,
    [switch]$Selftest,
    # 删掉 build/ 与 dist/ 后从头构建（换 Qt 版本或部署出现残留时用）。
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$Here = $PSScriptRoot
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $Here '..\..\..')).ProviderPath
$BuildDir = Join-Path $Here 'build'
$DistDir = Join-Path $Here 'dist'
$LogPath = Join-Path $Here 'out\build-setup.log'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null

function Write-Both {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date).ToString('HH:mm:ss'), $Level, $Message
    [Console]::Out.WriteLine($line)
    Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value $line
}
function Fail {
    param([string]$Message)
    Write-Both $Message 'ERROR'
    exit 1
}

Write-Both "仓库根: $RepoRoot"
Write-Both "外壳源码: $Here"

# --- 1. 解析 Qt（优先参数，其次 manifest） ---------------------------------
if (-not $QtRoot) {
    $manifestPath = Resolve-QifwPath 'toolchain/manifest.json' -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $manifestPath)) { Fail "找不到工具链清单: $manifestPath" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $QtRoot = Resolve-RepoPath -RelativePath $manifest.qt.installDir -RepoRoot $RepoRoot
}
$QtRoot = (Resolve-Path -LiteralPath $QtRoot).ProviderPath
$QtBin = Join-Path $QtRoot 'bin'
foreach ($f in @('Qt6Core.dll', 'Qt6Quick.dll', 'Qt6Qml.dll', 'windeployqt.exe', 'qmlimportscanner.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $QtBin $f))) { Fail "Qt 目录不完整，缺少 bin\$f：$QtRoot" }
}
$qtVersion = $null
$qmake = Join-Path $QtBin 'qmake.exe'
if (Test-Path -LiteralPath $qmake) { $qtVersion = (& $qmake -query QT_VERSION 2>$null) }
if (-not $qtVersion) {
    $qtVersion = (Get-Item (Join-Path $QtBin 'Qt6Core.dll')).VersionInfo.FileVersion
}
$qtVersion = "$qtVersion".Trim()
Write-Both "Qt: $QtRoot ($qtVersion)"

# --- 2. 定位 MSVC 与 CMake --------------------------------------------------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) { Fail '找不到 vswhere.exe；需要 Visual Studio 2022（含 C++ 桌面开发工作负载）' }
$vsPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
if (-not $vsPath) { Fail 'vswhere 未找到带 MSVC x64 工具的 Visual Studio 实例；期望：VS 2022 + "使用 C++ 的桌面开发"' }
$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars)) { Fail "找不到 vcvars64.bat：$vcvars" }
$cmake = (Get-Command cmake.exe -ErrorAction SilentlyContinue).Source
if (-not $cmake) { Fail 'PATH 中没有 cmake.exe（需要 3.21+）' }
$cmakeVersion = (& $cmake --version | Select-Object -First 1)
Write-Both "MSVC: $vsPath"
Write-Both "CMake: $cmakeVersion"
Write-Both "编译器: $(Split-Path -Parent (Split-Path -Parent $vcvars))"

# --- 3. 配置与编译（在 vcvars64 环境里跑，保证 cl/ninja 可见） --------------
# 用 .bat 驱动而不是把整条命令串传给 cmd /c：引号嵌套在 Git Bash 启动的
# cmd 里不可靠，写成批处理文件后路径带空格也没问题。
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
$batPath = Join-Path $Here 'out\build-setup.cmd'
if ($Clean) {
    foreach ($d in @($BuildDir, $DistDir)) {
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
    }
    Write-Both '已清理 build/ 与 dist/'
}
$batPath = Join-Path $Here 'out\build-setup.cmd'
$batLines = @(
    '@echo off',
    "call `"$vcvars`" >nul || exit /b 1",
    "cmake -S `"$Here`" -B `"$BuildDir`" -G Ninja -DCMAKE_PREFIX_PATH=`"$QtRoot`" -DCMAKE_BUILD_TYPE=Release -DORBBEC_SETUP_VERSION=$Version || exit /b 1"
)
if (-not $ConfigureOnly) {
    $batLines += "cmake --build `"$BuildDir`" || exit /b 1"
}
$batLines += 'exit /b 0'
[System.IO.File]::WriteAllLines($batPath, $batLines, (New-Object System.Text.ASCIIEncoding))

$cmdOut = Join-Path $Here 'out\build-setup.cmake.log'
# 不用 Start-Process -Wait：非交互管道里 vcvars64 → VsDevCmd 可能等输入永不退出。
# 重定向三个标准流并在开始时关闭 stdin（EOF），同时异步读走输出，避免管道写满。
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'cmd.exe'
$psi.Arguments = "/c `"$batPath`""
$psi.WorkingDirectory = $Here
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$p = New-Object System.Diagnostics.Process
$p.StartInfo = $psi
[void]$p.Start()
$p.StandardInput.Close()
$outTask = $p.StandardOutput.ReadToEndAsync()
$errTask = $p.StandardError.ReadToEndAsync()
if (-not $p.WaitForExit(1800000)) {
    try { $p.Kill() } catch {}
    Fail "编译超过 30 分钟仍未结束（日志见 $cmdOut）"
}
$p.WaitForExit()
[System.IO.File]::WriteAllText($cmdOut, $outTask.Result, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText(($cmdOut + '.err'), $errTask.Result, (New-Object System.Text.UTF8Encoding($false)))
if ($p.ExitCode -ne 0) {
    Get-Content -LiteralPath $cmdOut -Encoding UTF8 -Tail 40 | ForEach-Object { Write-Both $_ 'CMAKE' }
    Get-Content -LiteralPath ($cmdOut + '.err') -Encoding UTF8 -Tail 20 | ForEach-Object { Write-Both $_ 'CMAKE' }
    Fail "编译失败（exit $($p.ExitCode)），完整日志见 $cmdOut"
}
Write-Both '编译完成'

if ($ConfigureOnly) { Write-Both '仅配置模式，结束'; exit 0 }

$built = Join-Path $BuildDir 'OrbbecSlicerSetup.exe'
if (-not (Test-Path -LiteralPath $built)) { Fail "未找到编译产物: $built" }
Copy-Item -LiteralPath $built -Destination (Join-Path $DistDir 'OrbbecSlicerSetup.exe') -Force
Write-Both ("外壳 exe: {0:N0} B" -f (Get-Item (Join-Path $DistDir 'OrbbecSlicerSetup.exe')).Length)
$launcher = Join-Path $BuildDir 'OrbbecSlicerSetupLauncher.exe'
if (-not (Test-Path -LiteralPath $launcher)) { Fail "未找到启动器: $launcher" }
Write-Both ("启动器 exe: {0:N0} B（{1}）" -f (Get-Item $launcher).Length, $launcher)

# --- 4. 部署 Qt 运行时（含 QML 模块） --------------------------------------
# 部署前先用 qmlimportscanner 按源码里真实的 import 求出所需模块，
# 和本脚本声明的清单对照：缺模块时直接失败，而不是等运行时白屏。
$qmlRoot = Join-Path $QtRoot 'qml'
$requiredModules = @(
    'QtQuick',                 # 基础元素（隐含依赖 QtQuick.Window，供 ApplicationWindow）
    'QtQuick.Layouts',         # ColumnLayout / RowLayout / StackLayout
    'QtQuick.Controls',        # Controls.Basic 依赖的公共模块（只部署 Basic 风格）
    'QtQuick.Controls.Basic',  # 界面显式导入的风格
    'QtQuick.Dialogs'          # FolderDialog
)
$scannerOut = Join-Path $Here 'out\qmlimportscanner.json'
$scannerErr = $scannerOut + '.err'
# qmlimportscanner 默认把 JSON 写到 stdout（Qt 6.8 没有 -json/-output 参数）。
$sp = Start-Process -FilePath (Join-Path $QtBin 'qmlimportscanner.exe') `
    -ArgumentList @('-rootPath', $Here, '-importPath', $qmlRoot) `
    -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $scannerOut -RedirectStandardError $scannerErr
if ($sp.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $scannerOut)) {
    Get-Content -LiteralPath $scannerErr -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Both $_ 'SCANNER' }
    Fail "qmlimportscanner 失败（exit $($sp.ExitCode)），日志见 $scannerOut"
}
$scanned = Get-Content -LiteralPath $scannerOut -Raw -Encoding UTF8 | ConvertFrom-Json
$foundModules = @($scanned | Where-Object { $_.type -eq 'module' } | ForEach-Object { $_.name } | Sort-Object -Unique)
$missingModules = @($requiredModules | Where-Object { $foundModules -notcontains $_ })
$scratchModules = @($scanned | Where-Object { $_.type -eq 'module' -and ($_.path -eq '' -or $null -eq $_.path) -and $_.name -notmatch '^SetupUi$' } | ForEach-Object { $_.name })
if ($scratchModules.Count -gt 0) { Write-Both ("QML 导入无法解析: {0}" -f ($scratchModules -join ', ')) 'WARN' }
if ($missingModules.Count -gt 0) {
    Fail ("缺少必需的 QML 模块: {0}。源码实际导入: {1}" -f ($missingModules -join ', '), ($foundModules -join ', '))
}
foreach ($m in $requiredModules) {
    $dir = Join-Path $qmlRoot ($m -replace '\.', '/')
    if (-not (Test-Path -LiteralPath $dir)) { Fail "Qt 安装缺少 QML 模块目录: $dir" }
}
Write-Both ("QML 模块校验通过: {0}" -f ($requiredModules -join ', '))

if ($SkipDeploy) {
    Write-Both '按要求跳过 windeployqt（-SkipDeploy）：dist 不可独立运行' 'WARN'
}
else {
    $windeploy = Join-Path $QtBin 'windeployqt.exe'
    $deployOut = Join-Path $Here 'out\windeployqt.log'
    $exe = Join-Path $DistDir 'OrbbecSlicerSetup.exe'
    $deployArgs = @(
        "`"$exe`"", '--release', '--no-translations', '--no-opengl-sw', '--no-system-d3d-compiler',
        # 只部署 Basic 风格：界面里没有用到 Fusion/Material/Windows/Universal 等风格，
        # 少拷一批 QML 与 DLL，打包体积按模块可核对。
        '--exclude-plugins', 'qmltooling,tls',
        '--qmldir', "`"$Here`""
    )
    $env:PATH = "$QtBin;$env:PATH"
    $dp = Start-Process -FilePath $windeploy -ArgumentList $deployArgs -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $deployOut -RedirectStandardError ($deployOut + '.err')
    Get-Content -LiteralPath $deployOut -Encoding UTF8 | Select-Object -Last 15 | ForEach-Object { Write-Both $_ 'DEPLOY' }
    if ($dp.ExitCode -ne 0) { Fail "windeployqt 失败（exit $($dp.ExitCode)），日志见 $deployOut" }

    # windeployqt 不再自动生成 qt.conf；没有它时 Qt 会去 Qt 安装目录找插件/QML，
    # 干净机器上就会缺模块。这里显式写一份：插件在 exe 同目录，QML 在 ./qml。
    $qtConfPath = Join-Path $DistDir 'qt.conf'
    $qtConf = "[Paths]`r`nPrefix = .`r`nPlugins = .`r`nQml2Imports = qml`r`n"
    [System.IO.File]::WriteAllText($qtConfPath, $qtConf, (New-Object System.Text.ASCIIEncoding))
    Write-Both '已写入 qt.conf（Prefix=. / Plugins=. / Qml2Imports=qml）'

    # --selftest 用 minimal 平台（无窗口）；windeployqt 只部署 qwindows，
    # 这里从工具链补一份，让自检在构建机与干净机器上都能跑。
    $platformDir = Join-Path $DistDir 'platforms'
    foreach ($dll in @('qminimal.dll', 'qwindows.dll')) {
        $src = Join-Path $QtRoot "plugins\platforms\$dll"
        $dst = Join-Path $platformDir $dll
        if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
            New-Item -ItemType Directory -Force -Path $platformDir | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst
            Write-Both "补充平台插件: $dll"
        }
    }

    # 部署清单摘要：记录部署了哪些 DLL 与 QML 模块，供排查"干净机器缺模块"。
    $deployed = Get-ChildItem -LiteralPath $DistDir -Recurse -File
    $dlls = @($deployed | Where-Object Extension -eq '.dll').Count
    $distQml = Join-Path $DistDir 'qml'
    $qmlModules = if (Test-Path $distQml) {
        Get-ChildItem -LiteralPath $distQml -Recurse -File -Filter 'qmldir' |
            ForEach-Object { $_.FullName.Substring($distQml.Length + 1) -replace '\\qmldir$', '' -replace '\\', '/' }
    } else { @() }
    $manifest = [ordered]@{
        qtRoot      = $QtRoot
        qtVersion   = $qtVersion
        exe         = (Join-Path $DistDir 'OrbbecSlicerSetup.exe')
        fileCount   = $deployed.Count
        totalBytes  = ($deployed | Measure-Object Length -Sum).Sum
        dllCount    = $dlls
        qmlModules  = @($qmlModules)
        hasQtConf   = (Test-Path -LiteralPath (Join-Path $DistDir 'qt.conf'))
        hasMinimalPlatform = (Test-Path -LiteralPath (Join-Path $DistDir 'platforms\qminimal.dll'))
    }
    $manifestPath = Join-Path $Here 'out\deploy-manifest.json'
    [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    Write-Both ("部署完成: {0} 个文件 / {1:N0} B / {2} 个 DLL / {3} 个 QML 模块（清单 {4}）" -f `
            $manifest.fileCount, $manifest.totalBytes, $manifest.dllCount, $manifest.qmlModules.Count, $manifestPath)
    if (-not $manifest.hasQtConf) { Write-Both 'dist 缺少 qt.conf：外壳可能找不到 QML 导入路径' 'WARN' }
    if (-not $manifest.hasMinimalPlatform) { Write-Both 'dist 缺少 platforms\qminimal.dll：--selftest 将失败' 'WARN' }
    $lost = @($requiredModules | Where-Object { $qmlModules -notcontains ($_ -replace '\.', '/') })
    if ($lost.Count -gt 0) { Fail ("dist/qml 缺少模块: {0}" -f ($lost -join ', ')) }
    Write-Both '部署校验通过: QtQuick 等必需 QML 模块均在 dist/qml 中'
}

# --- 4b. 构建自包含卸载器 ---------------------------------------------------
$uninstallerExe = Join-Path $BuildDir 'OrbbecSlicerUninstaller.exe'
$pkgUninstaller = Join-Path $Here 'package-uninstaller.ps1'
if (-not (Test-Path -LiteralPath $pkgUninstaller)) { Fail "找不到 package-uninstaller.ps1: $pkgUninstaller" }
if (-not (Test-Path -LiteralPath $launcher)) { Fail "找不到启动器: $launcher" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pkgUninstaller `
    -LauncherExe $launcher -UiDir $DistDir -OutputPath $uninstallerExe -Version $Version
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $uninstallerExe)) {
    Fail "构建卸载器失败（exit $LASTEXITCODE）"
}
Write-Both ("卸载器 exe: {0:N0} B（{1}）" -f (Get-Item $uninstallerExe).Length, $uninstallerExe)

# 品牌图标必须嵌进三个 exe（外壳 / 启动器 / 卸载器）；用 PE 资源表里的 RT_GROUP_ICON 判定。
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
foreach ($exeWithIcon in @((Join-Path $DistDir 'OrbbecSlicerSetup.exe'), $launcher, $uninstallerExe)) {
    if (-not [IconProbe]::HasGroupIcon($exeWithIcon)) { Fail "缺少品牌图标: $exeWithIcon" }
}
Write-Both '图标校验通过: 外壳 / 启动器 / 卸载器 均含品牌图标'


# --- 5. 启动自检 ------------------------------------------------------------
if ($Selftest) {
    $exe = Join-Path $DistDir 'OrbbecSlicerSetup.exe'
    $stOut = Join-Path $Here 'out\selftest.log'
    $st = Start-Process -FilePath $exe -ArgumentList @('--selftest') -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stOut -RedirectStandardError ($stOut + '.err')
    Get-Content -LiteralPath $stOut, ($stOut + '.err') -Encoding UTF8 -ErrorAction SilentlyContinue |
        Select-Object -First 20 | ForEach-Object { Write-Both $_ 'SELFTEST' }
    if ($st.ExitCode -ne 0) { Fail "启动自检失败（exit $($st.ExitCode)），日志见 $stOut" }

    # 真实平台下主窗口必须真的显示（截图用的 shotWindow 不能替代这一步）。
    $winOut = Join-Path $Here 'out\selftest-window.log'
    $sw = Start-Process -FilePath $exe -ArgumentList @('--selftest', '--check-window') -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $winOut -RedirectStandardError ($winOut + '.err')
    Get-Content -LiteralPath $winOut, ($winOut + '.err') -Encoding UTF8 -ErrorAction SilentlyContinue |
        Select-Object -First 20 | ForEach-Object { Write-Both $_ 'SELFTEST' }
    if ($sw.ExitCode -ne 0) { Fail "主窗口显示自检失败（exit $($sw.ExitCode)），日志见 $winOut" }

    # 卸载模式：从系统卸载入口启动时必须直接看到品牌化卸载窗口。
    $uninstOut = Join-Path $Here 'out\selftest-uninstall.log'
    $su = Start-Process -FilePath $exe -ArgumentList @('--selftest', '--uninstall', '--check-window') -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $uninstOut -RedirectStandardError ($uninstOut + '.err')
    Get-Content -LiteralPath $uninstOut, ($uninstOut + '.err') -Encoding UTF8 -ErrorAction SilentlyContinue |
        Select-Object -First 20 | ForEach-Object { Write-Both $_ 'SELFTEST' }
    if ($su.ExitCode -ne 0) { Fail "卸载窗口自检失败（exit $($su.ExitCode)），日志见 $uninstOut" }

    # 自包含卸载器：解压后应直接显示卸载窗口并以 0 退出（--selftest 不触发自删除）。
    $uninstSelfLog = Join-Path $Here 'out\selftest-uninstaller-exe.log'
    $sx = Start-Process -FilePath $uninstallerExe -ArgumentList @('--selftest', '--uninstall', '--check-window') -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $uninstSelfLog -RedirectStandardError ($uninstSelfLog + '.err')
    Get-Content -LiteralPath $uninstSelfLog, ($uninstSelfLog + '.err') -Encoding UTF8 -ErrorAction SilentlyContinue |
        Select-Object -First 20 | ForEach-Object { Write-Both $_ 'SELFTEST' }
    if ($sx.ExitCode -ne 0) { Fail "卸载器自检失败（exit $($sx.ExitCode)），日志见 $uninstSelfLog" }

    # 进度收尾时序（成功 600ms / 失败 300ms）。
    $timingLog = Join-Path $Here 'out\selftest-finish-timing.log'
    $st2 = Start-Process -FilePath $exe -ArgumentList @('--selftest', '--check-finish-timing') -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $timingLog -RedirectStandardError ($timingLog + '.err')
    Get-Content -LiteralPath $timingLog, ($timingLog + '.err') -Encoding UTF8 -ErrorAction SilentlyContinue |
        Select-Object -First 20 | ForEach-Object { Write-Both $_ 'SELFTEST' }
    if ($st2.ExitCode -ne 0) { Fail "进度收尾自检失败（exit $($st2.ExitCode)），日志见 $timingLog" }

    # 完成页标题用 runMode（fresh 不应显示"修复完成"）。
    $runModeLog = Join-Path $Here 'out\selftest-run-mode.log'
    $st3 = Start-Process -FilePath $exe -ArgumentList @('--selftest', '--check-run-mode') -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $runModeLog -RedirectStandardError ($runModeLog + '.err')
    Get-Content -LiteralPath $runModeLog, ($runModeLog + '.err') -Encoding UTF8 -ErrorAction SilentlyContinue |
        Select-Object -First 20 | ForEach-Object { Write-Both $_ 'SELFTEST' }
    if ($st3.ExitCode -ne 0) { Fail "runMode 自检失败（exit $($st3.ExitCode)），日志见 $runModeLog" }
    Write-Both '启动自检通过（--selftest / --check-window / --uninstall --check-window / 卸载器 / 进度收尾 / runMode 均 exit 0）'
}

Write-Both '外壳构建完成'
exit 0
