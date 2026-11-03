#include "msopen.h"

#ifdef Q_OS_WIN
#  ifndef NOMINMAX
#    define NOMINMAX
#  endif
#  include <windows.h>
#  include <aclapi.h>
#  include <sddl.h>

#  include <QDir>
#  include <QFileInfo>
#  include <QVector>
#endif

namespace MSOpen {

QString accessName(Access a)
{
    switch (a) {
    case Access::Writable: return QStringLiteral("可写");
    case Access::ReadOnly: return QStringLiteral("只读");
    case Access::Missing:  return QStringLiteral("不存在");
    case Access::Unknown:  break;
    }
    return QStringLiteral("未知");
}

#ifdef Q_OS_WIN
namespace {

using SidBytes = QVector<BYTE>;

// 模拟令牌：进程令牌的副本（含 SID、组与完整性级别，即"当前用户实际拥有的身份"）。
struct SessionToken {
    HANDLE token = nullptr;
    ~SessionToken() { if (token) CloseHandle(token); }
};

bool openSessionToken(SessionToken &t)
{
    HANDLE raw = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE, &raw))
        return false;
    HANDLE sim = nullptr;
    const bool ok = DuplicateTokenEx(raw, TOKEN_QUERY | TOKEN_IMPERSONATE | TOKEN_DUPLICATE,
                                     nullptr, SecurityImpersonation, TokenImpersonation, &sim);
    CloseHandle(raw);
    if (!ok)
        return false;
    t.token = sim;
    return true;
}

bool sameSid(PSID a, const SidBytes &b)
{
    return a && !b.isEmpty() && IsValidSid(a) && EqualSid(a, const_cast<BYTE *>(b.constData()));
}

bool makeWellKnown(WELL_KNOWN_SID_TYPE type, SidBytes &out)
{
    out.resize(SECURITY_MAX_SID_SIZE);
    DWORD len = DWORD(out.size());
    if (!CreateWellKnownSid(type, nullptr, out.data(), &len)) {
        out.clear();
        return false;
    }
    out.resize(int(len));
    return true;
}

QString sidStr(PSID sid)
{
    LPWSTR s = nullptr;
    if (!ConvertSidToStringSidW(sid, &s))
        return QStringLiteral("?");
    const QString out = QString::fromWCharArray(s);
    LocalFree(s);
    return out;
}

bool tokenMemberOf(HANDLE token, PSID sid)
{    // 用令牌的 SID 列表直接匹配，而不是 CheckTokenMembership：后者对"管理员"这类内建组
    // 走的是组启用状态之外的兼容逻辑，结果会和 ACE 的实际生效情况对不上。
    if (!sid || !IsValidSid(sid))
        return false;
    DWORD size = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &size);
    GetTokenInformation(token, TokenGroups, nullptr, 0, &size);
    QVector<BYTE> buf(qMax<DWORD>(size, 4096));
    if (!GetTokenInformation(token, TokenUser, buf.data(), DWORD(buf.size()), &size))
        return false;
    auto *user = reinterpret_cast<TOKEN_USER *>(buf.data());
    if (EqualSid(user->User.Sid, sid))
        return true;
    if (!GetTokenInformation(token, TokenGroups, buf.data(), DWORD(buf.size()), &size))
        return false;
    auto *groups = reinterpret_cast<TOKEN_GROUPS *>(buf.data());
    for (DWORD i = 0; i < groups->GroupCount; ++i) {
        if (EqualSid(groups->Groups[i].Sid, sid))
            return true;
    }
    return false;
}

// DACL 逐条匹配（DENY 优先、允许位含写位即可写）。不用 AccessCheck：管理员组是巨大位
// 掩码，带了写位就会让任何检查一律通过；这里只认明确对本令牌生效的 ACE。
// - 管理员组：只有令牌里该组可用（已提升）时才生效，UAC 未提升时被过滤掉；
// - 创建者所有者/创建者组：只对新建对象有意义，跳过；
// - SYSTEM：与能否写无关，跳过。
bool aclAllowsWrite(HANDLE token, PACL acl, const SidBytes &admin, const SidBytes &system,
                    const SidBytes &creatorOwner, const SidBytes &creatorGroup)
{
    if (!acl)
        return false;
    const DWORD writeBits = FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY | FILE_WRITE_DATA | FILE_APPEND_DATA;
    for (DWORD i = 0; i < DWORD(acl->AceCount); ++i) {
        void *ace = nullptr;
        if (!GetAce(acl, i, &ace))
            continue;
        auto *header = static_cast<ACE_HEADER *>(ace);
        const bool isAllow = header->AceType == ACCESS_ALLOWED_ACE_TYPE;
        const bool isDeny = header->AceType == ACCESS_DENIED_ACE_TYPE;
        if (!isAllow && !isDeny)
            continue;
        auto *allowed = static_cast<ACCESS_ALLOWED_ACE *>(ace);
        PSID sid = reinterpret_cast<PSID>(&allowed->SidStart);
        const DWORD mask = allowed->Mask;
        if (qEnvironmentVariableIsSet("ORBBEC_ACL_DEBUG"))
            printf("ACE %s mask=0x%lx member=%d\n", qPrintable(sidStr(sid)), (unsigned long)(mask & 0xffffffff),
                   int(tokenMemberOf(token, sid)));
        if (sameSid(sid, admin)) {
            if (!tokenMemberOf(token, sid))
                continue;
        } else if (!tokenMemberOf(token, sid)) {
            continue;
        }
        if (isDeny) {
            if (mask & writeBits)
                return false;
        } else if (mask & writeBits) {
            return true;
        }
    }
    return false;
}

} // namespace

Access accessForNewDirectory(const QString &parentDir)
{
    // 在 parentDir 下新建目录 = 对 parentDir 的 FILE_ADD_SUBDIRECTORY；已有目录 = FILE_ADD_FILE。
    // 两者都在 aclAllowsWrite 的写位里，所以对父目录做一次同样的判断即可。
    SessionToken t;
    if (!openSessionToken(t))
        return Access::Unknown;
    const QString native = QDir::toNativeSeparators(parentDir);
    PSECURITY_DESCRIPTOR sd = nullptr;
    PACL dacl = nullptr;
    if (GetNamedSecurityInfoW(reinterpret_cast<LPCWSTR>(native.utf16()), SE_FILE_OBJECT,
                              DACL_SECURITY_INFORMATION, nullptr, nullptr, &dacl, nullptr, &sd)
        != ERROR_SUCCESS)
        return Access::Unknown;
    SidBytes admin, system, creatorOwner, creatorGroup;
    const bool sids = makeWellKnown(WinBuiltinAdministratorsSid, admin)
                      && makeWellKnown(WinLocalSystemSid, system)
                      && makeWellKnown(WinCreatorOwnerSid, creatorOwner)
                      && makeWellKnown(WinCreatorGroupSid, creatorGroup);
    const bool writable = sids && aclAllowsWrite(t.token, dacl, admin, system, creatorOwner, creatorGroup);
    LocalFree(sd);
    if (!sids)
        return Access::Unknown;
    return writable ? Access::Writable : Access::ReadOnly;
}

QString daclStr(const QString &path)
{
    PSECURITY_DESCRIPTOR sd = nullptr;
    PACL dacl = nullptr;
    if (GetNamedSecurityInfoW(reinterpret_cast<LPCWSTR>(QDir::toNativeSeparators(path).utf16()),
                              SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, nullptr, nullptr, &dacl,
                              nullptr, &sd)
        != ERROR_SUCCESS)
        return QStringLiteral("<none>");
    LPWSTR s = nullptr;
    QString out;
    if (ConvertSecurityDescriptorToStringSecurityDescriptorW(sd, SDDL_REVISION_1, DACL_SECURITY_INFORMATION, &s, nullptr)) {
        out = QString::fromWCharArray(s);
        LocalFree(s);
    }
    LocalFree(sd);
    return out;
}

bool isAdmin()
{
    SessionToken t;
    if (!openSessionToken(t))
        return false;
    SidBytes admin;
    if (!makeWellKnown(WinBuiltinAdministratorsSid, admin))
        return false;
    return tokenMemberOf(t.token, admin.data());
}

Access effectiveAccess(const QString &dirPath)
{
    const QString given = QFileInfo(dirPath).absoluteFilePath();
    QString dir = given;
    while (!QFileInfo(dir).exists() && !QFileInfo(dir).isRoot() && dir.length() > 3)
        dir = QFileInfo(dir).absolutePath();
    const QFileInfo existing(dir);
    if (!existing.exists())
        return Access::Missing;
    if (!existing.isDir())
        return Access::Unknown;
    // 目录还不存在：能否新建取决于第一个存在祖先的"新建子目录"权限。
    if (QDir::cleanPath(dir) != QDir::cleanPath(given))
        return accessForNewDirectory(dir);

    SessionToken t;
    if (!openSessionToken(t))
        return Access::Unknown;

    const QString native = QDir::toNativeSeparators(dir);
    PSECURITY_DESCRIPTOR sd = nullptr;
    PACL dacl = nullptr;
    if (GetNamedSecurityInfoW(reinterpret_cast<LPCWSTR>(native.utf16()), SE_FILE_OBJECT,
                              DACL_SECURITY_INFORMATION, nullptr, nullptr, &dacl, nullptr, &sd)
        != ERROR_SUCCESS)
        return Access::Unknown;

    if (qEnvironmentVariableIsSet("ORBBEC_ACL_DEBUG")) {
        printf("ACL %s\n", qPrintable(daclStr(dir)));
        fflush(stdout);
        return Access::Unknown;
    }
    SidBytes admin, system, creatorOwner, creatorGroup;
    const bool sids = makeWellKnown(WinBuiltinAdministratorsSid, admin)
                      && makeWellKnown(WinLocalSystemSid, system)
                      && makeWellKnown(WinCreatorOwnerSid, creatorOwner)
                      && makeWellKnown(WinCreatorGroupSid, creatorGroup);
    const bool writable = sids && aclAllowsWrite(t.token, dacl, admin, system, creatorOwner, creatorGroup);
    LocalFree(sd);
    if (!sids)
        return Access::Unknown;
    return writable ? Access::Writable : Access::ReadOnly;
}

#else

bool isAdmin() { return false; }
Access effectiveAccess(const QString &) { return Access::Unknown; }

#endif

} // namespace MSOpen
