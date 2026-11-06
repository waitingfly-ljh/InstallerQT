@echo off
setlocal EnableExtensions
rem ==========================================================================
rem  build-installer.bat
rem  One-click build for the OrbbecSlicer installer (single-file Setup.exe).
rem
rem  Usage (from anywhere):
rem    build-installer.bat                      build only (toolchain must already exist)
rem    build-installer.bat install              fetch Qt + QIFW (idempotent), then build
rem    build-installer.bat install -Force       re-download + re-extract the toolchain
rem    build-installer.bat install -Compression 9
rem    build-installer.bat -Compression 9       pass options to build-product.ps1
rem    build-installer.bat -WithoutSetupUi      deliver the QIFW native package
rem    build-installer.bat -SkipInstallVerify   skip the install/uninstall loop
rem    build-installer.bat help                 show this help
rem
rem  Fresh clone / first run: just run
rem    build-installer.bat install
rem  ("install" may appear anywhere; every other argument is forwarded verbatim
rem   to packaging\qifw\product\build-product.ps1.)
rem
rem  Set NO_PAUSE=1 to avoid the final "Press any key" prompt (CI).
rem ==========================================================================

set "ROOT=%~dp0"
pushd "%ROOT%" >nul

rem  ---------------------------------------------------------------------------
rem  qifw dir detection -- supports two layouts:
rem    <repo root>\packaging\qifw   (standalone clone of this repo)
rem    <repo root>\qifw             (this repo placed under <upstream>\packaging)
rem  ---------------------------------------------------------------------------
set "QIFW_DIR=%ROOT%packaging\qifw"
if not exist "%QIFW_DIR%\toolchain\install-toolchain.ps1" if exist "%ROOT%qifw\toolchain\install-toolchain.ps1" set "QIFW_DIR=%ROOT%qifw"

set "TOOLCHAIN_PS1=%QIFW_DIR%\toolchain\install-toolchain.ps1"
set "CHECKENV_PS1=%QIFW_DIR%\toolchain\check-env.ps1"
set "PRODUCT_PS1=%QIFW_DIR%\product\build-product.ps1"

rem ---- split the "install" switch out; everything else is forwarded ---------
set "DO_INSTALL="
set "BUILD_ARGS="
:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="install"             goto take_install
if /i "%~1"=="toolchain"           goto take_install
if /i "%~1"=="--install-toolchain" goto take_install
if /i "%~1"=="-install-toolchain"  goto take_install
if /i "%~1"=="get-toolchain"       goto take_install
if /i "%~1"=="-Force"              goto take_force
if /i "%~1"=="--force"             goto take_force
if /i "%~1"=="help"                goto usage
if /i "%~1"=="-h"                  goto usage
if /i "%~1"=="--help"              goto usage
if /i "%~1"=="/?"                  goto usage
set "BUILD_ARGS=%BUILD_ARGS% "%~1""
shift
goto parse_args
:take_force
set "FORCE_TOOLCHAIN=1"
shift
goto parse_args
:take_install
set "DO_INSTALL=1"
shift
goto parse_args
:args_done

set "FORCE_ARG="
if defined FORCE_TOOLCHAIN set "FORCE_ARG= -Force"
if defined FORCE_TOOLCHAIN if not defined DO_INSTALL (
    echo [WARN] -Force only applies together with "install" ^(toolchain fetch^); ignored.
    echo.
)

echo.
echo ============================================================
echo  OrbbecSlicer installer build
echo  repo: %ROOT%
if defined DO_INSTALL echo  mode: fetch toolchain + build
if not defined DO_INSTALL echo  mode: build only (use "install" to fetch toolchain)
echo ============================================================
echo.

if not exist "%CHECKENV_PS1%" (
    echo [ERROR] %CHECKENV_PS1% not found.
    echo         Run this script from the repository root.
    goto :fail
)
if not exist "%PRODUCT_PS1%" (
    echo [ERROR] %PRODUCT_PS1% not found.
    echo         Run this script from the repository root.
    goto :fail
)

rem ---- 1/3 toolchain (only when asked) -------------------------------------
if defined DO_INSTALL (
    echo [1/3] Fetching toolchain: Qt 6.8.3 + QIFW 4.11.0 -- first run downloads about 270 MB, reruns are idempotent...
    if not exist "%TOOLCHAIN_PS1%" (
        echo [ERROR] %TOOLCHAIN_PS1% not found.
        goto :fail
    )
    powershell -NoProfile -ExecutionPolicy Bypass -File "%TOOLCHAIN_PS1%"%FORCE_ARG%
    if errorlevel 1 (
        echo.
        echo [ERROR] Toolchain fetch failed. Fix the error above, then rerun:
        echo         build-installer.bat install
        goto :fail
    )
    echo.
)

rem ---- 2/3 environment gate -------------------------------------------------
if defined DO_INSTALL (
    echo [2/3] Checking toolchain and environment...
) else (
    echo [1/2] Checking toolchain and environment...
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%CHECKENV_PS1%"
if errorlevel 1 (
    echo.
    echo [ERROR] Environment check failed. Fix the BLOCKING items above first.
    if not defined DO_INSTALL (
        echo         No toolchain yet? Run this to download Qt 6.8.3 + QIFW 4.11.0:
        echo             build-installer.bat install %BUILD_ARGS%
    )
    goto :fail
)

rem ---- 3/3 build ------------------------------------------------------------
echo.
if defined DO_INSTALL (
    echo [3/3] Building installer...
) else (
    echo [2/2] Building installer...
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PRODUCT_PS1%" %BUILD_ARGS%
if errorlevel 1 (
    echo.
    echo [ERROR] Build failed. See %QIFW_DIR%\out\product\^<timestamp^>\build-product.log
    goto :fail
)

rem ---- locate the newest output directory -----------------------------------
set "LATEST="
for /f "delims=" %%D in ('dir /b /ad /o-n "%QIFW_DIR%\out\product" 2^>nul') do (
    if not defined LATEST set "LATEST=%%D"
)

echo.
echo ============================================================
echo  BUILD OK
echo ============================================================
if defined LATEST (
    echo  Output dir: %QIFW_DIR%\out\product\%LATEST%
    echo.
    for %%F in ("%QIFW_DIR%\out\product\%LATEST%\*.exe") do echo    %%~nxF  %%~zF bytes
    echo.
    echo  Result: %QIFW_DIR%\out\product\%LATEST%\result.json
) else (
    echo  [WARN] No output directory found under %QIFW_DIR%\out\product
)

if /i not "%NO_PAUSE%"=="1" pause
popd >nul
exit /b 0

:usage
echo.
echo build-installer.bat - OrbbecSlicer installer build
echo.
echo   build-installer.bat                      build only (toolchain already present)
echo   build-installer.bat install              fetch Qt + QIFW, then build   ^<-- fresh clone
echo   build-installer.bat install -Force       re-download and re-extract the toolchain
echo   build-installer.bat install -Compression 9
echo   build-installer.bat help                 this help
echo.
echo   Aliases for "install": toolchain, --install-toolchain, -install-toolchain, get-toolchain
echo.
echo   Other arguments are forwarded to build-product.ps1:
echo     -Compression 0^|1^|3^|5^|7^|9   -ArchiveFormat 7z^|zip^|...   -SkipInstallVerify
echo     -StageRoot ^<abs dir^>          -UpstreamRepo ^<dir^>          -WithoutSetupUi
echo.
echo   Environment: NO_PAUSE=1  (no final pause, for CI)
echo   Docs: BUILD.md at the repository root
echo.
popd >nul
exit /b 0

:fail
echo.
echo Build aborted.
if /i not "%NO_PAUSE%"=="1" pause
popd >nul
exit /b 1
