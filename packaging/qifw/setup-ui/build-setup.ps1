#Requires -Version 5.1
<#
.SYNOPSIS
  Build the installer shell (Qt Quick UI) and deploy its runtime to dist/.

.DESCRIPTION
  Artifact layout:
    build/          CMake + MSVC build directory (safe to delete at any time)
    dist/           runnable OrbbecSlicerSetup.exe + Qt runtime + QML modules + qt.conf

  This script only writes build/ and dist/ under setup-ui/ and never touches the original project.
  Qt is registered through the manifest (toolchain/qt/<ver>/msvc2022_64),
  MSVC is located via vswhere, and CMake uses the version found in PATH.

.PARAMETER QtRoot
  Override the Qt root directory; defaults to reading from packaging/qifw/manifest.json.

.PARAMETER ConfigureOnly
  Run only the CMake configure step, no build (useful when debugging toolchain issues).

.PARAMETER SkipDeploy
  Skip windeployqt (useful when you only need the exe for a quick check; in this case dist/ is not standalone).

.PARAMETER Selftest
  After the build, run dist\OrbbecSlicerSetup.exe --selftest; a non-zero exit code means failure.

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
    # Delete build/ and dist/ and build from scratch (use when switching Qt versions or when deployment leaves residue).
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

Write-Both "Repo root: $RepoRoot"
Write-Both "Shell source: $Here"

# --- 1. Resolve Qt (parameter first, then manifest) ---------------------------------
if (-not $QtRoot) {
    $manifestPath = Join-Path $RepoRoot 'packaging\qifw\toolchain\manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { Fail "Toolchain manifest not found: $manifestPath" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $QtRoot = Join-Path $RepoRoot $manifest.qt.installDir
}
$QtRoot = (Resolve-Path -LiteralPath $QtRoot).ProviderPath
$QtBin = Join-Path $QtRoot 'bin'
foreach ($f in @('Qt6Core.dll', 'Qt6Quick.dll', 'Qt6Qml.dll', 'windeployqt.exe', 'qmlimportscanner.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $QtBin $f))) { Fail "Incomplete Qt directory, missing bin\${f}: $QtRoot" }
}
$qtVersion = $null
$qmake = Join-Path $QtBin 'qmake.exe'
if (Test-Path -LiteralPath $qmake) { $qtVersion = (& $qmake -query QT_VERSION 2>$null) }
if (-not $qtVersion) {
    $qtVersion = (Get-Item (Join-Path $QtBin 'Qt6Core.dll')).VersionInfo.FileVersion
}
$qtVersion = "$qtVersion".Trim()
Write-Both "Qt: $QtRoot ($qtVersion)"

# --- 2. Locate MSVC and CMake --------------------------------------------------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) { Fail 'vswhere.exe not found; Visual Studio 2022 is required (with the Desktop development with C++ workload)' }
$vsPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
if (-not $vsPath) { Fail 'vswhere found no Visual Studio instance with MSVC x64 tools; expected: VS 2022 + "Desktop development with C++"' }
$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars)) { Fail "vcvars64.bat not found: $vcvars" }
$cmake = (Get-Command cmake.exe -ErrorAction SilentlyContinue).Source
if (-not $cmake) { Fail 'cmake.exe not found in PATH (3.21+ required)' }
$cmakeVersion = (& $cmake --version | Select-Object -First 1)
Write-Both "MSVC: $vsPath"
Write-Both "CMake: $cmakeVersion"
Write-Both "Compiler: $(Split-Path -Parent (Split-Path -Parent $vcvars))"

# --- 3. Configure and build (run inside the vcvars64 environment so cl/ninja are visible) --------------
# Drive with a .bat file instead of passing the whole command string to cmd /c: nested
# quotes are unreliable in a cmd launched from Git Bash; a batch file handles paths with spaces fine.
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
$batPath = Join-Path $Here 'out\build-setup.cmd'
if ($Clean) {
    foreach ($d in @($BuildDir, $DistDir)) {
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
    }
    Write-Both 'Cleaned build/ and dist/'
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
# Don't use Start-Process -Wait: in a non-interactive pipe vcvars64 -> VsDevCmd may wait for input and never exit.
# Redirect all three standard streams, close stdin (EOF) at the start, and drain output asynchronously to avoid filling the pipe.
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
    Fail "Build did not finish within 30 minutes (see log: $cmdOut)"
}
$p.WaitForExit()
[System.IO.File]::WriteAllText($cmdOut, $outTask.Result, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText(($cmdOut + '.err'), $errTask.Result, (New-Object System.Text.UTF8Encoding($false)))
if ($p.ExitCode -ne 0) {
    Get-Content -LiteralPath $cmdOut -Encoding UTF8 -Tail 40 | ForEach-Object { Write-Both $_ 'CMAKE' }
    Get-Content -LiteralPath ($cmdOut + '.err') -Encoding UTF8 -Tail 20 | ForEach-Object { Write-Both $_ 'CMAKE' }
    Fail "Build failed (exit $($p.ExitCode)); full log: $cmdOut"
}
Write-Both 'Build completed'

if ($ConfigureOnly) { Write-Both 'Configure-only mode, done'; exit 0 }

$built = Join-Path $BuildDir 'OrbbecSlicerSetup.exe'
if (-not (Test-Path -LiteralPath $built)) { Fail "Build artifact not found: $built" }
Copy-Item -LiteralPath $built -Destination (Join-Path $DistDir 'OrbbecSlicerSetup.exe') -Force
Write-Both ("Shell exe: {0:N0} B" -f (Get-Item (Join-Path $DistDir 'OrbbecSlicerSetup.exe')).Length)
$launcher = Join-Path $BuildDir 'OrbbecSlicerSetupLauncher.exe'
if (-not (Test-Path -LiteralPath $launcher)) { Fail "Launcher not found: $launcher" }
Write-Both ("Launcher exe: {0:N0} B ({1})" -f (Get-Item $launcher).Length, $launcher)

# --- 4. Deploy Qt runtime (including QML modules) --------------------------------------
# Before deploying, use qmlimportscanner to compute the required modules from the real imports in the source,
# and compare against the list declared in this script: fail immediately on a missing module instead of waiting for a blank screen at runtime.
$qmlRoot = Join-Path $QtRoot 'qml'
$requiredModules = @(
    'QtQuick',                 # base elements (implicitly depends on QtQuick.Window, for ApplicationWindow)
    'QtQuick.Layouts',         # ColumnLayout / RowLayout / StackLayout
    'QtQuick.Controls',        # common module required by Controls.Basic (only deploy the Basic style)
    'QtQuick.Controls.Basic',  # style explicitly imported by the UI
    'QtQuick.Dialogs'          # FolderDialog
)
$scannerOut = Join-Path $Here 'out\qmlimportscanner.json'
$scannerErr = $scannerOut + '.err'
# qmlimportscanner writes JSON to stdout by default (Qt 6.8 has no -json/-output option).
$sp = Start-Process -FilePath (Join-Path $QtBin 'qmlimportscanner.exe') `
    -ArgumentList @('-rootPath', $Here, '-importPath', $qmlRoot) `
    -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput $scannerOut -RedirectStandardError $scannerErr
if ($sp.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $scannerOut)) {
    Get-Content -LiteralPath $scannerErr -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Both $_ 'SCANNER' }
    Fail "qmlimportscanner failed (exit $($sp.ExitCode)); see log: $scannerOut"
}
$scanned = Get-Content -LiteralPath $scannerOut -Raw -Encoding UTF8 | ConvertFrom-Json
$foundModules = @($scanned | Where-Object { $_.type -eq 'module' } | ForEach-Object { $_.name } | Sort-Object -Unique)
$missingModules = @($requiredModules | Where-Object { $foundModules -notcontains $_ })
$scratchModules = @($scanned | Where-Object { $_.type -eq 'module' -and ($_.path -eq '' -or $null -eq $_.path) -and $_.name -notmatch '^SetupUi$' } | ForEach-Object { $_.name })
if ($scratchModules.Count -gt 0) { Write-Both ("Unresolved QML imports: {0}" -f ($scratchModules -join ', ')) 'WARN' }
if ($missingModules.Count -gt 0) {
    Fail ("Missing required QML modules: {0}. Actual imports in source: {1}" -f ($missingModules -join ', '), ($foundModules -join ', '))
}
foreach ($m in $requiredModules) {
    $dir = Join-Path $qmlRoot ($m -replace '\.', '/')
    if (-not (Test-Path -LiteralPath $dir)) { Fail "Qt installation is missing the QML module directory: $dir" }
}
Write-Both ("QML module verification passed: {0}" -f ($requiredModules -join ', '))

if ($SkipDeploy) {
    Write-Both 'Skipping windeployqt as requested (-SkipDeploy): dist is not standalone' 'WARN'
}
else {
    $windeploy = Join-Path $QtBin 'windeployqt.exe'
    $deployOut = Join-Path $Here 'out\windeployqt.log'
    $exe = Join-Path $DistDir 'OrbbecSlicerSetup.exe'
    $deployArgs = @(
        "`"$exe`"", '--release', '--no-translations', '--no-opengl-sw', '--no-system-d3d-compiler',
        # Deploy only the Basic style: the UI does not use Fusion/Material/Windows/Universal, etc.,
        # so fewer QML files and DLLs are copied and the package size can be checked per module.
        '--exclude-plugins', 'qmltooling,tls',
        '--qmldir', "`"$Here`""
    )
    $env:PATH = "$QtBin;$env:PATH"
    $dp = Start-Process -FilePath $windeploy -ArgumentList $deployArgs -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $deployOut -RedirectStandardError ($deployOut + '.err')
    Get-Content -LiteralPath $deployOut -Encoding UTF8 | Select-Object -Last 15 | ForEach-Object { Write-Both $_ 'DEPLOY' }
    if ($dp.ExitCode -ne 0) { Fail "windeployqt failed (exit $($dp.ExitCode)); see log: $deployOut" }

    # windeployqt no longer generates qt.conf automatically; without it Qt looks for plugins/QML in the Qt install directory,
    # which means missing modules on a clean machine. Write one explicitly here: plugins are next to the exe, QML is in ./qml.
    $qtConfPath = Join-Path $DistDir 'qt.conf'
    $qtConf = "[Paths]`r`nPrefix = .`r`nPlugins = .`r`nQml2Imports = qml`r`n"
    [System.IO.File]::WriteAllText($qtConfPath, $qtConf, (New-Object System.Text.ASCIIEncoding))
    Write-Both 'Wrote qt.conf (Prefix=. / Plugins=. / Qml2Imports=qml)'

    # --selftest uses the minimal platform (no window); windeployqt only deploys qwindows,
    # so add it from the toolchain here so the self-test runs on both the build machine and a clean machine.
    $platformDir = Join-Path $DistDir 'platforms'
    foreach ($dll in @('qminimal.dll', 'qwindows.dll')) {
        $src = Join-Path $QtRoot "plugins\platforms\$dll"
        $dst = Join-Path $platformDir $dll
        if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
            New-Item -ItemType Directory -Force -Path $platformDir | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst
            Write-Both "Added platform plugin: $dll"
        }
    }

    # Deployment manifest summary: record which DLLs and QML modules were deployed, to help diagnose "missing modules on a clean machine".
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
    Write-Both ("Deployment complete: {0} files / {1:N0} B / {2} DLLs / {3} QML modules (manifest {4})" -f `
            $manifest.fileCount, $manifest.totalBytes, $manifest.dllCount, $manifest.qmlModules.Count, $manifestPath)
    if (-not $manifest.hasQtConf) { Write-Both 'dist is missing qt.conf: the shell may not find the QML import path' 'WARN' }
    if (-not $manifest.hasMinimalPlatform) { Write-Both 'dist is missing platforms\qminimal.dll: --selftest will fail' 'WARN' }
    $lost = @($requiredModules | Where-Object { $qmlModules -notcontains ($_ -replace '\.', '/') })
    if ($lost.Count -gt 0) { Fail ("dist/qml is missing modules: {0}" -f ($lost -join ', ')) }
    Write-Both 'Deployment verification passed: all required QML modules such as QtQuick are present in dist/qml'
}

# --- 4b. Build self-contained uninstaller ---------------------------------------------------
$uninstallerExe = Join-Path $BuildDir 'OrbbecSlicerUninstaller.exe'
$pkgUninstaller = Join-Path $Here 'package-uninstaller.ps1'
if (-not (Test-Path -LiteralPath $pkgUninstaller)) { Fail "package-uninstaller.ps1 not found: $pkgUninstaller" }
if (-not (Test-Path -LiteralPath $launcher)) { Fail "Launcher not found: $launcher" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pkgUninstaller `
    -LauncherExe $launcher -UiDir $DistDir -OutputPath $uninstallerExe -Version $Version
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $uninstallerExe)) {
    Fail "Failed to build uninstaller (exit $LASTEXITCODE)"
}
Write-Both ("Uninstaller exe: {0:N0} B ({1})" -f (Get-Item $uninstallerExe).Length, $uninstallerExe)

# The brand icon must be embedded in all three exes (shell / launcher / uninstaller); check via RT_GROUP_ICON in the PE resource table.
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
    if (-not [IconProbe]::HasGroupIcon($exeWithIcon)) { Fail "Missing brand icon: $exeWithIcon" }
}
Write-Both 'Icon verification passed: shell / launcher / uninstaller all contain the brand icon'


# --- 5. Startup self-test ------------------------------------------------------------
if ($Selftest) {
    $exe = Join-Path $DistDir 'OrbbecSlicerSetup.exe'
    $stOut = Join-Path $Here 'out\selftest.log'
    $st = Start-Process -FilePath $exe -ArgumentList @('--selftest') -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stOut -RedirectStandardError ($stOut + '.err')
    Get-Content -LiteralPath $stOut, ($stOut + '.err') -Encoding UTF8 -ErrorAction SilentlyContinue |
        Select-Object -First 20 | ForEach-Object { Write-Both $_ 'SELFTEST' }
    if ($st.ExitCode -ne 0) { Fail "Startup self-test failed (exit $($st.ExitCode)); see log: $stOut" }

    # Under the real platform the main window must actually be shown (the shotWindow used for screenshots cannot replace this step).
    $winOut = Join-Path $Here 'out\selftest-window.log'
    $sw = Start-Process -FilePath $exe -ArgumentList @('--selftest', '--check-window') -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $winOut -RedirectStandardError ($winOut + '.err')
    Get-Content -LiteralPath $winOut, ($winOut + '.err') -Encoding UTF8 -ErrorAction SilentlyContinue |
        Select-Object -First 20 | ForEach-Object { Write-Both $_ 'SELFTEST' }
    if ($sw.ExitCode -ne 0) { Fail "Main-window display self-test failed (exit $($sw.ExitCode)); see log: $winOut" }

    # Uninstall mode: launching from the system uninstall entry must show the branded uninstall window directly.
    $uninstOut = Join-Path $Here 'out\selftest-uninstall.log'
    $su = Start-Process -FilePath $exe -ArgumentList @('--selftest', '--uninstall', '--check-window') -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $uninstOut -RedirectStandardError ($uninstOut + '.err')
    Get-Content -LiteralPath $uninstOut, ($uninstOut + '.err') -Encoding UTF8 -ErrorAction SilentlyContinue |
        Select-Object -First 20 | ForEach-Object { Write-Both $_ 'SELFTEST' }
    if ($su.ExitCode -ne 0) { Fail "Uninstall window self-test failed (exit $($su.ExitCode)); see log: $uninstOut" }

    # Self-contained uninstaller: after extraction it must show the uninstall window directly and exit 0 (--selftest does not trigger self-delete).
    $uninstSelfLog = Join-Path $Here 'out\selftest-uninstaller-exe.log'
    $sx = Start-Process -FilePath $uninstallerExe -ArgumentList @('--selftest', '--uninstall', '--check-window') -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $uninstSelfLog -RedirectStandardError ($uninstSelfLog + '.err')
    Get-Content -LiteralPath $uninstSelfLog, ($uninstSelfLog + '.err') -Encoding UTF8 -ErrorAction SilentlyContinue |
        Select-Object -First 20 | ForEach-Object { Write-Both $_ 'SELFTEST' }
    if ($sx.ExitCode -ne 0) { Fail "Uninstaller self-test failed (exit $($sx.ExitCode)); see log: $uninstSelfLog" }

    # Progress finish timing (success 600ms / failure 300ms).
    $timingLog = Join-Path $Here 'out\selftest-finish-timing.log'
    $st2 = Start-Process -FilePath $exe -ArgumentList @('--selftest', '--check-finish-timing') -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $timingLog -RedirectStandardError ($timingLog + '.err')
    Get-Content -LiteralPath $timingLog, ($timingLog + '.err') -Encoding UTF8 -ErrorAction SilentlyContinue |
        Select-Object -First 20 | ForEach-Object { Write-Both $_ 'SELFTEST' }
    if ($st2.ExitCode -ne 0) { Fail "Progress finish self-test failed (exit $($st2.ExitCode)); see log: $timingLog" }

    # The completion page title uses runMode (fresh should not show "Repair complete").
    $runModeLog = Join-Path $Here 'out\selftest-run-mode.log'
    $st3 = Start-Process -FilePath $exe -ArgumentList @('--selftest', '--check-run-mode') -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $runModeLog -RedirectStandardError ($runModeLog + '.err')
    Get-Content -LiteralPath $runModeLog, ($runModeLog + '.err') -Encoding UTF8 -ErrorAction SilentlyContinue |
        Select-Object -First 20 | ForEach-Object { Write-Both $_ 'SELFTEST' }
    if ($st3.ExitCode -ne 0) { Fail "runMode self-test failed (exit $($st3.ExitCode)); see log: $runModeLog" }
    Write-Both 'Startup self-test passed (--selftest / --check-window / --uninstall --check-window / uninstaller / progress finish / runMode all exit 0)'
}

Write-Both 'Shell build complete'
exit 0
