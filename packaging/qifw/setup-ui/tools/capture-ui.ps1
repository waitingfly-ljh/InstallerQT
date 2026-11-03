#Requires -Version 5.1
<#
.SYNOPSIS
  构建截图版外壳，并逐视图抓图（验证界面用）。

.DESCRIPTION
  只做两件事：
    1. 以 -DORBBEC_SETUP_SHOT=ON 把外壳编成截图构建，产物在 build-shot/，不碰 build/ 与 dist/。
    2. 按视图逐个运行截图构建（--selftest --qml-smoke --view <视图>），窗口存成
       out/ui-shots/<视图>.png，选项勾选态存成 out/ui-shots/option-<键>.png。

  直接跑 build-shot/ 里的 exe，运行时由 toolchain 的 Qt bin 提供（PATH），不经过
  windeployqt：部署目录里残留的旧 exe / 旧 qml 曾经让问题排查跑偏。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\capture-ui.ps1 -Models 'options|failure'
#>
param(
    [string]$Models = 'options|maintenance|progress|complete|failure|uninstall-scope|uninstall-confirm|uninstall-done|option-shortcutDesktop|option-assoc3mf|option-assocStl|option-launchAfterInstall',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $PSScriptRoot
$QtRoot = Join-Path $Here '..\toolchain\qt\6.8.3\msvc2022_64'
$QtBin = Join-Path $QtRoot 'bin'
$BuildDir = Join-Path $Here 'build-shot'
$ShotDir = Join-Path $Here 'out\ui-shots'
$VcVars = 'C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat'
$ShellLog = Join-Path $env:LOCALAPPDATA 'Orbbec\OrbbecSlicerSetup\logs\setup-shell.log'
$Exe = Join-Path $BuildDir 'OrbbecSlicerSetup.exe'

if (-not (Test-Path -LiteralPath $QtBin)) { throw "找不到 Qt: $QtBin" }

# 视图名 = SetupController.view 的名字；卸载三屏同名，冒烟里由 main.cpp 额外切侧栏。
$Views = @('options', 'maintenance', 'progress', 'complete', 'failure',
           'uninstall-scope', 'uninstall-confirm', 'uninstall-done')
$OptionKeys = @('shortcutDesktop', 'assoc3mf', 'assocStl', 'launchAfterInstall')

function Write-Step([string]$msg) { Write-Host "[shot] $msg" }

function Read-ShellLogTail {
    if (Test-Path -LiteralPath $ShellLog) {
        Get-Content -LiteralPath $ShellLog -Tail 30 -Encoding UTF8 | ForEach-Object { Write-Host $_ }
    }
}

# 跑一次截图；30 秒没退出说明窗口没起来，把外壳日志带出来再失败。
# 同一个视图最多重试两次：启动阶段偶发崩溃（0xC0000005），日志里没有 QML 错误，单独重跑即恢复。
function Invoke-Shot([string[]]$ShotArgs, [string]$Png) {
    if (Test-Path -LiteralPath $Png) { Remove-Item -LiteralPath $Png -Force }
    for ($attempt = 1; $attempt -le 2; ++$attempt) {
        $proc = Start-Process -FilePath $Exe -ArgumentList $ShotArgs -PassThru
        if (-not $proc.WaitForExit(30000)) {
            Stop-Process -Id $proc.Id -Force
            Read-ShellLogTail
            throw "$Png 30 秒内没有退出（窗口可能没起来），见 $ShellLog"
        }
        if (Test-Path -LiteralPath $Png) {
            if ($attempt -gt 1) {
                Write-Step ("{0}: 第 2 次尝试才出图（exit {1}）" -f [System.IO.Path]::GetFileName($Png), $proc.ExitCode)
            }
            break
        }
        if ($attempt -eq 2) {
            Read-ShellLogTail
            throw "$Png 没有产出截图（exit $($proc.ExitCode)）"
        }
        Write-Step ("{0} 第一次没出图（exit {1}），重跑一次" -f [System.IO.Path]::GetFileName($Png), $proc.ExitCode)
    }
    Write-Step ("{0} -> {1}" -f [System.IO.Path]::GetFileName($Png), $Png)
}

# --- 1. 构建截图版 -----------------------------------------------------------
if (-not $SkipBuild) {
    Write-Step '构建截图版外壳（build-shot/）'
    $bat = Join-Path $Here 'out\build-shot.cmd'
    $lines = @(
        '@echo off',
        "call `"$VcVars`" >nul || exit /b 1",
        "if not exist `"$BuildDir`" mkdir `"$BuildDir`"",
        "cmake -S `"$Here`" -B `"$BuildDir`" -G Ninja -DCMAKE_PREFIX_PATH=`"$QtRoot`" -DCMAKE_BUILD_TYPE=Release -DORBBEC_SETUP_SHOT=ON || exit /b 1",
        "cmake --build `"$BuildDir`" || exit /b 1",
        'exit /b 0'
    )
    [System.IO.File]::WriteAllLines($bat, $lines, (New-Object System.Text.ASCIIEncoding))

    $log = Join-Path $Here 'out\build-shot.log'
    $errLog = Join-Path $Here 'out\build-shot.log.err'
    # 不用 Start-Process -Wait：非交互管道里 vcvars64 → VsDevCmd 可能等输入永不退出。
    # 这里重定向标准流、立刻关掉 stdin（EOF），并在 WaitForExit 的同时读走输出。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = "/c `"$bat`""
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
    if (-not $p.WaitForExit(1200000)) {
        try { $p.Kill() } catch {}
        throw "构建超过 20 分钟仍未结束，已终止（日志见 $log）"
    }
    $p.WaitForExit()
    [System.IO.File]::WriteAllText($log, $outTask.Result, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($errLog, $errTask.Result, (New-Object System.Text.UTF8Encoding($false)))
    if ($p.ExitCode -ne 0) {
        foreach ($l in @($log, $errLog)) {
            if (Test-Path -LiteralPath $l) { Get-Content -LiteralPath $l -Tail 20 | ForEach-Object { Write-Host $_ } }
        }
        throw "截图版编译失败（exit $($p.ExitCode)），日志见 $log"
    }
    # 编译有时会"带着错误继续跑旧 exe"（例如 qmlcachegen 失败但 ninja 码被吞掉），
    # 这里用日志兜底：出现 FAILED 或 QML 语法/类型错误就判定失败，避免截出旧界面。
    $bad = @(Get-Content -LiteralPath $log, $errLog -ErrorAction SilentlyContinue |
             Where-Object { $_ -match 'FAILED:|error:|Expected token|is not a type|Binding loop' })
    if ($bad.Count -gt 0) {
        $bad | Select-Object -First 20 | ForEach-Object { Write-Host $_ }
        throw "截图版编译有错误（见 $log），不运行旧 exe"
    }
}
if (-not (Test-Path -LiteralPath $Exe)) { throw "未找到截图版 exe: $Exe" }

# --- 2. 逐个视图截图 ---------------------------------------------------------
# 截图要真实渲染（offscreen 平台不出图），用 Qt Quick 的软件渲染后端，避免依赖 GPU。
# DPI 固定成 96，再把缩放固定成 1：机器是 125% 缩放，Windows 会按 1.25 倍栅格化窗口，
# 截图变成 1175×813；评审稿按 100% 设计（940×650），两者都要固定才能逐像素对照。
New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null
$env:QT_QUICK_BACKEND = 'software'
$env:QT_ENABLE_HIGHDPI_SCALING = '0'
$env:QT_SCALE_FACTOR = '1'
$env:QT_FONT_DPI = '96'
$env:PATH = "$BuildDir;$QtBin;$env:PATH"
$env:ORBBEC_SETUP_SHOT_DIR = $ShotDir.TrimEnd('\')

$names = @($Models.Split('|') | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
$failed = New-Object System.Collections.Generic.List[string]
foreach ($v in $Views) {
    if ($names -notcontains $v) { continue }
    try { Invoke-Shot @('--selftest', '--qml-smoke', '--view', $v) (Join-Path $ShotDir "$v.png") }
    catch { Write-Step "失败：$($_.Exception.Message)"; $failed.Add($v) }
}

# 安装选项：同一个安装设置页，取消其中一个勾选项。
# 外壳仍然按 --view（options）命名截图，所以每次先截到 options.png，再改成 option-<键>.png。
# 这一步必须放在所有普通视图之后：否则随后截的 options 会把改出来的文件覆盖回去。
foreach ($k in $OptionKeys) {
    $name = "option-$k"
    if ($names -notcontains $name) { continue }
    try {
        Invoke-Shot @('--selftest', '--qml-smoke', '--view', 'options', '--option', $k) (Join-Path $ShotDir 'options.png')
        Move-Item -LiteralPath (Join-Path $ShotDir 'options.png') -Destination (Join-Path $ShotDir "$name.png") -Force
    } catch { Write-Step "失败：$($_.Exception.Message)"; $failed.Add($name) }
}
if ($names -contains 'options') {
    try { Invoke-Shot @('--selftest', '--qml-smoke', '--view', 'options') (Join-Path $ShotDir 'options.png') }
    catch { Write-Step "失败：$($_.Exception.Message)"; $failed.Add('options') }
}

# 普通视图截完之后核对安装设置页的默认勾选与选项传递（真实页面走一遍"安装"）。
# 截图版带着 ORBBEC_SETUP_SHOT_DIR 时 --selftest 会去等截图；这里用环境变量临时去掉，
# 只保留 --selftest 本身。结果写进外壳日志，出现"自检: 交给引擎"即通过。
$selftestLog = Join-Path $env:LOCALAPPDATA 'Orbbec\OrbbecSlicerSetup\logs\setup-shell.log'
$savedShotDir = $env:ORBBEC_SETUP_SHOT_DIR
$env:ORBBEC_SETUP_SHOT_DIR = ''
$env:ORBBEC_SETUP_SELFTEST_OPTIONS = '1'
try {
    $p = Start-Process -FilePath $Exe -ArgumentList @('--selftest') -NoNewWindow -PassThru
    if (-not $p.WaitForExit(30000)) { Stop-Process -Id $p.Id -Force; throw '自检 30 秒内没有退出' }
    $line = @(Get-Content -LiteralPath $selftestLog -Encoding UTF8 -ErrorAction SilentlyContinue |
              Where-Object { $_ -match '自检: 交给引擎' }) | Select-Object -Last 1
    if (-not $line) { throw "自检没有写出选项行，见 $selftestLog" }
    Write-Step $line
} finally {
    Remove-Item Env:\ORBBEC_SETUP_SELFTEST_OPTIONS -ErrorAction SilentlyContinue
    $env:ORBBEC_SETUP_SHOT_DIR = $savedShotDir
}

if ($failed.Count -gt 0) { throw "以下视图没截到图：$($failed -join ', ')" }
Write-Step '完成'
