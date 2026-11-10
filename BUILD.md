# From git clone to a built installer

This document is for people who have **only cloned this repository and have no Qt / QIFW toolchain on the machine**.
Follow the steps in order; the whole flow only requires "installing a few standard Windows development tools + running a few commands", and the scripts download the toolchain themselves.

> Directory convention: below, `<repo>` means your clone directory (for example `D:\work\install-qt`).
> All commands are run inside `<repo>`, using **Windows PowerShell 5.1** (built into the OS, not PowerShell 7).

---

## 0. First, understand: what is and isn't in the repository

| Item | Committed | Notes |
| --- | --- | --- |
| Packaging scripts `packaging/qifw/**/*.ps1`, `manifest.json` | ✅ | Toolchain versions, download URLs, and sha256 are all pinned here |
| Installer shell source `packaging/qifw/setup-ui/` (Qt Quick + C++) | ✅ | The UI part that builds the single-file `Setup.exe` |
| One-click script `build-installer.bat` | ✅ | Internally runs `check-env.ps1` first, then `build-product.ps1` |
| **Qt 6.8.3 + QIFW 4.11 toolchain** (about 2.1 GB unpacked) | ❌ gitignore | Downloaded into the repository by `install-toolchain.ps1` |
| `packaging/qifw/out/` (artifacts, archive cache, logs) | ❌ gitignore | Generated on every build |
| **The product OrbbecSlicer's program tree (staging)** | ❌ not in this repository | Comes from the build output of the `orbbecslicer` source repository |

So after cloning you **must do two things**: ① get the toolchain; ② obtain the staging tree.
If you only want to verify the installer itself (shell / packaging pipeline / smoke package), you can skip ②; see 3.3 and 3.4.

---

## 1. Three prerequisites you must read

1. **You must `git clone`; do not use "Download ZIP" from the web page.**
   The scripts locate the repository root by walking up to find `.git` (`Get-RepoRoot` in `_common.ps1`); without `.git` they immediately report
   `Cannot find the repository root (.git) walking up from ...`.
2. **The toolchain can only live inside the repository.**
   The tool root is fixed at `packaging/qifw/toolchain/qt` (`toolchainRoot` in `manifest.json`);
   pointing outside the repository or using an absolute path will be rejected by the path guard. You can clone to any drive, but reserve **about 10 GB** of disk:
   toolchain 2.1 GB + archive cache 0.3 GB + staging working copy 0.5 GB + install verification directory 0.5 GB + artifacts.
3. **This repository does not modify or write to the product repository.**
   During real packaging it only **reads** the staging tree and `version.inc`, so the staging path must be specified explicitly by you (see 3.5).

---

## 2. Machine requirements

| Dependency | Necessity | Check command | Notes |
| --- | --- | --- | --- |
| Windows 10 1803+ / 11, 64-bit | Required | `[Environment]::Is64BitOperatingSystem` | |
| Windows PowerShell 5.1 | Required | `$PSVersionTable.PSVersion` | Built into the OS; the scripts are written against 5.1 syntax |
| Python 3.8+ (`pip` available) | Required | `python --version` | Only used to unpack 7z; if `py7zr` is missing the script automatically runs `pip install py7zr` |
| `curl.exe` | Required | `curl.exe --version` | Built in on Win10 1803+ |
| VC++ 2015-2022 runtime | Required | `Test-Path C:\Windows\System32\vcruntime140.dll` | Without it, Qt/QIFW tools report `0xc000007b` |
| Visual Studio 2022 + "Desktop development with C++" | Needed when building the shell | `& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property displayName` | Provides MSVC x64 and Ninja |
| CMake 3.21+, **on PATH** | Needed when building the shell | `cmake --version` | Note: `build-setup.ps1` looks for cmake in the **current PowerShell's PATH**, and does not recognize the path bundled with VS |
| 7-Zip CLI | Optional | `7z` | `binarycreator` bundles its own 7z, so packaging works without it |
| Git | Required | `git --version` | |

The easiest way to install CMake: `winget install --id Kitware.CMake -e`; after installing, **reopen the terminal** and confirm `cmake --version` prints output.

> When delivering only the QIFW native package (`-WithoutSetupUi`, i.e. without building the Qt shell), **neither VS 2022 nor CMake is a hard blocker**:
> `check-env.ps1` treats them as non-blocking notices; they only affect the `Setup.exe` step (3.3).

---

## 3. Five steps

> In a hurry? Just read this one: **`.\build-installer.bat install`** (fetch toolchain + package in one go). The breakdown below
> is for troubleshooting, for doing only one thing, or for seeing what each step is checking.

### 3.1 Get the toolchain: one command

```powershell
git clone <repository URL> install-qt
cd install-qt
.\build-installer.bat install
```

`install` means "fetch the toolchain first, then package": the script downloads Qt 6.8.3 + QIFW 4.11.0 in sequence, verifies the official `.sha256`, unpacks,
runs health checks, and then builds the installer directly. **Without `install` it only packages and does not download** (use this when the toolchain already exists).

- Download sources and checksums both come from the official site: Qt 6.8.3 `win64_msvc2022_64` (7 archives) + QIFW 4.11.0 from `download.qt.io`.
  Each archive is first verified against the official `.sha256`; a mismatch aborts immediately and nothing is unpacked.
- **Idempotent; you can interrupt and re-run at any time**: already-downloaded archives in `packaging/qifw/out/archives/` are skipped,
  and existing Qt / QIFW directories are also skipped. To force a re-download and re-unpack: `build-installer.bat install -Force` (or delete `packaging/qifw/toolchain/qt`).
- If your corporate network requires a proxy, set the environment variables first (`curl` honors these two):

```powershell
$env:HTTP_PROXY  = 'http://user:pass@proxy:8080'
$env:HTTPS_PROXY = 'http://user:pass@proxy:8080'
```

When finished, the directory looks like:

```
packaging/qifw/toolchain/qt/6.8.3/msvc2022_64/                       Qt
packaging/qifw/toolchain/qt/Tools/QtInstallerFramework/4.11.0/bin/   binarycreator / installerbase / archivegen / repogen
```

> The 4 ps1 files under `packaging/qifw/toolchain/` (`install-toolchain.ps1` / `fetch-qt-archives.ps1` /
> `fetch-ifw.ps1` / `check-env.ps1`) are internal implementation of `build-installer.bat` and **normally do not need to be called separately**;
> run them directly only when troubleshooting or when you want to do just one half (`-SkipQt` / `-SkipIfw`).

### 3.2 Self-check (only exit code 0 means usable; `build-installer.bat` runs this step itself)

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\check-env.ps1
"exit=$LASTEXITCODE"
```

The output has three sections: `Prerequisites` (OS / MSVC / CMake / VC runtime / 7-Zip), `Path guard`, and `Tools`.
`FAIL` = blocking item; fix it following the hint after `->`. `WARN` = optional, e.g. 7-Zip not installed.
The last line must be `Overall conclusion: available`. Use `-Json` when consuming it from a script.

### 3.3 Build only the installer shell (no product, no staging needed)

This is the fastest "prove the environment works" path: compile the Qt Quick shell, deploy the Qt runtime, and run the full self-check.

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\setup-ui\build-setup.ps1 -Version 0.3.0-beta.5 -Selftest
```

The script asserts in sequence: CMake configure and build → Chinese translation `lrelease` output and `.qm` embedded in the exe → QML modules
(QtQuick / Layouts / Controls / Controls.Basic / Dialogs) all present → `windeployqt` deployment + `qt.conf` written
→ all three exes carry the brand icon → `--selftest` / `--check-window` / `--uninstall --check-window` / uninstaller self-check / progress timing / runMode.
If any item fails it exits non-zero; logs are in `packaging/qifw/setup-ui/out/`.

Artifacts: `packaging/qifw/setup-ui/dist/` (`OrbbecSlicerSetup.exe` + Qt DLLs + `qml/` + `qt.conf`, can be double-clicked directly).

> Add `-Clean` when switching Qt versions or when deployment leftovers remain; add `-ConfigureOnly` if you only want to see whether configuration passes.

### 3.4 Verify only the QIFW packaging pipeline (smoke package, no product needed)

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\smoke\run-smoke.ps1
```

Generates a 4-file mini installer, then silent install → per-file verification → uninstall → leftover check → shortcut assertions.
Artifacts and `result.json` are in `packaging/qifw/out/smoke/<timestamp>/`.
By this point you have verified that the "toolchain + install/uninstall pipeline" all works.

### 3.5 Real product packaging (requires a staging tree)

`build-product.ps1` needs two read-only inputs:

| Input | Default | Parameter |
| --- | --- | --- |
| Product staging tree (OrbbecSlicer program directory, containing `ob-slicer.exe`, `resources\`, etc.) | `D:\Orbbec\orbbecslicer\build\presets\windows-release\OrbbecSlicer` | `-StageRoot` (must be an **absolute path**) |
| Version number source, `set(SLICER_APP_VERSION "...")` in `version.inc` | `D:\Orbbec\orbbecslicer\version.inc` | `-UpstreamRepo` |

**Where staging comes from — pick one of three based on what you have at hand:**

**A. You have the orbbecslicer source repository (recommended)** — build its `windows-release` preset directly and install:

```powershell
cd D:\Orbbec\orbbecslicer
cmake --preset windows-release
cmake --build --preset windows-release --target install
# the output is the staging tree: D:\Orbbec\orbbecslicer\build\presets\windows-release\OrbbecSlicer
```

(That project's `CMAKE_INSTALL_PREFIX` defaults to `${CMAKE_BINARY_DIR}/OrbbecSlicer`,
so the directory produced by the `install` target is exactly the staging shape this repository needs. `scripts\build_package.bat` in the source
is the old "build + NSIS packaging" flow; this repository does not need NSIS.)

**B. You only have an installed OrbbecSlicer on one machine** — use the installation directory directly as staging:

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\product\build-product.ps1 `
    -StageRoot "C:\Program Files\OrbbecSlicer" `
    -UpstreamRepo "D:\path\to\orbbecslicer"     # only needs to be able to read version.inc
```

**C. Copy a complete staging tree from a colleague's machine** — copy it to any location on your machine and point `-StageRoot` at it.
(When `resources\images\app_logo.ico` exists, the installer includes the brand icon; when it does not, the default icon is used and nothing is blocked.)

**One-click packaging** (reads staging, builds the shell, assembles the single-file `Setup.exe`, silent install + per-file comparison + uninstall round-trip):

```powershell
.\build-installer.bat install                    # first time: fetch toolchain + package (one command does it all)
.\build-installer.bat                            # afterwards: toolchain already ready, package directly
# specify staging / version source
.\build-installer.bat -StageRoot "D:\stage\OrbbecSlicer" -UpstreamRepo "D:\src\orbbecslicer"
# deliver only the QIFW native package (skip shell and install verification, fastest)
.\build-installer.bat -WithoutSetupUi -SkipInstallVerify
# higher compression
.\build-installer.bat -Compression 9
# do not pause in CI
set NO_PAUSE=1
# forgot the parameters
.\build-installer.bat help
```

`install` can be placed anywhere (the parameters after it are still forwarded to `build-product.ps1`):
`build-installer.bat install -StageRoot "D:\stage\OrbbecSlicer" -Compression 9`.
The toolchain-fetch step is idempotent; running with `install` each time just does one extra verification; to force a re-download and re-unpack, add `-Force`.

Note that `build-installer.bat` **always runs `check-env.ps1` first**; if it fails it exits immediately and tells you to use
`build-installer.bat install` — pick that when you have no toolchain, and don't try to remember the ps1 paths yourself.

Artifacts are in `packaging/qifw/out/product/<timestamp>/`:

- `OrbbecSlicer-<version>-x64-Setup.exe` + `.sha256` — the deliverable (single file, including UI and Qt runtime)
- `OrbbecSlicer-<version>-x64-Installer.exe` + `.sha256` — QIFW native package (intermediate artifact)
- `result.json` (per-step timing, staging summary, install/uninstall verification results), `build-product.log`, `setup-shell.log`

> **Artifact bytes are not reproducible**: `binarycreator` writes the current build time and a random temporary qrc file name into the artifact, so the same
> input yields a different SHA-256 every time. To judge "the same source produces the same content", look at `staging.digestBefore` in `result.json`
> and `installVerified` / `diffCount`; do not compare the exe's hash. When releasing, you must use the `.sha256` generated by the **current** run.

---

## 4. Intranet / fully offline machines

When the target machine cannot reach `download.qt.io` and its CDN, **do not try to build QIFW from source** (it requires a static Qt + liblzma/zlib/bzip2,
and the cost far outweighs the benefit; steps are in "Offline fallback" in `packaging/qifw/README.md`). The correct approach is to move the archives:

1. On a machine with internet access, run through 3.1 once to obtain the 8 `.7z` files under `packaging/qifw/out/archives/`
   and their respective `.sha256` files (7 for Qt + 1 for QIFW, about 270 MB in total).
2. Copy all 16 files as a whole to the same directory `packaging/qifw/out/archives/` on the offline machine.
3. On the offline machine, execute in sequence (the first only verifies, the second unpacks; archives already in the cache are not downloaded again):

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\fetch-qt-archives.ps1 -VerifyOnly
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\install-toolchain.ps1
```

4. If the offline machine also cannot reach PyPI, you need to install `py7zr` offline first: `pip install py7zr` (or copy the wheel to the machine and
   `pip install py7zr-*.whl`), otherwise the unpack step will fail.

---

## 5. Common errors → handling

| Error / symptom | Cause and handling |
| --- | --- |
| `Cannot find the repository root (.git) walking up from ...` | ZIP download was used, or the command is not run in the clone directory → `git clone`, and run the command under `<repo>` |
| `python not found (3.8+). Install it and add it to PATH.` | Install Python and check Add to PATH, then reopen the terminal |
| `pip install py7zr failed` | No PyPI on the intranet: install `py7zr` manually and run again, see section 4 |
| `curl.exe not found` | OS too old or PATH modified; confirm from `C:\Windows\System32\curl.exe` |
| `Archive verification failed, extraction aborted.` | Download tampered with by a proxy/gateway (you got back an HTML page). Delete that `.7z` and its `.sha256`, then re-run |
| `0xc000007b` / `not a valid Win32` / tools crash as soon as they start | Missing VC++ runtime → install Microsoft Visual C++ 2015-2022 Redistributable (x64) |
| `vswhere.exe not found` / `vswhere found no Visual Studio instance with MSVC x64 tools` | Install VS 2022 and check "Desktop development with C++" |
| `cmake.exe not found in PATH (3.21+ required)` | Install CMake or add VS's bundled CMake to the system PATH; note that it checks the **current terminal's** PATH |
| `lrelease.exe not found in ...\bin` / `Incomplete Qt directory, missing bin\...` | Qt unpack incomplete → `build-installer.bat install -Force` to fetch again |
| `Translation source not found: ...translations\OrbbecSlicerSetup_zh_CN.ts` | The clone is missing `translations/` (see section 6) |
| `Staging tree does not exist:` / `Staging tree ... must be an absolute path` | `-StageRoot` was given a relative path or points to the wrong directory |
| `Version source not found: ...\version.inc` | `-UpstreamRepo` points to a directory without `version.inc` |
| `Toolchain does not match the manifest registration` | The directory contains another Qt/QIFW version → `build-installer.bat install -Force` to fetch again |
| `Environment check failed` + `Missing ... binarycreator.exe` | The toolchain has not been downloaded yet → `build-installer.bat install` |
| `binarycreator` only prints `Usage:` and then exits 1 | Wrong arguments (the script already fixes them as `-c <config.xml file> -p <packages> -t <installerbase.exe> --ac <0\|1\|3\|5\|7\|9>`; `--ac` does not support 2 and 4) |
| No `maintenancetool.exe` after silent install, `diffCount>0` | Commonly caused by antivirus killing the unpack process midway. The script already cleans up and retries once automatically; if it still fails, add the repository directory and `%TEMP%` to the antivirus whitelist |
| `Failed to assemble Setup.exe` / `Shell build failed` | Check `build-product.log` and `setup-shell.log`; most are shell-side issues, so run 3.3 alone first to locate them |

---

## 6. Artifacts, cleanup, and pre-commit checks

```powershell
# full cleanup (back to the "source only" state)
Remove-Item -Recurse -Force .\packaging\qifw\toolchain\qt, .\packaging\qifw\out, `
    .\packaging\qifw\setup-ui\build, .\packaging\qifw\setup-ui\dist, .\packaging\qifw\setup-ui\out
```

Script write boundaries: the tool root, `out/`, `staging-work/`, and temporary install directories are all inside the repository; out-of-bounds paths are rejected;
the only exception is `%TEMP%\binarycreator-*` created by `binarycreator` itself (it cannot be turned off with a parameter and is deleted automatically on exit).

**Maintainers, please confirm before committing**: `packaging/qifw/setup-ui/translations/OrbbecSlicerSetup_zh_CN.ts` must be committed
(`build-setup.ps1` hard-depends on it and fails immediately if it is missing). It is currently committed; after changing UI text and re-running `lupdate`, remember to commit it together:

```powershell
git status --short packaging/qifw/setup-ui/translations
```

The committed/not-committed boundary is: **only text and small assets, no rebuildable binaries or artifacts**.
Therefore `packaging/qifw/toolchain/qt/`, `packaging/qifw/out/` (trash and cache),
`setup-ui/build/`, `setup-ui/dist/`, `setup-ui/out/` are all in `.gitignore`.

For more details (QIFW command-line conventions, shell single-file format, languages and translations, why not aqt, offline fallback), see
`packaging/qifw/README.md`.
