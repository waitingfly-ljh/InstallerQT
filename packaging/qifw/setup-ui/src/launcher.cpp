// 单文件启动器（不依赖 Qt）。
//
// Setup.exe 布局（与 package-setup.ps1 一致）：
//   [本启动器 exe][bundle.zip][尾部索引: magic 8B "OSUI1", offset 8B, length 8B, sha256 32B, version 4B]
// bundle.zip 里是 ui/（外壳 exe + Qt 运行时 + qt.conf）与 payload/installer.exe。
//
// 启动时把 bundle 解到 %TEMP%\OrbbecSlicerSetup\<hash>\，再用 --payload 指向释放出来的
// 安装包运行 ui\OrbbecSlicerSetup.exe；等界面退出后返回它的退出码并清理释放目录。
#include <windows.h>
#include <shellapi.h>

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr char kMagic[8] = {'O', 'S', 'U', 'I', '1', 0, 0, 0};
constexpr long long kTrailerSize = 8 + 8 + 8 + 32 + 4;

std::wstring utf8ToWide(const std::string &s)
{
    if (s.empty())
        return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), int(s.size()), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), int(s.size()), &w[0], n);
    return w;
}

std::string wideToUtf8(const std::wstring &w)
{
    if (w.empty())
        return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), int(w.size()), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), int(w.size()), &s[0], n, nullptr, nullptr);
    return s;
}

void logLine(const wchar_t *fmt, ...)
{
    wchar_t buffer[2048];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf_s(buffer, _countof(buffer), _TRUNCATE, fmt, ap);
    va_end(ap);
    // WIN32 子系统没有控制台：写到 %TEMP%\OrbbecSlicerSetupLauncher.log。
    wchar_t logPath[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"TEMP", logPath, MAX_PATH);
    if (n == 0 || n >= MAX_PATH)
        return;
    wcscat_s(logPath, L"\\OrbbecSlicerSetupLauncher.log");
    FILE *f = nullptr;
    if (_wfopen_s(&f, logPath, L"a, ccs=UTF-8") == 0 && f) {
        fwprintf(f, L"%s\n", buffer);
        fclose(f);
    }
}

std::wstring exePath()
{
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(nullptr, path, MAX_PATH);
    return std::wstring(path, n);
}

bool readTrailer(const std::wstring &self, HANDLE file, long long &offset, long long &length,
                 unsigned char hash[32], std::string &version)
{
    LARGE_INTEGER size;
    if (!GetFileSizeEx(file, &size) || size.QuadPart <= kTrailerSize)
        return false;
    LARGE_INTEGER pos;
    pos.QuadPart = size.QuadPart - kTrailerSize;
    if (!SetFilePointerEx(file, pos, nullptr, FILE_BEGIN))
        return false;
    unsigned char trailer[kTrailerSize];
    DWORD read = 0;
    if (!ReadFile(file, trailer, DWORD(kTrailerSize), &read, nullptr) || read != kTrailerSize)
        return false;
    if (std::memcmp(trailer, kMagic, 8) != 0)
        return false;
    std::memcpy(&offset, trailer + 8, 8);
    std::memcpy(&length, trailer + 16, 8);
    std::memcpy(hash, trailer + 24, 32);
    version.assign(reinterpret_cast<const char *>(trailer + 56), 4);
    return offset > 0 && length > 0 && offset + length <= size.QuadPart - kTrailerSize;
}

bool runAndWait(const std::wstring &exe, const std::wstring &args, DWORD &exitCode)
{
    std::wstring cmd = L"\"" + exe + L"\" " + args;
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    std::vector<wchar_t> mutableCmd(cmd.begin(), cmd.end());
    mutableCmd.push_back(L'\0');
    // CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP：与控制台脱离，
    // 父进程所在控制台收到的 Ctrl+C/Ctrl+Break 不会把 tar 一起终止（0xC000013A）。
    if (!CreateProcessW(exe.c_str(), mutableCmd.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP, nullptr, nullptr, &si, &pi)) {
        return false;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    exitCode = code;
    return true;
}

} // namespace

int runLauncher()
{
    const std::wstring self = exePath();
    HANDLE file = CreateFileW(self.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        logLine(L"无法打开自身: %ls", self.c_str());
        return 2;
    }

    // --silent：失败时不要弹 MessageBox（打包/CI 环境没有人点）。
    bool silent = false;
    {
        int argc = 0;
        LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
        for (int i = 1; argv && i < argc; ++i) {
            if (wcscmp(argv[i], L"--silent") == 0)
                silent = true;
        }
        if (argv)
            LocalFree(argv);
    }

    long long offset = 0, length = 0;
    unsigned char hash[32] = {};
    std::string version;
    const bool packaged = readTrailer(self, file, offset, length, hash, version);
    if (!packaged) {
        CloseHandle(file);
        if (!silent)
            MessageBoxW(nullptr, L"这个程序缺少内嵌负载，无法安装。请重新下载完整的安装程序。",
                        L"OrbbecSlicer 安装程序", MB_ICONERROR | MB_OK);
        return 2;
    }

    // 释放目录：按 payload 的 SHA-256 前 16 位命名，重复运行时复用。
    wchar_t temp[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"TEMP", temp, MAX_PATH);
    std::wstring root = std::wstring(temp, n) + L"\\OrbbecSlicerSetup";
    wchar_t hex[33] = {};
    for (int i = 0; i < 8; ++i)
        swprintf_s(hex + i * 2, 3, L"%02x", hash[i]);
    std::wstring dir = root + L"\\" + hex;
    CreateDirectoryW(root.c_str(), nullptr);
    CreateDirectoryW(dir.c_str(), nullptr);

    const std::wstring uiExe = dir + L"\\ui\\OrbbecSlicerSetup.exe";
    const std::wstring payload = dir + L"\\payload\\installer.exe";
    const std::wstring embeddedUninstaller = dir + L"\\uninstaller\\OrbbecSlicerUninstaller.exe";
    const std::wstring marker = dir + L"\\bundle.ok";

    if (GetFileAttributesW(marker.c_str()) == INVALID_FILE_ATTRIBUTES) {
        const std::wstring zip = dir + L"\\bundle.zip";
        HANDLE out = CreateFileW(zip.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                                 FILE_ATTRIBUTE_NORMAL, nullptr);
        if (out == INVALID_HANDLE_VALUE) {
            CloseHandle(file);
            logLine(L"无法写出 bundle: %ls", zip.c_str());
            return 2;
        }
        LARGE_INTEGER pos;
        pos.QuadPart = offset;
        SetFilePointerEx(file, pos, nullptr, FILE_BEGIN);
        std::vector<char> buffer(1 << 20);
        long long remaining = length;
        bool ok = true;
        while (remaining > 0) {
            DWORD want = DWORD(std::min<long long>(remaining, (long long)buffer.size()));
            DWORD got = 0;
            if (!ReadFile(file, buffer.data(), want, &got, nullptr) || got == 0) {
                ok = false;
                break;
            }
            DWORD written = 0;
            if (!WriteFile(out, buffer.data(), got, &written, nullptr) || written != got) {
                ok = false;
                break;
            }
            remaining -= got;
        }
        CloseHandle(out);
        if (!ok) {
            CloseHandle(file);
            logLine(L"释放 bundle 失败");
            return 2;
        }

        // 用 Windows 自带的 tar.exe（bsdtar）解 zip：单文件交付，不需要额外运行时。
        // 用完整路径，避免调用方清空 PATH 后找不到（干净环境自检会这样做）。
        wchar_t sysRoot[MAX_PATH];
        DWORD sysLen = GetEnvironmentVariableW(L"SystemRoot", sysRoot, MAX_PATH);
        std::wstring tarExe = (sysLen > 0 && sysLen < MAX_PATH)
                                  ? std::wstring(sysRoot, sysLen) + L"\\System32\\tar.exe"
                                  : L"tar.exe";
        std::wstring tarArgs = L"-xf \"" + zip + L"\" -C \"" + dir + L"\"";
        DWORD tarCode = 1;
        if (!runAndWait(tarExe, tarArgs, tarCode) || tarCode != 0) {
            CloseHandle(file);
            logLine(L"tar 解压失败: %lu", tarCode);
            if (!silent)
                MessageBoxW(nullptr, L"安装程序解压失败，请查看 %TEMP%\\OrbbecSlicerSetupLauncher.log。",
                            L"OrbbecSlicer 安装程序", MB_ICONERROR | MB_OK);
            return 2;
        }
        DeleteFileW(zip.c_str());
        HANDLE m = CreateFileW(marker.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                               FILE_ATTRIBUTE_NORMAL, nullptr);
        if (m != INVALID_HANDLE_VALUE)
            CloseHandle(m);
    }
    CloseHandle(file);

    const bool hasPayload = GetFileAttributesW(payload.c_str()) != INVALID_FILE_ATTRIBUTES;
    // 卸载器 bundle 只有 ui/，没有 payload：以"卸载器模式"运行。
    const bool uninstallerMode = !hasPayload;
    if (GetFileAttributesW(uiExe.c_str()) == INVALID_FILE_ATTRIBUTES) {
        logLine(L"释放结果不完整: ui=%ls", uiExe.c_str());
        if (!silent)
            MessageBoxW(nullptr, L"安装程序解压后缺少文件，请重新下载。", L"OrbbecSlicer 安装程序",
                        MB_ICONERROR | MB_OK);
        return 2;
    }

    // 把原始参数接在 --payload / --uninstaller 之后（UI 侧解析这些参数与 --silent / --log / --selftest）。
    std::wstring args;
    if (hasPayload)
        args += L"--payload \"" + payload + L"\"";
    if (GetFileAttributesW(embeddedUninstaller.c_str()) != INVALID_FILE_ATTRIBUTES)
        args += L" --uninstaller \"" + embeddedUninstaller + L"\"";
    if (uninstallerMode)
        args += L" --uninstall";
    int argc = 0;
    bool hasSelftest = false;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    for (int i = 1; i < argc; ++i) {
        if (wcscmp(argv[i], L"--selftest") == 0)
            hasSelftest = true;
        args += L" \"";
        args += argv[i];
        args += L"\"";
    }
    if (argv)
        LocalFree(argv);

    DWORD exitCode = 1;
    if (!runAndWait(uiExe, args, exitCode)) {
        logLine(L"无法启动界面: %ls", uiExe.c_str());
        if (!silent)
            MessageBoxW(nullptr, L"无法启动安装界面，请查看 %TEMP%\\OrbbecSlicerSetupLauncher.log。",
                        L"OrbbecSlicer 安装程序", MB_ICONERROR | MB_OK);
        return 2;
    }

    // 结束后清理释放目录（文件被占用时删除会失败，留待系统清理）。
    wchar_t sysRoot2[MAX_PATH];
    DWORD sysLen2 = GetEnvironmentVariableW(L"SystemRoot", sysRoot2, MAX_PATH);
    std::wstring cmdExe = (sysLen2 > 0 && sysLen2 < MAX_PATH)
                              ? std::wstring(sysRoot2, sysLen2) + L"\\System32\\cmd.exe"
                              : L"cmd.exe";

    auto runHidden = [&cmdExe](const std::wstring &commandLine, bool waitMs) {
        STARTUPINFOW si{};
        si.cb = sizeof(si);
        PROCESS_INFORMATION pi{};
        std::vector<wchar_t> cmd(commandLine.begin(), commandLine.end());
        cmd.push_back(L'\0');
        if (!CreateProcessW(cmdExe.c_str(), cmd.data(), nullptr, nullptr, FALSE,
                            CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP, nullptr, nullptr, &si, &pi))
            return;
        if (waitMs)
            WaitForSingleObject(pi.hProcess, 5000);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    };

    runHidden(L"/c rmdir /s /q \"" + dir + L"\"", true);

    if (uninstallerMode && !hasSelftest) {
        // 只有部署在 ...\uninstaller\ 下的卸载器才自删除；构建目录 / selftest 不删。
        const std::wstring selfDir = self.substr(0, self.find_last_of(L"\\"));
        const std::wstring selfDirName = selfDir.substr(selfDir.find_last_of(L"\\") + 1);
        if (_wcsicmp(selfDirName.c_str(), L"uninstaller") == 0)
            runHidden(L"/c timeout /t 2 /nobreak >nul & rmdir /s /q \"" + selfDir + L"\"", false);
    }
    return int(exitCode);
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int)
{
    return runLauncher();
}
