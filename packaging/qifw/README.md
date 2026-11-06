# OrbbecSlicer QIFW 打包

用 Qt Installer Framework（QIFW）替代原项目的 NSIS + wx 引导方案，生成 OrbbecSlicer 的离线安装程序。

**本目录的一切代码、脚本、配置、工具链与产物都只放在本仓库 `D:\Orbbec\install-qt` 内。** 原项目 `D:\Orbbec\orbbecslicer` 只作只读引用（staging 树、`version.inc`），任何脚本都不会写入它。

## 目录

```
packaging/qifw/
  toolchain/
    manifest.json           固定版本、渠道 URL、归档名、sha256、工具相对路径（入库）
    _common.ps1             公共函数：仓库根解析、路径守卫、manifest 加载、原生命令调用
    install-toolchain.ps1   总入口：幂等获取 Qt + QIFW 到 toolchain/qt（入库）
    fetch-qt-archives.ps1   下载 + 校验 + 解包 Qt
    fetch-ifw.ps1           下载 + 校验 + 解包 QIFW
    check-env.ps1           环境健康检查，退出码 0 = 可用（入库）
    aqt.ini                 备用：aqt 的配置文件（见"为什么不用 aqt"）
    qt/                     Qt 6.8.3 与 QIFW 4.11.0 实体（2.2 GB，已 gitignore）
  smoke/
    config/config.xml       冒烟安装器配置
    packages/com.orbbec.smoke/meta/package.xml + installscript.qs
    packages/com.orbbec.smoke/data/    4 个小文件（payload/ 下）
    expected-payload.json   固定预期清单（路径 + sha256），缺文件时能报出是哪个
    run-smoke.ps1           生成 → 静默安装 → 校验 → 卸载 → 校验
  product/                  真实产品包（config.xml / package.xml / data 的装配逻辑）
  out/                      所有产物、归档缓存与日志（已 gitignore）
```

工具根固定为仓库内 `packaging/qifw/toolchain/qt`（manifest 的 `toolchainRoot`）。脚本解析后会校验其落在仓库根内，越界即中止；绝对路径同样会被拒绝。

布局与 aqt 约定一致：

```
toolchain/qt/6.8.3/msvc2022_64/                       Qt 6.8.3
toolchain/qt/Tools/QtInstallerFramework/4.11.0/bin/   binarycreator / installerbase / archivegen / repogen
```

## 快速开始

> **第一次 clone、机器上没有工具链？** 先看仓库根的 [`BUILD.md`](../../BUILD.md)：环境要求、取工具链、
> staging 从哪来、常见报错都在那里；本文侧重打包细节与约定。

从仓库根 `D:\Orbbec\install-qt` 执行（Windows PowerShell 5.1）：

```powershell
# 0. 一键构建（仓库根有 build-installer.bat；双击或命令行均可）
.\build-installer.bat install                   # 首次：取工具链 + 打包
.\build-installer.bat                           # 之后：工具链已就绪，直接打包
#   .\build-installer.bat install -Force        强制重下重解工具链
#   .\build-installer.bat -Compression 9        传给 build-product.ps1
#   .\build-installer.bat -WithoutSetupUi       只交付 QIFW 原生包
#   .\build-installer.bat -SkipInstallVerify    跳过安装/卸载回路
#   .\build-installer.bat help                  参数帮助
#   设 NO_PAUSE=1 可禁用结束时的按任意键（CI 用）
```

```powershell
# 1. 获取工具链（首次约 2.2 GB；重复执行幂等，已完成的部分会跳过）
#    通常不需要单独跑：build-installer.bat install 会调用它。只有排障或只补一半时才直接用。
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\install-toolchain.ps1

# 2. 检查环境，退出码 0 表示可用
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\check-env.ps1
"exit=$LASTEXITCODE"

# JSON 输出（供脚本消费）
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\check-env.ps1 -Json

# 3. 冒烟包全回路
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\smoke\run-smoke.ps1

# 4. 真实产品树打包（默认 --ac 5；约 2 分钟，含静默安装校验）
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\product\build-product.ps1

# 冒烟参数 / 产品参数
#   run-smoke.ps1    -Compression 0|1|3|5|7|9   -ArchiveFormat 7z|zip|...   -SkipUninstall
#   build-product.ps1 -Compression 0|1|3|5|7|9  -ArchiveFormat 7z|zip|...  -SkipInstallVerify
#                    -StageRoot <staging>  -UpstreamRepo <原项目根>  -WithoutSetupUi
```

产物：`packaging/qifw/out/product/<时间戳>/` 下有：

- 交付物 `OrbbecSlicer-<版本>-x64-Setup.exe` + `.sha256`（默认；单文件，含界面与 Qt 运行时）
- 中间产物 `OrbbecSlicer-<版本>-x64-Installer.exe` + `.sha256`（QIFW 原生包）
- `result.json`、`build-product.log`、`setup-shell.log`

`-WithoutSetupUi` 时不构建外壳，交付物回退为 QIFW 原生包，`result.json.deliverable = "qifw-native"`，不产出 `Setup.exe`。

前置依赖：Python 3.8+（`py7zr` 缺失时脚本会自动 `pip install`）、`curl.exe`（Windows 10 1803+ 自带）、PowerShell 5.1。

## 产品打包：每一步在把关什么

`build-product.ps1` 的顺序即 `result.json.steps` 的顺序，任一步失败都会写入 `failures` 并以非零退出：

| 步骤 | 内容 | 失败时 |
| --- | --- | --- |
| 0. 工具链核对 | 调 `check-env.ps1 -Json`，Qt/QIFW 版本必须与 `manifest.json` 登记一致 | 退出 1，`failures` 给出"期望 x / 实际 y"，不打包 |
| 1. 解析版本 | 只读 `version.inc` 的 `set(SLICER_APP_VERSION "...")` | 找不到版本来源 ⇒ 退出 1，不生成默认版本产物 |
| 2. 快照（前） | staging 树 文件数 + 逐文件 SHA-256 摘要 | — |
| 3. 复制 staging | `robocopy /MIR` 到 `out/staging-work/<时间戳>/packages/<id>/data` | robocopy exit > 7 ⇒ 退出 1 |
| 4. 打包 | `binarycreator --offline-only --af --ac` | 退出 1，子工具输出已在日志里 |
| 5. 快照（后）并比对 | staging 是否被改动 | 列出改动的文件到 `staging-changes.txt`，**删除产物与 .sha256**，退出 1 |
| 5b. 工作副本核对 | `data/` 是否仍与 staging 逐文件一致（同尺寸改字节也能发现） | 同上 |
| 6. SHA-256 | 生成 `.sha256` 并重算比对；产物命名校验 | 记录失败 |
| 6b. 构建外壳 | 调 `setup-ui/build-setup.ps1 -Version <ver> -Selftest`（CMake + MSVC + windeployqt + qt.conf + `--selftest`） | 退出 1，不产出 `Setup.exe` |
| 6c. 合成交付物 | `setup-ui/package-setup.ps1`：启动器 + `ui/`/`payload/` 的 bundle.zip + 尾部索引（OSUI1） | 删 `Setup.exe` 与校验文件，退出 1 |
| 7–9. 安装/差异/卸载 | 静默安装到 `out/product/<时间戳>/install`，逐文件比对，`--purge` 卸载 | 记录失败 |
| 9b–9c. 外壳回路 | `Setup.exe --silent in` → 逐文件比对 → `Setup.exe --silent pr` | 作废 `Setup.exe` 与校验文件，退出 1，日志见 `build-product.log` / `setup-shell.log` |

只有整个流程通过后，才会清掉 `out/staging-work/` 里**其它批次**的工作副本（每份约 0.5 GB）；失败批次保留现场。

失败路径的判据（内容变化 / 文件缺失 / staging 变动）都写在 `product/build-product.ps1` 的校验环节里：
脚本先比对 staging 与工作副本，打包后再逐个比对安装结果；任何不一致都会以非零退出并作废产物。
要手动复现，改 `out/staging-work/<时间戳>/packages/<id>/data/` 下的文件再重跑即可（只影响仓库内副本）。

## 安装器外壳（Qt Quick）

外壳源码在 `packaging/qifw/setup-ui/`，产物是单文件 `Setup.exe`。构建与验证：

```powershell
# 只构建外壳（dist/ = exe + Qt 运行时 + qml/ + qt.conf）
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\setup-ui\build-setup.ps1 -Version 0.3.0-beta.5 -Selftest

# 界面截图（构建 build-shot/ 并逐视图抓图到 out/ui-shots/）
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\setup-ui\tools\capture-ui.ps1

# 单独合成（构建流水线里由 build-product.ps1 调用）
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\setup-ui\package-setup.ps1 `
    -LauncherExe .\packaging\qifw\setup-ui\build\OrbbecSlicerSetupLauncher.exe `
    -UiDir .\packaging\qifw\setup-ui\dist `
    -InstallerExe <Installer.exe> -Version <版本>
```

单文件布局（小端）：

```
[OrbbecSlicerSetupLauncher.exe][bundle.zip][magic 8B "OSUI1" | offset 8B | length 8B | sha256 32B | version 4B]
bundle.zip: ui/（外壳 exe + Qt 运行时 + qml/ + qt.conf）
          + payload/installer.exe
          + uninstaller/OrbbecSlicerUninstaller.exe（自包含卸载器，安装成功后部署）
```

启动器不依赖 Qt：把 bundle 解到 `%TEMP%\OrbbecSlicerSetup\<hash>\`，用
`<ui>\OrbbecSlicerSetup.exe --payload <payload>\installer.exe ...` 启动界面，等界面退出后
返回它的退出码并删除释放目录。

命令行：

| 参数 | 作用 |
| --- | --- |
| `--silent in -t <dir>` | 无界面安装（退出码即结果） |
| `--silent pr [-t <dir>]` | 无界面卸载（缺省用注册表/默认安装目录） |
| `--payload <path>` | 开发模式：直接用外部安装包（不需要尾部索引） |
| `--log <path>` | 指定安装日志（默认 `%LOCALAPPDATA%\Orbbec\OrbbecSlicerSetup\logs\setup-<ts>.log`） |
| `--selftest` | 最小平台加载 QML 后退出（0 = 成功） |
| `--selftest --check-options [--dir <路径>]` | 目录可写/空间断言（配合 `--payload` 验证按钮可用性） |
| `--selftest --check-window` | 真实平台下主窗口必须显示（1175×813 @125%，不能只靠截图用的 shotWindow） |
| `--selftest --check-steps` | 侧栏三步的 active/done/pending 断言 |
| `--selftest --check-launch <目录>` | 验证"立即启动"能拉起 `<目录>\OrbbecSlicer.exe` |
| `--uninstall` | 直接进入品牌化卸载流程（系统卸载入口使用） |
| `--install-dir <路径>` | 指定要卸载的安装目录（与 `--uninstall` 连用） |
| `--uninstaller <路径>` | 内部参数：启动器把解压出来的卸载器源文件传给界面，安装成功后部署 |
| `--with-options` | 测试钩子：静默安装时使用安装设置页默认选项（快捷方式/.3mf/完成后启动），供回路验证卸载还原 |
| `--lang <code>` | 指定界面语言（`en` / `zh_CN`，也可写 `zh`）；缺省按系统区域选择，未知语言回退英文。静默模式下同样有效 |

维护（修复/升级/降级）时 QIFW 拒绝覆盖已安装目录，外壳会先把旧程序目录改名为
`<dir>.orbbec-backup-<pid>`，安装失败/取消时改回，成功后删除备份。卸载的数据清理
（保留个人数据 / 删除全部 / 保留用户数据文件夹）与文案见 `docs/installer-copy.md`。

**品牌与收尾**：
- 外壳、`Setup.exe` 启动器、卸载器都嵌入了 `resources/app.ico`；窗口/任务栏、桌面/开始菜单快捷方式与程序与功能条目使用同一图标。
- 安装成功时进度条先到 100% 并停留约 0.6s 再切完成页；失败/取消停留约 0.3s（见 `--selftest --check-finish-timing`）。
- 卸载成功会删除安装时创建的桌面快捷方式、开始菜单快捷方式、卸载登记与卸载器，并用安装时记录的原值还原 `.3mf`/`.stl` 关联；卸载失败不清理这些现场。
- 程序与功能条目恰好一条，包含 `Publisher`/`EstimatedSize`/`DisplayIcon` 等字段；per-machine 安装且以管理员运行优先写 HKLM，否则写 HKCU。

**品牌化卸载入口**：安装/修复/升级成功后，外壳会把 `OrbbecSlicerUninstaller.exe` 部署到
`%LOCALAPPDATA%\Orbbec\OrbbecSlicer\uninstaller\`，并把 Windows 卸载登记
（`HKCU\...\Uninstall\{QIFW-GUID}`）的 `UninstallString` / `QuietUninstallString` /
`DisplayIcon` 与开始菜单里的 `Uninstall OrbbecSlicer` 快捷方式都指向它。`maintenancetool.exe`
仍留在安装目录里做维护/更新，但不再是用户可见的卸载入口。卸载完成后卸载器会删除自己、
登记与快捷方式。已安装的旧版本会在下一次修复/升级/重装后自动切换。

## 语言与翻译

- **英文是源语言与默认语言**：所有用户可见文案在源码里写成英文，并用 `qsTr()`（QML）或
  `tr()`（C++）包裹；诊断日志（`appendLog`、`--selftest` 输出）保持英文，便于排障与脚本匹配。
- **中文是可选语言**：界面语言按 `--lang <code>` > 系统区域（`zh*` → `zh_CN`）> 英文 的顺序选择。
  `--lang zh_CN` / `--lang zh` / `--lang en` 都可用；不支持的语言代码回退英文并在日志中记录一条警告。
  语言在启动时确定（创建 QML 引擎之前安装 `QTranslator`），安装器运行期间不切换。
- **翻译资源随包交付**：`translations/OrbbecSlicerSetup_zh_CN.ts` 经 `lrelease` 编译为 `.qm`，
  由 CMake 的 `qt_add_translations` 嵌入可执行文件的 `:/i18n/OrbbecSlicerSetup_zh_CN.qm`，
  随 `Setup.exe` / 卸载器一起交付，不依赖目标机上的额外文件。`build-setup.ps1` 会断言该资源
  已嵌入，并输出未翻译条目数（缺失条目回退英文，不阻断构建）。
- **字体随语言切换**：中文用 `Microsoft YaHei`，英文用 `Segoe UI`，集中在 `UiTheme.qml` 的
  `fontFamily`，各页面不单独判断语言。
- **外部固定名称不翻译**：产品名 `OrbbecSlicer`、桌面快捷方式 `OrbbecSlicer.lnk`、卸载快捷方式
  `Uninstall OrbbecSlicer.lnk`、程序与功能显示名、`.3mf`/`.stl` 关联 ProgId 始终为英文，
  避免切换语言后出现重复的卸载登记或找不到快捷方式。

更新翻译（改了界面文案后）：

```powershell
# 1. 从源码重新提取，保留已有翻译并标记新增/过时条目
packaging\qifw\toolchain\qt\6.8.3\msvc2022_64\bin\lupdate.exe `
    packaging\qifw\setup-ui\src\*.cpp packaging\qifw\setup-ui\src\*.h `
    packaging\qifw\setup-ui\*.qml packaging\qifw\setup-ui\pages\*.qml `
    -ts packaging\qifw\setup-ui\translations\OrbbecSlicerSetup_zh_CN.ts

# 2. 正常构建时 lrelease 自动执行；也可手工校验翻译是否完整
packaging\qifw\toolchain\qt\6.8.3\msvc2022_64\bin\lrelease.exe `
    packaging\qifw\setup-ui\translations\OrbbecSlicerSetup_zh_CN.ts

# 3. 中文界面自检（翻译未生效时以非零退出）
.\packaging\qifw\setup-ui\dist\OrbbecSlicerSetup.exe --selftest --lang zh_CN

# 4. 中文界面截图（输出 out/ui-shots/<view>-zh.png）
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\setup-ui\tools\capture-ui.ps1 -Lang zh_CN
```

新增第三种语言：在 `translations/` 下新建 `<name>_<locale>.ts`，在 `CMakeLists.txt` 的
`qt_add_translations(... TS_FILES ...)` 中追加该文件，并让 `main.cpp` 的 `resolveLanguage()`
接受该语言代码（当前只识别 `zh*` 与 `en`）。

## 冒烟包与 QIFW 命令行约定

`run-smoke.ps1` 可带 `-Compression 0|1|3|5|7|9`（默认 5）、`-ArchiveFormat`（默认 `7z`）与 `-SkipUninstall`（只打包和安装，方便手工看结果）。

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\smoke\run-smoke.ps1 -Compression 9
```

QIFW 4.11 的几条实测约定（写错会直接打印用法并退出 1，或静默卡在 GUI）：

| 步骤 | 命令 |
| --- | --- |
| 打包 | `binarycreator --offline-only -c <config 目录>\config.xml -p <packages 目录> -t <ifw>\bin\installerbase.exe --ac <级别> <产物>` |
| 安装 | `SmokeInstaller.exe --platform minimal in -c --confirm-command --accept-licenses --accept-messages --cp <缓存目录> -t <安装目录>` |
| 卸载 | `<安装目录>\maintenancetool.exe --platform minimal pr -c --confirm-command --accept-licenses --accept-messages --cp <缓存目录>` |

- `-c` 必须指向 `config.xml` **文件**，指向目录只会打印用法；`-t` 必须显式给出 `installerbase.exe`（虽然设了 `--offline-only`）。
- `--ac` 只接受 `0,1,3,5,7,9`，写 2 或 4 会被拒绝。
- 无头模式靠 `--platform minimal` + `-c`；不加这两个时安装器会弹 GUI 等人点。
- `binarycreator -v` **不回显**实际压缩级别，只回显归档大小，所以压缩级别以调用参数 + 产物字节数一起记录。
- 安装脚本里判断 Windows 用 `systemInfo.kernelType === "winnt"`（不是 `"win"`，写错会让 `if` 静默不进入）。
- 卸载只会删掉组件自己用 `CreateShortcut` 登记的快捷方式，不会清空 `StartMenuDir` 指向的整个目录。`run-smoke.ps1` 对快捷方式的"安装后存在 / 卸载后消失"各做一次断言。
- 每次运行产物写 `out/smoke/<时间戳>/`：`SmokeInstaller.exe`、`run-smoke.log`、`result.json`（各步耗时、压缩级别、产物大小与 SHA-256、快捷方式路径、残留清单）。

### 产物不可复现（实测）

同样的输入连续打包，产物字节数与 SHA-256 **每次都会不同**。用两次 smoke 产物做二进制比对，差异只在三处：

| 差异 | 出现位置 | 原因 |
| --- | --- | --- |
| `2026-10-30 - 18:54:54` 这类字符串 | 嵌入的 Qt 资源里两处 | `binarycreator` 写入本次构建时间 |
| `rccprojectASZEBU.qrc` / `rccprojectUgbHzg.qrc` | 资源目录表 | 临时 qrc 文件名是随机的 |
| `CompressedSize="681"` / `"677"` | `Updates.xml` | 上面两项让内嵌 rcc 大小浮动 |

`binarycreator` 没有关闭这些行为的参数。因此：

- **“可重复”指的是工具链**（`manifest.json` + 固定 sha256），不是产物字节。要判断"同一份源码产出同样内容"，看 `out/*/result.json` 里的 `staging.digestBefore` 与 `installVerified`/`diffCount`，而不是比较 exe 的 SHA-256。
- 发布时必须用**当次**生成的 `.sha256`，不能沿用上次的。

### 仓库外的写入

IFW 自身会用到两个仓库外的位置，脚本对它们分别处理：

- **元数据缓存**：默认 `%LOCALAPPDATA%\cache\qt-installer-framework\<guid>\`。所有安装/卸载调用都传 `--cp` 指到 `out/smoke/<时间戳>/cache`，实测该目录不再被创建。
- **临时解包目录**：`binarycreator` 在启动时于 `%TEMP%\binarycreator-*` 创建临时目录，无参数可改，退出时自动删除（实测无残留）。这一点只能靠"可接受"而非隔离来解决。

## 为什么不用 aqt

原计划用 `aqtinstall` 获取，实测（aqt 3.3.0，2026-10-30）不可行：

- **`aqt install-qt`**：`download.qt.io` 对归档返回 302 跳转到 CDN（`qt.mirror.constant.com`），aqt 以 5s 超时逐包下载，`qtdeclarative`(148 MB) 等大包反复 read timeout；`downloadBinaryFile` 每次都重新下载，不复用已下载文件，`--keep`/`--archive-dest` 也绕不开。国内镜像（tuna / ustc / aliyun）缺 `.sha256` 文件，aqt 连目录枚举都会失败。
- **`aqt install-tool`**：QIFW 4.11 只在 `windows_x86/ifw/` channel 发布，而 aqt 的 target 白名单固定为 `{desktop, winrt, android, ios, wasm, qt}`，无法访问（`desktop/tools_ifw/` 下只有 4.7）。

因此改为：`curl` 并发下载官方归档 → 逐个核对**官方 `.sha256`** → `py7zr` 解包。版本、归档名、sha256 全部固化在 `manifest.json`，下载源与校验值都来自官方站点，结果与 aqt 等价，且校验更严格（校验不通过即中止，不解包）。

`aqt.ini` 保留作为参考配置（CDN 下载 + 官方校验源），若将来 aqt 修复了下载器可直接使用。

## 离线兜底：完全断开 Qt 在线仓库时

目标机器访问不了 `download.qt.io` 与 CDN 时，可从源码构建 QIFW。**注意这不是一条轻量路径**，以下按官方 `INSTALL` 说明整理（源码包内 `INSTALL` 是权威依据）：

**前提（缺一不可）：**
- Qt ≥ 6.6.0，且必须是 **静态** 构建（`-static -static-runtime`）——单文件安装器需要静态链接。本仓库现有的是动态 Qt 6.8.3，**不能直接用来构建 QIFW**。
- MSVC 2019 或更新；官方测试组合为 Qt 6.7.2 + MSVC 2019。
- 第三方压缩库 liblzma / zlib / libbzip2（<https://zlib.net/>、<https://www.sourceware.org/bzip2/>、<https://tukaani.org/xz/>），需与 Qt 相同的 MSVC 版本和运行时选项（debug/release、静态/动态 CRT）一致；用 `IFW_ZLIB_LIBRARY`、`IFW_BZIP2_LIBRARY`、`IFW_LZMA_LIBRARY` 指给 qmake。
- 静态 Qt **不要**配置 `-qt-zlib`：那样 libarchive 会链接 Qt 自带的 zlib。INSTALL 里 Windows 的示例配置本身就避开了它。

**步骤：**

```powershell
$root = "D:\Orbbec\install-qt\packaging\qifw\toolchain"
$src  = "D:\Orbbec\install-qt\packaging\qifw\out\src"
New-Item -ItemType Directory -Force -Path $src, "$root\build-ifw" | Out-Null

# 1. 取源码（也可从已联网机器拷贝）
Invoke-WebRequest -Uri "https://download.qt.io/official_releases/qt-installer-framework/4.11.0/installer-framework-everywhere-src-4.11.0.zip" -OutFile "$src\ifw-src-4.11.0.zip"
Expand-Archive -Path "$src\ifw-src-4.11.0.zip" -DestinationPath $src -Force
# 先在 VS 2022 x64 开发者环境里打开命令行（vcvars64.bat），再执行以下命令。
# 解压后顶层目录名为 installer-framework-everywhere-src-dev（不随版本号变化），内含 installerfw.pro / installerfw.pri
# 自检：确认源码目录里有 installerfw.pro；仓库里的动态 Qt 6.8.3 自带 qmake.exe，可用来验证 qmake 可用，
#       但它不是静态 Qt，不能用于构建。

# 2. 先构建静态 Qt（参数取自 INSTALL 的 Windows 推荐配置），产物示例：$root\qt-static
#    <Qt 源码目录>\configure -prefix %CD%\qtbase -release -static -static-runtime -accessibility -no-icu -no-sql-sqlite -no-qml-debug -nomake examples -nomake tests
#    cmake --build . --parallel
#    cmake --install .

# 3. 用 qmake 构建 QIFW（是 qmake，不是 CMake）
Push-Location "$root\build-ifw"
& "$root\qt-static\bin\qmake.exe" "$src\installer-framework-everywhere-src-dev\installerfw.pro" `
    IFW_ZLIB_LIBRARY=<zlib>\lib\zlibstatic.lib `
    IFW_BZIP2_LIBRARY=<bzip2>\lib\libbz2.lib `
    IFW_LZMA_LIBRARY=<xz>\lib\liblzma.lib
nmake
Pop-Location
```

构建产物落在 `build-ifw\bin`，需拷贝到 `toolchain\qt\Tools\QtInstallerFramework\4.11.0\bin` 后 `check-env.ps1` 才会识别。

**为什么它只是兜底：** 静态 Qt + 三个压缩库的构建与排错成本远高于直接取官方预编译二进制；libarchive 相关编译错误还需要按 `src/libs/3rdparty/libarchive/config/*` 的平台头文件调整。除非确有无网需求，否则优先用官方归档。

> 若离线机器上连 Qt 也没有：把 `out/archives/` 下 7 个 Qt 归档与其 `.sha256`、以及 QIFW 的 `.7z` 与 `.sha256` 整体拷贝过去。`-VerifyOnly` 只核验、不解包，所以在离线机器上要连跑两次：
>
> ```powershell
> powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\fetch-qt-archives.ps1 -VerifyOnly   # 只校验，tools 未就绪时不报缺工具
> powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\install-toolchain.ps1               # 归档已在缓存中，直接校验并解包
> ```
>
> `install-toolchain.ps1` 遇到已存在的归档会跳过下载，离线环境下无需额外参数。

## 约束

- **不改原项目**：只读 `D:\Orbbec\orbbecslicer\build\presets\windows-release\OrbbecSlicer`（默认 staging，即原项目 CMake preset 的安装产物）与 `version.inc`；用 `-StageRoot` 可指向别处。
- **不写仓库外**：工具根、输出目录、归档缓存、临时安装目录都在仓库内；越界路径会被拒绝。唯一例外见「仓库外的写入」：IFW 的 `%TEMP%\binarycreator-*`（无参数可改，退出时自动删除）。
- **版本以 manifest 为准**：`check-env.ps1` 校验工具位于 `manifest.ifw.installDir` 之下，与登记的版本不一致即非零退出。
- **清理/回滚**：删除 `toolchain/qt/` 与 `out/` 即可；仓库内其余文件均为小文本。

## 已验证的工具链来源

| 组件 | 渠道 | 版本 | 校验 |
| --- | --- | --- | --- |
| Qt | `download.qt.io/online/qtsdkrepository/windows_x86/desktop/qt6_683/...` | 6.8.3 `win64_msvc2022_64`（7 个归档） | 官方 `.sha256` 全部通过 |
| QIFW | `download.qt.io/online/qtsdkrepository/windows_x86/ifw/tools_ifw_411/...` | 4.11.0 win-x64 | 官方 `.sha256` 通过（`c47201c4…`） |

## 许可

QIFW 为 LGPLv3/GPLv3 或商业授权。本目录只在本地构建与验证，不涉及分发；正式分发前需单独确认授权口径。
