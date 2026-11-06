# 从 git clone 到构建出安装器

本文面向**只 clone 了本仓库、机器上没有任何 Qt / QIFW 工具链**的人。
按顺序做，全流程只需要「装几个常规 Windows 开发工具 + 跑几条命令」，工具链由脚本自己下载。

> 目录约定：下文用 `<repo>` 表示你的克隆目录（例如 `D:\work\install-qt`）。
> 所有命令都在 `<repo>` 里执行，用 **Windows PowerShell 5.1**（系统自带，不是 PowerShell 7）。

---

## 0. 先搞清楚：仓库里有什么、没有什么

| 内容 | 是否入库 | 说明 |
| --- | --- | --- |
| 打包脚本 `packaging/qifw/**/*.ps1`、`manifest.json` | ✅ | 工具链版本、下载地址、sha256 全部固定在这里 |
| 安装器外壳源码 `packaging/qifw/setup-ui/`（Qt Quick + C++） | ✅ | 构建出单文件 `Setup.exe` 的界面部分 |
| 一键脚本 `build-installer.bat` | ✅ | 内部先 `check-env.ps1` 再 `build-product.ps1` |
| **Qt 6.8.3 + QIFW 4.11 工具链**（解包约 2.1 GB） | ❌ gitignore | 由 `install-toolchain.ps1` 下载到仓库内 |
| `packaging/qifw/out/`（产物、归档缓存、日志） | ❌ gitignore | 每次构建生成 |
| **产品本体 OrbbecSlicer 的程序树（staging）** | ❌ 不在本仓库 | 来自 `orbbecslicer` 源码仓库的构建产物 |

所以 clone 之后**必须做两步**：① 取工具链；② 拿到 staging 树。
如果你只想验证安装器本身（外壳 / 打包链路 / 冒烟包），可以跳过 ②，见 3.3、3.4。

---

## 1. 三个必读前提

1. **必须 `git clone`，不要用网页上的 "Download ZIP"。**
   脚本靠向上查找 `.git` 来确定仓库根（`_common.ps1` 的 `Get-RepoRoot`），没有 `.git` 会直接报
   `Cannot find the repository root (.git) walking up from ...`。
2. **工具链只能落在仓库内。**
   工具根固定为 `packaging/qifw/toolchain/qt`（`manifest.json` 的 `toolchainRoot`），
   指向仓库外或绝对路径会被路径守卫拒绝。克隆到哪个盘都可以，但要预留**约 10 GB** 磁盘：
   工具链 2.1 GB + 归档缓存 0.3 GB + staging 工作副本 0.5 GB + 安装校验目录 0.5 GB + 产物。
3. **本仓库不改、不写产品仓库。**
   真实打包时只**只读** staging 树和 `version.inc`，所以 staging 路径必须由你显式指定（见 3.5）。

---

## 2. 机器要求

| 依赖 | 必需性 | 检测命令 | 说明 |
| --- | --- | --- | --- |
| Windows 10 1803+ / 11，64 位 | 必需 | `[Environment]::Is64BitOperatingSystem` | |
| Windows PowerShell 5.1 | 必需 | `$PSVersionTable.PSVersion` | 系统自带；脚本按 5.1 语法写 |
| Python 3.8+（`pip` 可用） | 必需 | `python --version` | 只用于解包 7z；缺 `py7zr` 时脚本会自动 `pip install py7zr` |
| `curl.exe` | 必需 | `curl.exe --version` | Win10 1803+ 自带 |
| VC++ 2015-2022 运行库 | 必需 | `Test-Path C:\Windows\System32\vcruntime140.dll` | 缺它时 Qt/QIFW 工具会报 `0xc000007b` |
| Visual Studio 2022 +「使用 C++ 的桌面开发」 | 构建外壳时需要 | `& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property displayName` | 提供 MSVC x64 与 Ninja |
| CMake 3.21+，**在 PATH 里** | 构建外壳时需要 | `cmake --version` | 注意：`build-setup.ps1` 是从**当前 PowerShell 的 PATH** 找 cmake，不认 VS 自带的路径 |
| 7-Zip CLI | 可选 | `7z` | `binarycreator` 自带 7z，不装也能打包 |
| Git | 必需 | `git --version` | |

装 CMake 最省事：`winget install --id Kitware.CMake -e`，装完**重开终端**确认 `cmake --version` 有输出。

> 只交付 QIFW 原生包（`-WithoutSetupUi`，即不构建 Qt 外壳）时，**VS 2022 和 CMake 都不是硬性阻塞项**：
> `check-env.ps1` 把它们算作非阻塞提示，只影响 `Setup.exe` 那一步（3.3）。

---

## 3. 五步走

> 赶时间只看这一条：**`.\build-installer.bat install`**（取工具链 + 打包一体）。下面是分步拆解，
> 用于排障、只做某一件事、或想看清每一步在把关什么。

### 3.1 取工具链：一条命令

```powershell
git clone <仓库地址> install-qt
cd install-qt
.\build-installer.bat install
```

`install` 就是「先取工具链再打包」：脚本会依次下载 Qt 6.8.3 + QIFW 4.11.0、核对官方 `.sha256`、解包、
体检、然后直接构建安装器。**不加 `install` 则只打包、不下载**（工具链已存在时用这种）。

- 下载源与校验值都来自官方：`download.qt.io` 的 Qt 6.8.3 `win64_msvc2022_64`（7 个归档）+ QIFW 4.11.0。
  每个归档先核对官方 `.sha256`，不符即中止、不解包。
- **幂等，可以随时打断再重跑**：已下载的归档在 `packaging/qifw/out/archives/` 会被跳过，
  已存在的 Qt / QIFW 目录也会跳过。要强制重下重解：`build-installer.bat install -Force`（或删掉 `packaging/qifw/toolchain/qt`）。
- 公司网络需要代理时，先设环境变量（`curl` 认这两个）：

```powershell
$env:HTTP_PROXY  = 'http://user:pass@proxy:8080'
$env:HTTPS_PROXY = 'http://user:pass@proxy:8080'
```

完成后目录形如：

```
packaging/qifw/toolchain/qt/6.8.3/msvc2022_64/                       Qt
packaging/qifw/toolchain/qt/Tools/QtInstallerFramework/4.11.0/bin/   binarycreator / installerbase / archivegen / repogen
```

> `packaging/qifw/toolchain/` 下的 4 个 ps1（`install-toolchain.ps1` / `fetch-qt-archives.ps1` /
> `fetch-ifw.ps1` / `check-env.ps1`）是 `build-installer.bat` 的内部实现，**平时不需要单独调用**；
> 只有排障或想单独补一半（`-SkipQt` / `-SkipIfw`）时才直接跑。

### 3.2 自检（退出码 0 才算可用，`build-installer.bat` 会自己跑这一步）

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\check-env.ps1
"exit=$LASTEXITCODE"
```

输出分三段：`Prerequisites`（OS / MSVC / CMake / VC 运行库 / 7-Zip）、`Path guard`、`Tools`。
`FAIL` = 阻塞项，按后面的 `->` 提示修；`WARN` = 可选，比如没装 7-Zip。
最后一行必须是 `Overall conclusion: available`。给脚本消费时用 `-Json`。

### 3.3 只构建安装器外壳（不需要产品、不需要 staging）

这是最快的「证明环境可用」路径：编译 Qt Quick 外壳、部署 Qt 运行时、跑全套自检。

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\setup-ui\build-setup.ps1 -Version 0.3.0-beta.5 -Selftest
```

脚本会依次断言：CMake 配置与编译 → 中文翻译 `lrelease` 产物与 `.qm` 已嵌入 exe → QML 模块
（QtQuick / Layouts / Controls / Controls.Basic / Dialogs）齐全 → `windeployqt` 部署 + 写 `qt.conf`
→ 三个 exe 都带品牌图标 → `--selftest` / `--check-window` / `--uninstall --check-window` / 卸载器自检 / 进度时序 / runMode。
任何一项不过就是非零退出，日志在 `packaging/qifw/setup-ui/out/`。

产物：`packaging/qifw/setup-ui/dist/`（`OrbbecSlicerSetup.exe` + Qt DLL + `qml/` + `qt.conf`，可直接双击）。

> 换 Qt 版本或部署残留时加 `-Clean`；只想看配置是否通过加 `-ConfigureOnly`。

### 3.4 只验证 QIFW 打包链路（冒烟包，不需要产品）

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\smoke\run-smoke.ps1
```

生成一个 4 文件的迷你安装包，然后静默安装 → 逐文件校验 → 卸载 → 校验残留 → 快捷方式断言。
产物与 `result.json` 在 `packaging/qifw/out/smoke/<时间戳>/`。
到这一步为止，你已经验证了「工具链 + 安装/卸载链路」全部可用。

### 3.5 真实产品打包（需要 staging 树）

#### 三个目录的关系

```
本仓库（打包器，git clone 得到）              D:\Orbbec\install-qt
├─ build-installer.bat                        入口
├─ packaging\qifw\toolchain\qt\               Qt + QIFW 实体（2.2 GB，不进 git，脚本重建）
├─ packaging\qifw\setup-ui\                   安装器外壳（Qt Quick）源码
└─ packaging\qifw\out\product\<时间戳>\       产物 Setup.exe / Installer.exe / result.json

上游产品仓库（只有被读，从不被写）             <UpstreamRepo>  = D:\Orbbec\orbbecslicer
├─ version.inc                               ← 唯一用到的文件（读 SLICER_APP_VERSION）
└─ build\presets\windows-release\OrbbecSlicer\ ← 默认 staging（cmake --target install 的产物）
   ├─ ob-slicer.exe                          程序本体
   ├─ OrbbecSlicer.dll  avcodec-62.dll  TK*.dll  ...
   ├─ resources\                             运行时资源（app_logo.ico 存在就用作安装器图标）
   ├─ lib\  include\                         运行库（也一起打进安装包）
   └─ ...                                    约 13,000 个文件 / 0.5 GB
```

打包做的事只有一件：把 **staging 目录整棵树** 逐字节复制成 `packages\com.orbbec.orbbecslicer\data`，
再压成单文件安装器。所以：

- 安装后 `C:\Program Files\OrbbecSlicer\` 里的内容 **与 staging 一一对应**（这就是「程序目录」）。
- staging 不需要是「安装过的目录」，只要是**这份目录树**就行（编译产物、别人机器上的安装目录、拷贝的副本都可以）。
- 本仓库**从不写入** staging 和上游仓库（`build-product.ps1` 会做打包前后哈希快照，被外部改动会立刻报错）。

#### 换机器 / 换目录怎么让它找对路径

`build-installer.bat` 的参数是原样转发的，路径解析顺序为
**命令行参数 > 环境变量 > 自动向上查找 > 本机默认值**：

| 输入 | 命令行 | 环境变量 | 自动查找 | 兜底默认值 |
| --- | --- | --- | --- | --- |
| staging 树 | `-StageRoot <绝对路径>` | `ORBBEC_STAGE_ROOT` | — | `<UpstreamRepo>\build\presets\windows-release\OrbbecSlicer` |
| 上游仓库（读 `version.inc`） | `-UpstreamRepo <目录>` | `ORBBEC_UPSTREAM_REPO` | 从仓库根向上 5 层找含 `version.inc` 的目录 | `D:\Orbbec\orbbecslicer` |

**自动查找**是为了「本仓库被放进上游仓库里」这种摆放。下面四种都无需任何参数：

```
D:\Orbbec\orbbecslicer\version.inc
├─ install-qt\packaging\qifw\...      整体克隆搬到上游下     -> 仓库根 = install-qt
├─ packaging\qifw\...                 只搬 packaging 目录    -> 仓库根 = packaging
└─ packaging\qifw\...                 仓库根就是 packaging   -> 同上
```

如果 `packaging` 被直接拷进 `orbbecslicer`（没有单独的 `.git`），仓库根就等于 `orbbecslicer`，
`version.inc` 就在仓库根上，同样能自动识别；此时 `packaging/qifw/out/` 的产物落在上游仓库里，
**记得在上游仓库的 `.gitignore` 里加**：

```gitignore
/packaging/qifw/out/
/packaging/qifw/toolchain/qt/
/packaging/qifw/setup-ui/build/
/packaging/qifw/setup-ui/dist/
```

另外 qifw 目录本身也做了两种布局的自适应（`<仓库根>\packaging\qifw` 与 `<仓库根>\qifw`），
`manifest.json` 里以 `packaging/qifw/` 开头的相对路径会自动改写到实际位置。

所以新机器上最省事的做法还是设两个用户环境变量（`setx` 后重开终端），之后**命令一个字都不用改**：

```powershell
setx ORBBEC_UPSTREAM_REPO "E:\src\orbbecslicer"
setx ORBBEC_STAGE_ROOT    "E:\src\orbbecslicer\build\presets\windows-release\OrbbecSlicer"
```

没有 `version.inc`（只拿了别人的 staging 副本）时，`-UpstreamRepo` 仍指向一个含 `version.inc` 的目录即可——
那个文件只提供版本号，不参与打包内容。找不到时会直接报错退出，不会拿默认版本号凑合。

`build-product.ps1` 需要两样只读输入：

| 输入 | 默认值 | 参数 |
| --- | --- | --- |
| 产品 staging 树（OrbbecSlicer 程序目录，含 `ob-slicer.exe`、`resources\` 等） | `D:\Orbbec\orbbecslicer\build\presets\windows-release\OrbbecSlicer` | `-StageRoot`（必须是**绝对路径**） |
| 版本号来源 `version.inc` 里的 `set(SLICER_APP_VERSION "...")` | `D:\Orbbec\orbbecslicer\version.inc` | `-UpstreamRepo` |

**staging 从哪来，按你手上的东西三选一：**

**A. 有 orbbecslicer 源码仓库（推荐）** — 直接构建它的 `windows-release` preset 并安装：

```powershell
cd D:\Orbbec\orbbecslicer
cmake --preset windows-release
cmake --build --preset windows-release --target install
# 产物即 staging：D:\Orbbec\orbbecslicer\build\presets\windows-release\OrbbecSlicer
```

（该项目的 `CMAKE_INSTALL_PREFIX` 默认就是 `${CMAKE_BINARY_DIR}/OrbbecSlicer`，
所以 `install` 目标产出的目录就是本仓库要的 staging 形状。源码里的 `scripts\build_package.bat`
是「构建 + NSIS 打包」的老流程，本仓库不需要 NSIS。）

**B. 只有一台机器上装好的 OrbbecSlicer** — 直接把安装目录当 staging：

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\product\build-product.ps1 `
    -StageRoot "C:\Program Files\OrbbecSlicer" `
    -UpstreamRepo "D:\path\to\orbbecslicer"     # 只需能读到 version.inc
```

**C. 从同事机器整包拷一份 staging** — 拷到本机任意位置后用 `-StageRoot` 指过去即可。
（`resources\images\app_logo.ico` 存在时安装器会带上品牌图标，不存在就用默认图标，不阻断。）

**一键打包**（读完 staging、构建外壳、合成单文件 `Setup.exe`、静默安装 + 逐文件比对 + 卸载回环）：

```powershell
.\build-installer.bat install                    # 首次：取工具链 + 打包（一条搞定）
.\build-installer.bat                            # 之后：工具链已就绪，直接打包
# 指定 staging / 版本来源
.\build-installer.bat -StageRoot "D:\stage\OrbbecSlicer" -UpstreamRepo "D:\src\orbbecslicer"
# 只交付 QIFW 原生包（跳过外壳与安装校验，最快）
.\build-installer.bat -WithoutSetupUi -SkipInstallVerify
# 更高压缩
.\build-installer.bat -Compression 9
# CI 里不暂停
set NO_PAUSE=1
# 忘记参数
.\build-installer.bat help
```

`install` 可以写在任意位置（后面的参数照样转发给 `build-product.ps1`）：
`build-installer.bat install -StageRoot "D:\stage\OrbbecSlicer" -Compression 9`。
取工具链那一步是幂等的，每次带 `install` 跑只是多做一次校验；要强制重下重解加 `-Force`。

注意 `build-installer.bat` **每次都会先跑 `check-env.ps1`**，失败就直接退出，并提示你用
`build-installer.bat install` —— 没工具链时选这个，不要自己去记 ps1 路径。

产物在 `packaging/qifw/out/product/<时间戳>/`：

- `OrbbecSlicer-<版本>-x64-Setup.exe` + `.sha256` —— 交付物（单文件，含界面与 Qt 运行时）
- `OrbbecSlicer-<版本>-x64-Installer.exe` + `.sha256` —— QIFW 原生包（中间产物）
- `result.json`（每步耗时、staging 摘要、安装/卸载校验结果）、`build-product.log`、`setup-shell.log`

> **产物字节不可复现**：`binarycreator` 会把本次构建时间和随机临时 qrc 文件名写进产物，同样的输入每次
> SHA-256 都不同。判断「同一份源码产出同样内容」看 `result.json` 的 `staging.digestBefore` 与
> `installVerified` / `diffCount`，不要比 exe 的哈希；发布时必须用**当次**生成的 `.sha256`。

---

## 4. 内网 / 完全离线机器

目标机访问不了 `download.qt.io` 及其 CDN 时，**不要试着从源码构建 QIFW**（需要静态 Qt + liblzma/zlib/bzip2，
成本远高于收益，步骤见 `packaging/qifw/README.md` 的「离线兜底」）。正确做法是搬归档：

1. 在一台能上网的机器上按 3.1 跑一遍，得到 `packaging/qifw/out/archives/` 下 8 个 `.7z`
   和各自的 `.sha256`（Qt 7 个 + QIFW 1 个，共约 270 MB）。
2. 把这 16 个文件整体拷到离线机器的同一目录 `packaging/qifw/out/archives/`。
3. 离线机器上依次执行（第一次只校验，第二次解包；归档已在缓存里就不会再下载）：

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\fetch-qt-archives.ps1 -VerifyOnly
powershell -ExecutionPolicy Bypass -File .\packaging\qifw\toolchain\install-toolchain.ps1
```

4. 离线机器如果连 PyPI 也访问不了，需要先离线装好 `py7zr`：`pip install py7zr`（或拷 wheel 到本机
   `pip install py7zr-*.whl`），否则解包那一步会失败。

---

## 5. 常见报错 → 处理

| 报错 / 现象 | 原因与处理 |
| --- | --- |
| `Cannot find the repository root (.git) walking up from ...` | 用了 ZIP 下载或不在克隆目录里运行 → `git clone`，命令在 `<repo>` 下执行 |
| `python not found (3.8+). Install it and add it to PATH.` | 装 Python 并勾选 Add to PATH，重开终端 |
| `pip install py7zr failed` | 内网无 PyPI：手动装 `py7zr` 后再跑，见第 4 节 |
| `curl.exe not found` | 系统太老或 PATH 被改；可从 `C:\Windows\System32\curl.exe` 确认 |
| `Archive verification failed, extraction aborted.` | 下载被代理/网关篡改（拿回一个 HTML 页）。删掉该 `.7z` 与其 `.sha256` 再重跑 |
| `0xc000007b` / `not a valid Win32` / 工具一启动就崩 | 缺 VC++ 运行库 → 装 Microsoft Visual C++ 2015-2022 Redistributable (x64) |
| `vswhere.exe not found` / `vswhere found no Visual Studio instance with MSVC x64 tools` | 装 VS 2022 并勾选「使用 C++ 的桌面开发」 |
| `cmake.exe not found in PATH (3.21+ required)` | 装 CMake 或把 VS 自带 CMake 加入系统 PATH；注意它检查的是**当前终端**的 PATH |
| `lrelease.exe not found in ...\bin` / `Incomplete Qt directory, missing bin\...` | Qt 解包不完整 → `build-installer.bat install -Force` 重取 |
| `Translation source not found: ...translations\OrbbecSlicerSetup_zh_CN.ts` | 克隆里缺 `translations/`（见第 6 节） |
| `Staging tree does not exist:` / `Staging tree ... must be an absolute path` | `-StageRoot` 给相对路径或指错目录 |
| `Version source not found: ...\version.inc` | `-UpstreamRepo` 指到了没有 `version.inc` 的目录 |
| `Toolchain does not match the manifest registration` | 目录里是别的 Qt/QIFW 版本 → `build-installer.bat install -Force` 重取 |
| `Environment check failed` + `Missing ... binarycreator.exe` | 还没下载工具链 → `build-installer.bat install` |
| `binarycreator` 只打印 `Usage:` 然后退出 1 | 参数写错（脚本里已固定为 `-c <config.xml 文件> -p <packages> -t <installerbase.exe> --ac <0\|1\|3\|5\|7\|9>`；`--ac` 不支持 2 和 4） |
| 静默安装后没有 `maintenancetool.exe`、`diffCount>0` | 常见于杀毒软件中途杀掉解包进程。脚本已自动清理重试一次；仍失败就把仓库目录与 `%TEMP%` 加入杀软白名单 |
| `Failed to assemble Setup.exe` / `Shell build failed` | 看 `build-product.log` 与 `setup-shell.log`；多数是外壳侧问题，可先单独跑 3.3 定位 |

---

## 6. 产物、清理与提交前检查

```powershell
# 全量清理（回到「只有源码」的状态）
Remove-Item -Recurse -Force .\packaging\qifw\toolchain\qt, .\packaging\qifw\out, `
    .\packaging\qifw\setup-ui\build, .\packaging\qifw\setup-ui\dist, .\packaging\qifw\setup-ui\out
```

脚本的写入边界：工具根、`out/`、`staging-work/`、临时安装目录全部在仓库内，越界路径会被拒绝；
唯一例外是 `binarycreator` 自己创建的 `%TEMP%\binarycreator-*`（无参数可关，退出时自动删除）。

**维护者提交前请确认**：`packaging/qifw/setup-ui/translations/OrbbecSlicerSetup_zh_CN.ts` 必须入库
（`build-setup.ps1` 硬依赖它，缺失直接 fail）。当前已入库；改动界面文案并重新 `lupdate` 之后记得一起提交：

```powershell
git status --short packaging/qifw/setup-ui/translations
```

入库/不入库的边界就是：**只放文本与小体积素材，不放可重建的二进制与产物**。
因此 `packaging/qifw/toolchain/qt/`、`packaging/qifw/out/`（trash 与缓存）、
`setup-ui/build/`、`setup-ui/dist/`、`setup-ui/out/` 都在 `.gitignore` 里。

更多细节（QIFW 命令行约定、外壳单文件格式、语言与翻译、为什么不用 aqt、离线兜底）见
`packaging/qifw/README.md`。
