# OrbbecSlicer QIFW Packaging

Use Qt Installer Framework (QIFW) to replace the original project's NSIS + wx bootstrapper approach and produce an offline installer for OrbbecSlicer.

**All code, scripts, configuration, toolchain and artifacts in this directory live only inside this repository, `D:\Orbbec\install-qt`.** The original project `D:\Orbbec\orbbecslicer` is referenced read-only (the staging tree and `version.inc`); no script ever writes to it.

## Contents

```
packaging/qifw/
  toolchain/
    manifest.json           Pinned versions, channel URLs, archive names, sha256, tool-relative paths (committed to repo)
    _common.ps1             Shared functions: repo root resolution, path guards, manifest loading, native command invocation
    install-toolchain.ps1   Main entry point: idempotently fetch Qt + QIFW into toolchain/qt (committed to repo)
    fetch-qt-archives.ps1   Download + verify + extract Qt
    fetch-ifw.ps1           Download + verify + extract QIFW
    check-env.ps1           Environment health check, exit code 0 = usable (committed to repo)
    aqt.ini                 Fallback: aqt configuration file (see "Why Not Use aqt")
    qt/                     Actual Qt 6.8.3 and QIFW 4.11.0 (2.2 GB, gitignored)
  smoke/
    config/config.xml       Smoke installer configuration
    packages/com.orbbec.smoke/meta/package.xml + installscript.qs
    packages/com.orbbec.smoke/data/    4 small files (under payload/)
    expected-payload.json   Fixed expected manifest (paths + sha256); reports exactly which file is missing
    run-smoke.ps1           Build → silent install → verify → uninstall → verify
  product/                  Real product package (assembly logic for config.xml / package.xml / data)
  out/                      All artifacts, archive cache and logs (gitignored)
```

The toolchain root is fixed at `packaging/qifw/toolchain/qt` inside the repository (the manifest's `toolchainRoot`). After resolution the scripts verify that it lies within the repository root and abort if it escapes; absolute paths are rejected as well.

The layout matches the aqt convention:

```
toolchain/qt/6.8.3/msvc2022_64/                       Qt 6.8.3
toolchain/qt/Tools/QtInstallerFramework/4.11.0/bin/   binarycreator / installerbase / archivegen / repogen
```

## Quick Start

> **First clone, no toolchain on the machine?** Start with [`BUILD.md`](../../BUILD.md) at the repo root: environment requirements, fetching the toolchain,
> where staging comes from and common errors are all covered there; this document focuses on packaging details and conventions.

Run from the repository root `D:\Orbbec\install-qt` (Windows PowerShell 5.1):

```powershell
# 0. One-shot build (build-installer.bat at the repo root; double-click or command line)
.\build-installer.bat install                   # First run: fetch toolchain + package
.\build-installer.bat                           # Afterwards: toolchain is ready, package directly
#   .\build-installer.bat install -Force        Force re-download and re-extract the toolchain
#   .\build-installer.bat -Compression 9        Passed through to build-product.ps1
#   .\build-installer.bat -WithoutSetupUi       Deliver only the QIFW-native package
#   .\build-installer.bat -SkipInstallVerify    Skip the install/uninstall round trip
#   .\build-installer.bat help                  Argument help
#   Set NO_PAUSE=1 to disable the final press-any-key prompt (for CI)
```

```powershell
# 1. Fetch the toolchain (about 2.2 GB the first time; idempotent on reruns, completed parts are skipped)
#    Usually not needed on its own: build-installer.bat install invokes it. Use it directly only for troubleshooting or to fill in a partial install.
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\install-toolchain.ps1

# 2. Check the environment; exit code 0 means usable
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\check-env.ps1
"exit=$LASTEXITCODE"

# JSON output (for script consumption)
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\check-env.ps1 -Json

# 3. Full smoke-package round trip
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\smoke\run-smoke.ps1

# 4. Package the real product tree (--ac 5 by default; about 2 minutes, including silent-install verification)
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\product\build-product.ps1

# Smoke args / product args
#   run-smoke.ps1    -Compression 0|1|3|5|7|9   -ArchiveFormat 7z|zip|...   -SkipUninstall
#   build-product.ps1 -Compression 0|1|3|5|7|9  -ArchiveFormat 7z|zip|...  -SkipInstallVerify
#                    -StageRoot <staging>  -UpstreamRepo <original project root>  -WithoutSetupUi
```

Artifacts: under `packaging/qifw/out/product/<timestamp>/` you get:

- Deliverable `OrbbecSlicer-<version>-x64-Setup.exe` + `.sha256` (default; single file containing the UI and Qt runtime)
- Intermediate artifact `OrbbecSlicer-<version>-x64-Installer.exe` + `.sha256` (QIFW-native package)
- `result.json`, `build-product.log`, `setup-shell.log`

With `-WithoutSetupUi` the shell is not built, the deliverable falls back to the QIFW-native package, `result.json.deliverable = "qifw-native"`, and no `Setup.exe` is produced.

Prerequisites: Python 3.8+ (the script automatically runs `pip install` when `py7zr` is missing), `curl.exe` (bundled with Windows 10 1803+), PowerShell 5.1.

## Product Packaging: What Each Step Guards Against

The order in `build-product.ps1` is the order of `result.json.steps`; any failing step is recorded in `failures` and the run exits non-zero:

| Step | What it does | On failure |
| --- | --- | --- |
| 0. Toolchain verification | Calls `check-env.ps1 -Json`; Qt/QIFW versions must match what is registered in `manifest.json` | Exits 1, `failures` reports "expected x / actual y", nothing is packaged |
| 1. Resolve version | Only reads `set(SLICER_APP_VERSION "...")` from `version.inc` | Version source not found ⇒ exit 1, no default-version artifact is produced |
| 2. Snapshot (before) | Staging tree file count + per-file SHA-256 digests | — |
| 3. Copy staging | `robocopy /MIR` into `out/staging-work/<timestamp>/packages/<id>/data` | robocopy exit > 7 ⇒ exit 1 |
| 4. Package | `binarycreator --offline-only --af --ac` | Exit 1; the sub-tool output is already in the log |
| 5. Snapshot (after) and compare | Whether staging was modified | Lists changed files in `staging-changes.txt`, **deletes artifacts and .sha256**, exits 1 |
| 5b. Working-copy check | Whether `data/` still matches staging file by file (same-size byte edits are caught too) | Same as above |
| 6. SHA-256 | Generates `.sha256`, recomputes and compares; validates artifact naming | Records failure |
| 6b. Build shell | Calls `setup-ui/build-setup.ps1 -Version <ver> -Selftest` (CMake + MSVC + windeployqt + qt.conf + `--selftest`) | Exit 1, no `Setup.exe` produced |
| 6c. Assemble deliverable | `setup-ui/package-setup.ps1`: launcher + bundle.zip of `ui/`/`payload/` + trailing index (OSUI1) | Deletes `Setup.exe` and checksum files, exits 1 |
| 7–9. Install/diff/uninstall | Silent install into `out/product/<timestamp>/install`, file-by-file comparison, uninstall via `--purge` | Records failure |
| 9b–9c. Shell round trip | `Setup.exe --silent in` → file-by-file comparison → `Setup.exe --silent pr` | Invalidates `Setup.exe` and checksum files, exits 1; see `build-product.log` / `setup-shell.log` |

Only after the whole flow passes are the working copies of **other batches** in `out/staging-work/` cleaned up (about 0.5 GB each); failed batches keep their contents intact.

The failure criteria (content change / missing file / staging drift) all live in the verification stage of `product/build-product.ps1`:
the script first compares staging with the working copy, and after packaging compares the install result file by file; any mismatch exits non-zero and invalidates the artifacts.
To reproduce manually, modify files under `out/staging-work/<timestamp>/packages/<id>/data/` and rerun (this only affects the in-repo copy).

## Installer Shell (Qt Quick)

The shell source lives in `packaging/qifw/setup-ui/`; the artifact is a single-file `Setup.exe`. Building and verifying:

```powershell
# Build only the shell (dist/ = exe + Qt runtime + qml/ + qt.conf)
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\setup-ui\build-setup.ps1 -Version 0.3.0-beta.5 -Selftest

# UI screenshots (build build-shot/ and capture each view into out/ui-shots/)
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\setup-ui\tools\capture-ui.ps1

# Assemble standalone (invoked by build-product.ps1 in the build pipeline)
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\setup-ui\package-setup.ps1 `
    -LauncherExe .\packaging\qifw\setup-ui\build\OrbbecSlicerSetupLauncher.exe `
    -UiDir .\packaging\qifw\setup-ui\dist `
    -InstallerExe <Installer.exe> -Version <version>
```

Single-file layout (little-endian):

```
[OrbbecSlicerSetupLauncher.exe][bundle.zip][magic 8B "OSUI1" | offset 8B | length 8B | sha256 32B | version 4B]
bundle.zip: ui/ (shell exe + Qt runtime + qml/ + qt.conf)
          + payload/installer.exe
          + uninstaller/OrbbecSlicerUninstaller.exe (self-contained uninstaller, deployed after a successful install)
```

The launcher does not depend on Qt: it extracts the bundle to `%TEMP%\OrbbecSlicerSetup\<hash>\`, starts the UI with
`<ui>\OrbbecSlicerSetup.exe --payload <payload>\installer.exe ...`, and once the UI exits
returns its exit code and deletes the extraction directory.

Command line:

| Argument | Purpose |
| --- | --- |
| `--silent in -t <dir>` | Headless install (the exit code is the result) |
| `--silent pr [-t <dir>]` | Headless uninstall (defaults to the registry/default install directory) |
| `--payload <path>` | Development mode: use an external installer package directly (no trailing index needed) |
| `--log <path>` | Specify the install log (default `%LOCALAPPDATA%\Orbbec\OrbbecSlicerSetup\logs\setup-<ts>.log`) |
| `--selftest` | Load QML on the minimal platform and exit (0 = success) |
| `--selftest --check-options [--dir <path>]` | Directory writability/space assertions (with `--payload`, to verify button availability) |
| `--selftest --check-window` | The main window must be shown on the real platform (1175×813 @125%; must not rely only on the shotWindow used for screenshots) |
| `--selftest --check-steps` | active/done/pending assertions for the three sidebar steps |
| `--selftest --check-launch <dir>` | Verify that "Launch now" can start `<dir>\OrbbecSlicer.exe` |
| `--uninstall` | Go straight into the branded uninstall flow (used by the system uninstall entry) |
| `--install-dir <path>` | Specify the install directory to uninstall (used together with `--uninstall`) |
| `--uninstaller <path>` | Internal parameter: the launcher passes the extracted uninstaller source file to the UI, which deploys it after a successful install |
| `--with-options` | Test hook: during silent install, use the install-settings-page defaults (shortcut/.3mf/launch when done) so the round trip can verify uninstall restoration |
| `--lang <code>` | Specify the UI language (`en` / `zh_CN`; `zh` also works); by default chosen from the system locale, with unknown languages falling back to English. Also effective in silent mode |

During maintenance (repair/upgrade/downgrade) QIFW refuses to overwrite the installed directory, so the shell first renames the old program directory to
`<dir>.orbbec-backup-<pid>`, renames it back if the install fails or is cancelled, and deletes the backup on success. Uninstall data cleanup
(keep personal data / delete everything / keep the user data folder) and its wording are described in `docs/installer-copy.md`.

**Branding and finishing touches**:
- The shell, the `Setup.exe` launcher and the uninstaller all embed `resources/app.ico`; the window/taskbar, desktop/Start menu shortcuts and the Programs and Features entry use the same icon.
- On a successful install the progress bar reaches 100% and pauses for about 0.6s before switching to the completion page; on failure/cancel it pauses for about 0.3s (see `--selftest --check-finish-timing`).
- A successful uninstall deletes the desktop shortcut, Start menu shortcut, uninstall registration and uninstaller created at install time, and restores the `.3mf`/`.stl` associations from the original values recorded during install; a failed uninstall leaves all of this in place.
- Exactly one Programs and Features entry, containing fields such as `Publisher`/`EstimatedSize`/`DisplayIcon`; for per-machine installs run as administrator it prefers HKLM, otherwise it writes HKCU.

**Branded uninstall entry point**: after a successful install/repair/upgrade, the shell deploys `OrbbecSlicerUninstaller.exe` to
`%LOCALAPPDATA%\Orbbec\OrbbecSlicer\uninstaller\` and points the Windows uninstall registration's
(`HKCU\...\Uninstall\{QIFW-GUID}`) `UninstallString` / `QuietUninstallString` /
`DisplayIcon`, as well as the `Uninstall OrbbecSlicer` shortcut in the Start menu, at it. `maintenancetool.exe`
stays in the install directory for maintenance/updates, but is no longer the user-visible uninstall entry. After the uninstall finishes, the uninstaller deletes itself, the
registration and the shortcuts. Already-installed older versions switch over automatically after the next repair/upgrade/reinstall.

## Language and Translation

- **English is the source and default language**: all user-visible text is written in English in the source and wrapped with `qsTr()` (QML) or
  `tr()` (C++); diagnostic logs (`appendLog`, `--selftest` output) stay in English so troubleshooting and script matching are easier.
- **Chinese is an optional language**: the UI language is chosen in the order `--lang <code>` > system locale (`zh*` → `zh_CN`) > English.
  `--lang zh_CN` / `--lang zh` / `--lang en` all work; unsupported language codes fall back to English and log a warning.
  The language is fixed at startup (`QTranslator` is installed before the QML engine is created) and does not switch while the installer is running.
- **Translation resources ship with the package**: `translations/OrbbecSlicerSetup_zh_CN.ts` is compiled to `.qm` by `lrelease`,
  embedded into the executable as `:/i18n/OrbbecSlicerSetup_zh_CN.qm` by CMake's `qt_add_translations`,
  and delivered with `Setup.exe` / the uninstaller, with no extra files required on the target machine. `build-setup.ps1` asserts that the resource
  is embedded and prints the number of untranslated entries (missing entries fall back to English and do not block the build).
- **Fonts switch with the language**: `Microsoft YaHei` for Chinese, `Segoe UI` for English, centralized in `UiTheme.qml`'s
  `fontFamily`; individual pages do not check the language.
- **Fixed external names are not translated**: the product name `OrbbecSlicer`, the desktop shortcut `OrbbecSlicer.lnk`, the uninstall shortcut
  `Uninstall OrbbecSlicer.lnk`, the Programs and Features display name, and the `.3mf`/`.stl` association ProgIds are always English,
  so that switching languages never produces a duplicate uninstall registration or a missing shortcut.

Updating translations (after changing UI text):

```powershell
# 1. Re-extract from source, keeping existing translations and marking new/obsolete entries
packaging\qifw\toolchain\qt\6.8.3\msvc2022_64\bin\lupdate.exe `
    packaging\qifw\setup-ui\src\*.cpp packaging\qifw\setup-ui\src\*.h `
    packaging\qifw\setup-ui\*.qml packaging\qifw\setup-ui\pages\*.qml `
    -ts packaging\qifw\setup-ui\translations\OrbbecSlicerSetup_zh_CN.ts

# 2. lrelease runs automatically during a normal build; you can also verify translation completeness manually
packaging\qifw\toolchain\qt\6.8.3\msvc2022_64\bin\lrelease.exe `
    packaging\qifw\setup-ui\translations\OrbbecSlicerSetup_zh_CN.ts

# 3. Chinese UI self-test (exits non-zero if translations are not active)
.\packaging\qifw\setup-ui\dist\OrbbecSlicerSetup.exe --selftest --lang zh_CN

# 4. Chinese UI screenshots (output to out/ui-shots/<view>-zh.png)
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\setup-ui\tools\capture-ui.ps1 -Lang zh_CN
```

Adding a third language: create `<name>_<locale>.ts` under `translations/`, append it to
`qt_add_translations(... TS_FILES ...)` in `CMakeLists.txt`, and make `main.cpp`'s `resolveLanguage()`
accept that language code (currently only `zh*` and `en` are recognized).

## Smoke Package and QIFW Command-Line Conventions

`run-smoke.ps1` accepts `-Compression 0|1|3|5|7|9` (default 5), `-ArchiveFormat` (default `7z`) and `-SkipUninstall` (package and install only, for inspecting the result by hand).

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\smoke\run-smoke.ps1 -Compression 9
```

A few empirically verified conventions for QIFW 4.11 (getting them wrong either prints usage and exits 1, or silently hangs in the GUI):

| Step | Command |
| --- | --- |
| Package | `binarycreator --offline-only -c <config dir>\config.xml -p <packages dir> -t <ifw>\bin\installerbase.exe --ac <level> <artifact>` |
| Install | `SmokeInstaller.exe --platform minimal in -c --confirm-command --accept-licenses --accept-messages --cp <cache dir> -t <install dir>` |
| Uninstall | `<install dir>\maintenancetool.exe --platform minimal pr -c --confirm-command --accept-licenses --accept-messages --cp <cache dir>` |

- `-c` must point at the `config.xml` **file**; pointing it at a directory only prints usage. `-t` must explicitly specify `installerbase.exe` (even though `--offline-only` is set).
- `--ac` only accepts `0,1,3,5,7,9`; 2 or 4 are rejected.
- Headless mode relies on `--platform minimal` + `-c`; without both the installer pops up a GUI and waits for clicks.
- `binarycreator -v` does **not** echo the actual compression level, only the archive size, so the compression level is recorded together with the invocation arguments and the artifact byte size.
- In install scripts, detect Windows with `systemInfo.kernelType === "winnt"` (not `"win"`; a typo makes the `if` silently not run).
- Uninstall only deletes shortcuts registered by the component itself via `CreateShortcut`; it does not wipe the entire directory that `StartMenuDir` points to. `run-smoke.ps1` asserts the shortcut's "exists after install / gone after uninstall" separately.
- Each run writes artifacts to `out/smoke/<timestamp>/`: `SmokeInstaller.exe`, `run-smoke.log`, `result.json` (per-step durations, compression level, artifact size and SHA-256, shortcut paths, leftovers list).

### Artifacts Are Not Reproducible (Measured)

Packaging the same input repeatedly produces **different byte counts and SHA-256 every time**. A binary diff of two smoke artifacts shows differences in only three places:

| Difference | Where it appears | Cause |
| --- | --- | --- |
| Strings like `2026-10-30 - 18:54:54` | Two places in the embedded Qt resources | `binarycreator` writes the current build time |
| `rccprojectASZEBU.qrc` / `rccprojectUgbHzg.qrc` | Resource directory table | The temporary qrc file names are random |
| `CompressedSize="681"` / `"677"` | `Updates.xml` | The two items above make the embedded rcc size fluctuate |

`binarycreator` has no option to disable these behaviors. Therefore:

- **"Reproducible" refers to the toolchain** (`manifest.json` + pinned sha256), not the artifact bytes. To judge whether "the same source produces the same content", look at `staging.digestBefore` and `installVerified`/`diffCount` in `out/*/result.json` rather than comparing the exe's SHA-256.
- When releasing you must use the `.sha256` generated **for that run**; never reuse the previous one.

### Writes Outside the Repository

IFW itself uses two locations outside the repository; the scripts handle each of them separately:

- **Metadata cache**: defaults to `%LOCALAPPDATA%\cache\qt-installer-framework\<guid>\`. Every install/uninstall call passes `--cp` pointing at `out/smoke/<timestamp>/cache`, and in testing the default directory is no longer created.
- **Temporary extraction directory**: `binarycreator` creates a temp directory under `%TEMP%\binarycreator-*` at startup; there is no option to change it and it is deleted automatically on exit (no leftovers in testing). This can only be handled by accepting it, not by isolation.

## Why Not Use aqt

The original plan was to fetch with `aqtinstall`; testing (aqt 3.3.0, 2026-10-30) showed it is not viable:

- **`aqt install-qt`**: `download.qt.io` returns a 302 redirect to a CDN (`qt.mirror.constant.com`) for archives; aqt downloads package by package with a 5s timeout, and large packages such as `qtdeclarative` (148 MB) repeatedly hit read timeouts; `downloadBinaryFile` re-downloads every time without reusing already-downloaded files, and `--keep`/`--archive-dest` don't get around it. Domestic mirrors (tuna / ustc / aliyun) lack `.sha256` files, so even directory enumeration fails in aqt.
- **`aqt install-tool`**: QIFW 4.11 is published only on the `windows_x86/ifw/` channel, while aqt's target allowlist is fixed to `{desktop, winrt, android, ios, wasm, qt}`, so it cannot be reached (`desktop/tools_ifw/` only has 4.7).

So we switched to: download official archives concurrently with `curl` → check each against the **official `.sha256`** → extract with `py7zr`. Versions, archive names and sha256 are all pinned in `manifest.json`; download sources and checksums both come from the official site, making the result equivalent to aqt but with stricter verification (a failed check aborts before extraction).

`aqt.ini` is kept as a reference configuration (CDN downloads + official checksum sources); it can be used directly if aqt fixes its downloader in the future.

## Offline Fallback: When the Qt Online Repository Is Completely Unreachable

If the target machine cannot reach `download.qt.io` and the CDN, QIFW can be built from source. **Note that this is not a lightweight path**; the following is organized from the official `INSTALL` instructions (the `INSTALL` inside the source package is authoritative):

**Prerequisites (all are required):**
- Qt ≥ 6.6.0, and it must be a **static** build (`-static -static-runtime`) — the single-file installer needs static linking. The repo currently has a dynamic Qt 6.8.3, which **cannot be used directly to build QIFW**.
- MSVC 2019 or newer; the officially tested combination is Qt 6.7.2 + MSVC 2019.
- Third-party compression libraries liblzma / zlib / libbzip2 (<https://zlib.net/>, <https://www.sourceware.org/bzip2/>, <https://tukaani.org/xz/>), which must match Qt's MSVC version and runtime options (debug/release, static/dynamic CRT); point qmake at them with `IFW_ZLIB_LIBRARY`, `IFW_BZIP2_LIBRARY`, `IFW_LZMA_LIBRARY`.
- Do **not** configure static Qt with `-qt-zlib`: that makes libarchive link against Qt's bundled zlib. The Windows example configuration in INSTALL already avoids it.

**Steps:**

```powershell
$root = "D:\Orbbec\install-qt\packaging\qifw\toolchain"
$src  = "D:\Orbbec\install-qt\packaging\qifw\out\src"
New-Item -ItemType Directory -Force -Path $src, "$root\build-ifw" | Out-Null

# 1. Get the source (can also be copied from a machine with network access)
Invoke-WebRequest -Uri "https://download.qt.io/official_releases/qt-installer-framework/4.11.0/installer-framework-everywhere-src-4.11.0.zip" -OutFile "$src\ifw-src-4.11.0.zip"
Expand-Archive -Path "$src\ifw-src-4.11.0.zip" -DestinationPath $src -Force
# First open a command prompt in the VS 2022 x64 developer environment (vcvars64.bat), then run the commands below.
# After extraction the top-level directory is installer-framework-everywhere-src-dev (it does not change with the version number), containing installerfw.pro / installerfw.pri
# Self-check: confirm installerfw.pro exists in the source directory; the repo's dynamic Qt 6.8.3 ships qmake.exe, which can be used to verify that qmake works,
#       but it is not a static Qt and cannot be used for the build.

# 2. First build static Qt (arguments taken from INSTALL's recommended Windows configuration); example output: $root\qt-static
#    <Qt source dir>\configure -prefix %CD%\qtbase -release -static -static-runtime -accessibility -no-icu -no-sql-sqlite -no-qml-debug -nomake examples -nomake tests
#    cmake --build . --parallel
#    cmake --install .

# 3. Build QIFW with qmake (qmake, not CMake)
Push-Location "$root\build-ifw"
& "$root\qt-static\bin\qmake.exe" "$src\installer-framework-everywhere-src-dev\installerfw.pro" `
    IFW_ZLIB_LIBRARY=<zlib>\lib\zlibstatic.lib `
    IFW_BZIP2_LIBRARY=<bzip2>\lib\libbz2.lib `
    IFW_LZMA_LIBRARY=<xz>\lib\liblzma.lib
nmake
Pop-Location
```

The build output lands in `build-ifw\bin` and must be copied to `toolchain\qt\Tools\QtInstallerFramework\4.11.0\bin` before `check-env.ps1` will recognize it.

**Why this is only a fallback:** building and debugging static Qt plus three compression libraries costs far more than simply taking the official prebuilt binaries; libarchive-related build errors also require adjustments according to the platform headers in `src/libs/3rdparty/libarchive/config/*`. Unless there is a real no-network requirement, prefer the official archives.

> If the offline machine doesn't even have Qt: copy over all 7 Qt archives under `out/archives/` together with their `.sha256` files, plus the QIFW `.7z` and `.sha256`. `-VerifyOnly` only verifies and does not extract, so you need to run it twice in a row on the offline machine:
>
> ```powershell
> powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\fetch-qt-archives.ps1 -VerifyOnly   # Verify only; does not report missing tools when tools are not ready
> powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\install-toolchain.ps1               # Archives are already in the cache; verify and extract directly
> ```
>
> `install-toolchain.ps1` skips downloading archives that already exist, so no extra arguments are needed in an offline environment.

## Constraints

- **Do not modify the original project**: it only reads `D:\Orbbec\orbbecslicer\build\presets\windows-release\OrbbecSlicer` (the default staging, i.e. the install output of the original project's CMake preset) and `version.inc`; `-StageRoot` can point elsewhere.
- **No writes outside the repository**: the toolchain root, output directories, archive cache and temporary install directories all live inside the repository; out-of-bounds paths are rejected. The only exception is covered in "Writes Outside the Repository": IFW's `%TEMP%\binarycreator-*` (no option to change it; deleted automatically on exit).
- **The manifest is the source of truth for versions**: `check-env.ps1` verifies the tools live under `manifest.ifw.installDir` and exits non-zero if the version does not match what is registered.
- **Cleanup/rollback**: just delete `toolchain/qt/` and `out/`; every other file in the repository is small text.

## Verified Toolchain Sources

| Component | Channel | Version | Verification |
| --- | --- | --- | --- |
| Qt | `download.qt.io/online/qtsdkrepository/windows_x86/desktop/qt6_683/...` | 6.8.3 `win64_msvc2022_64` (7 archives) | All official `.sha256` checks pass |
| QIFW | `download.qt.io/online/qtsdkrepository/windows_x86/ifw/tools_ifw_411/...` | 4.11.0 win-x64 | Official `.sha256` passes (`c47201c4…`) |

## License

QIFW is LGPLv3/GPLv3 or commercially licensed. This directory is only used for local building and verification and does not involve distribution; the licensing terms must be confirmed separately before formal distribution.
