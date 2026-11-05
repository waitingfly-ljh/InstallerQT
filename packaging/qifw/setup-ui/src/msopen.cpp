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
    case Access::Writable: return QStringLiteral("Writable");
    case Access::ReadOnly: return QStringLiteral("Read-only");
    case Access::Missing:  return QStringLiteral("Does not exist");
    case Access::Unknown:  break;
    }
    return QStringLiteral("Unknown");
}

#ifdef Q_OS_WIN
namespace {

using SidBytes = QVector<BYTE>;

// Impersonation token: a copy of the process token (with SID, groups and integrity level, i.e. "the identity the current user actually has").
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
{    // Match directly against the token's SID list instead of CheckTokenMembership: the latter uses
    // compatibility logic beyond group enable state for built-in groups like "Administrators", so results
    // would not match how the ACE actually takes effect.
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

// Match DACL entries one by one (DENY takes priority; writable if the allowed bits include a write bit). Do not use
// AccessCheck: the Administrators group is a huge bit mask, so any write bit would make every check pass; here we
// only honor ACEs that explicitly take effect for this token.
// - Administrators group: effective only when that group is enabled in the token (elevated); filtered out when UAC is not elevated;
// - CREATOR OWNER/CREATOR GROUP: only meaningful for newly created objects, skipped;
// - SYSTEM: unrelated to whether we can write, skipped.
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
    // Creating a new directory under parentDir = FILE_ADD_SUBDIRECTORY on parentDir; existing directory = FILE_ADD_FILE.
    // Both are within aclAllowsWrite's write bits, so a single equivalent check on the parent directory suffices.
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
    // The directory does not exist yet: whether it can be created depends on the first existing ancestor's "create subdirectory" permission.
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
