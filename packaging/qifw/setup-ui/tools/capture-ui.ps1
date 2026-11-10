#Requires -Version 5.1
<#
.SYNOPSIS
  Build the screenshot build of the shell and capture screenshots view by view (for UI verification).

.DESCRIPTION
  Does only two things:
    1. Build the shell as a screenshot build with -DORBBEC_SETUP_SHOT=ON; artifacts go to build-shot/, leaving build/ and dist/ untouched.
    2. Run the screenshot build view by view (--selftest --qml-smoke --view <view>); windows are saved as
       out/ui-shots/<view>.png and option checkbox states as out/ui-shots/option-<key>.png.

  Runs the exe in build-shot/ directly; the runtime is provided by the toolchain's Qt bin (PATH) without going through
  windeployqt: stale exe / qml left in the deploy directory has misled troubleshooting before.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\capture-ui.ps1 -Models 'options|failure'
#>
param(
    [string]$Models = 'options|maintenance|progress|complete|failure|uninstall-scope|uninstall-confirm|uninstall-done|option-shortcutDesktop|option-assoc3mf|option-assocStl|option-launchAfterInstall',
    # UI language for the captures (e.g. zh_CN). Empty keeps the default (English / system locale).
    # Captures are written as <view>-<shortlang>.png so they can be compared side by side with the English set.
    [string]$Lang = '',
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

if (-not (Test-Path -LiteralPath $QtBin)) { throw "Qt not found: $QtBin" }

# View names = SetupController.view names; the three uninstall screens share names, and main.cpp additionally switches the sidebar in the smoke run.
$Views = @('options', 'maintenance', 'progress', 'complete', 'failure',
           'uninstall-scope', 'uninstall-confirm', 'uninstall-done')
$OptionKeys = @('shortcutDesktop', 'assoc3mf', 'assocStl', 'launchAfterInstall')

function Write-Step([string]$msg) { Write-Host "[shot] $msg" }

function Read-ShellLogTail {
    if (Test-Path -LiteralPath $ShellLog) {
        Get-Content -LiteralPath $ShellLog -Tail 30 -Encoding UTF8 | ForEach-Object { Write-Host $_ }
    }
}

# Run one capture; if it does not exit within 30 seconds the window probably did not come up, so print the shell log and then fail.
# Retry each view at most twice: startup occasionally crashes (0xC0000005) with no QML error in the log, and a lone rerun recovers.
function Invoke-Shot([string[]]$ShotArgs, [string]$Png) {
    if (Test-Path -LiteralPath $Png) { Remove-Item -LiteralPath $Png -Force }
    for ($attempt = 1; $attempt -le 2; ++$attempt) {
        $proc = Start-Process -FilePath $Exe -ArgumentList $ShotArgs -PassThru
        if (-not $proc.WaitForExit(30000)) {
            Stop-Process -Id $proc.Id -Force
            Read-ShellLogTail
            throw "$Png did not exit within 30 seconds (the window may not have come up), see $ShellLog"
        }
        if (Test-Path -LiteralPath $Png) {
            if ($attempt -gt 1) {
                Write-Step ("{0}: screenshot only produced on the 2nd attempt (exit {1})" -f [System.IO.Path]::GetFileName($Png), $proc.ExitCode)
            }
            break
        }
        if ($attempt -eq 2) {
            Read-ShellLogTail
            throw "$Png produced no screenshot (exit $($proc.ExitCode))"
        }
        Write-Step ("{0} produced no screenshot on the first try (exit {1}), rerunning once" -f [System.IO.Path]::GetFileName($Png), $proc.ExitCode)
    }
    Write-Step ("{0} -> {1}" -f [System.IO.Path]::GetFileName($Png), $Png)
}

# --- 1. Build the screenshot build -----------------------------------------------------------
if (-not $SkipBuild) {
    Write-Step 'Building screenshot shell (build-shot/)'
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
    # Don't use Start-Process -Wait: in a non-interactive pipe vcvars64 -> VsDevCmd may wait for input and never exit.
    # Here redirect the standard streams, close stdin immediately (EOF), and drain output while waiting in WaitForExit.
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
        throw "Build did not finish within 20 minutes; terminated (see log: $log)"
    }
    $p.WaitForExit()
    [System.IO.File]::WriteAllText($log, $outTask.Result, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($errLog, $errTask.Result, (New-Object System.Text.UTF8Encoding($false)))
    if ($p.ExitCode -ne 0) {
        foreach ($l in @($log, $errLog)) {
            if (Test-Path -LiteralPath $l) { Get-Content -LiteralPath $l -Tail 20 | ForEach-Object { Write-Host $_ } }
        }
        throw "Screenshot build failed (exit $($p.ExitCode)); see log: $log"
    }
    # The build sometimes "keeps running the old exe despite errors" (e.g. qmlcachegen fails but the ninja code is swallowed),
    # so use the log as a fallback: treat FAILED or a QML syntax/type error as a failure to avoid capturing the old UI.
    $bad = @(Get-Content -LiteralPath $log, $errLog -ErrorAction SilentlyContinue |
             Where-Object { $_ -match 'FAILED:|error:|Expected token|is not a type|Binding loop' })
    if ($bad.Count -gt 0) {
        $bad | Select-Object -First 20 | ForEach-Object { Write-Host $_ }
        throw "Screenshot build has errors (see $log); not running the old exe"
    }
}
if (-not (Test-Path -LiteralPath $Exe)) { throw "Screenshot exe not found: $Exe" }

# --- 2. Capture screenshots view by view ---------------------------------------------------------
# Screenshots need real rendering (the offscreen platform produces no image), so use the Qt Quick software rendering backend to avoid depending on the GPU.
# Fix DPI to 96 and scale factor to 1: the machine is at 125% scaling, so Windows rasterizes the window at 1.25x and
# the screenshot becomes 1175x813; the review artwork is designed at 100% (940x650), so both must be fixed for a pixel-by-pixel comparison.
New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null
$env:QT_QUICK_BACKEND = 'software'
$env:QT_ENABLE_HIGHDPI_SCALING = '0'
$env:QT_SCALE_FACTOR = '1'
$env:QT_FONT_DPI = '96'
$env:PATH = "$BuildDir;$QtBin;$env:PATH"
$env:ORBBEC_SETUP_SHOT_DIR = $ShotDir.TrimEnd('\')

$names = @($Models.Split('|') | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
# Language-specific captures: append --lang; the shell still writes <view>.png (the file name comes from
# --view, not from the language), so rename to <view>-<shortlang>.png afterwards.
$langArgs = if ($Lang) { @('--lang', $Lang) } else { @() }
$langSuffix = if ($Lang) { '-' + $Lang.Split('_')[0] } else { '' }
$failed = New-Object System.Collections.Generic.List[string]
foreach ($v in $Views) {
    if ($names -notcontains $v) { continue }
    try {
        Invoke-Shot (@('--selftest', '--qml-smoke', '--view', $v) + $langArgs) (Join-Path $ShotDir "$v.png")
        if ($langSuffix) {
            Move-Item -LiteralPath (Join-Path $ShotDir "$v.png") -Destination (Join-Path $ShotDir "$v$langSuffix.png") -Force
        }
    }
    catch { Write-Step "Failed: $($_.Exception.Message)"; $failed.Add($v) }
}

# Install options: the same install settings page with one checkbox unchecked.
# The shell still names the screenshot after --view (options), so each time capture to options.png first, then rename to option-<key>.png.
# This step must come after all normal views: otherwise the options captured afterwards would overwrite the renamed files.
foreach ($k in $OptionKeys) {
    $name = "option-$k"
    if ($names -notcontains $name) { continue }
    try {
        Invoke-Shot (@('--selftest', '--qml-smoke', '--view', 'options', '--option', $k) + $langArgs) (Join-Path $ShotDir 'options.png')
        Move-Item -LiteralPath (Join-Path $ShotDir 'options.png') -Destination (Join-Path $ShotDir "$name$langSuffix.png") -Force
    } catch { Write-Step "Failed: $($_.Exception.Message)"; $failed.Add($name) }
}
if ($names -contains 'options') {
    try {
        Invoke-Shot (@('--selftest', '--qml-smoke', '--view', 'options') + $langArgs) (Join-Path $ShotDir 'options.png')
        if ($langSuffix) {
            Move-Item -LiteralPath (Join-Path $ShotDir 'options.png') -Destination (Join-Path $ShotDir "options$langSuffix.png") -Force
        }
    }
    catch { Write-Step "Failed: $($_.Exception.Message)"; $failed.Add('options') }
}

# After the normal views are captured, verify the install settings page's default checks and option passing (a real pass through "install").
# When the screenshot build has ORBBEC_SETUP_SHOT_DIR set, --selftest waits for a screenshot; here temporarily remove it via the environment variable,
# keeping only --selftest itself. The result is written to the shell log; seeing "Self-test: handing to engine" means passed.
$selftestLog = Join-Path $env:LOCALAPPDATA 'Orbbec\OrbbecSlicerSetup\logs\setup-shell.log'
$savedShotDir = $env:ORBBEC_SETUP_SHOT_DIR
$env:ORBBEC_SETUP_SHOT_DIR = ''
$env:ORBBEC_SETUP_SELFTEST_OPTIONS = '1'
try {
    $p = Start-Process -FilePath $Exe -ArgumentList @('--selftest') -NoNewWindow -PassThru
    if (-not $p.WaitForExit(30000)) { Stop-Process -Id $p.Id -Force; throw 'Self-test did not exit within 30 seconds' }
    $line = @(Get-Content -LiteralPath $selftestLog -Encoding UTF8 -ErrorAction SilentlyContinue |
              Where-Object { $_ -match 'Self-test: handing to engine' }) | Select-Object -Last 1
    if (-not $line) { throw "Self-test did not write the options line, see $selftestLog" }
    Write-Step $line
} finally {
    Remove-Item Env:\ORBBEC_SETUP_SELFTEST_OPTIONS -ErrorAction SilentlyContinue
    $env:ORBBEC_SETUP_SHOT_DIR = $savedShotDir
}

if ($failed.Count -gt 0) { throw "The following views failed to capture: $($failed -join ', ')" }
Write-Step 'Done'
