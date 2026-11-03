@echo off
setlocal EnableExtensions
rem ==========================================================================
rem  build-installer.bat
rem  One-click build for the OrbbecSlicer installer (single-file Setup.exe).
rem
rem  Usage (from anywhere):
rem    build-installer.bat                     full build (shell + Setup.exe)
rem    build-installer.bat -Compression 9      pass options to build-product.ps1
rem    build-installer.bat -WithoutSetupUi     deliver the QIFW native package
rem    build-installer.bat -SkipInstallVerify  skip the install/uninstall loop
rem
rem  Set NO_PAUSE=1 to avoid the final "Press any key" prompt (CI).
rem ==========================================================================

set "ROOT=%~dp0"
pushd "%ROOT%" >nul

echo.
echo ============================================================
echo  OrbbecSlicer installer build
echo  repo: %ROOT%
echo ============================================================
echo.

if not exist "%ROOT%packaging\qifw\toolchain\check-env.ps1" (
    echo [ERROR] packaging\qifw\toolchain\check-env.ps1 not found.
    echo         Run this script from the repository root.
    goto :fail
)

echo [1/2] Checking toolchain and environment...
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%packaging\qifw\toolchain\check-env.ps1"
if errorlevel 1 (
    echo.
    echo [ERROR] Environment check failed. Fix the BLOCKING items above first.
    goto :fail
)

echo.
echo [2/2] Building installer...
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%packaging\qifw\product\build-product.ps1" %*
if errorlevel 1 (
    echo.
    echo [ERROR] Build failed. See packaging\qifw\out\product\<timestamp>\build-product.log
    goto :fail
)

rem ---- locate the newest output directory -----------------------------------
set "LATEST="
for /f "delims=" %%D in ('dir /b /ad /o-n "%ROOT%packaging\qifw\out\product" 2^>nul') do (
    if not defined LATEST set "LATEST=%%D"
)

echo.
echo ============================================================
echo  BUILD OK
echo ============================================================
if defined LATEST (
    echo  Output dir: %ROOT%packaging\qifw\out\product\%LATEST%
    echo.
    for %%F in ("%ROOT%packaging\qifw\out\product\%LATEST%\*.exe") do echo    %%~nxF  %%~zF bytes
    echo.
    echo  Result: %ROOT%packaging\qifw\out\product\%LATEST%\result.json
) else (
    echo  [WARN] No output directory found under packaging\qifw\out\product
)

if /i not "%NO_PAUSE%"=="1" pause
popd >nul
exit /b 0

:fail
echo.
echo Build aborted.
if /i not "%NO_PAUSE%"=="1" pause
popd >nul
exit /b 1
