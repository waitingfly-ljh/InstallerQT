// Current token and directory access check (Windows): results match "can files be put into this folder" in File Explorer.
// Note: do not judge by "trying to write a temporary file". OpenFile goes through user-mode elevation fallback
// (AppInfo auto-elevation manifest, UAC virtualization), so an ordinary user often "succeeds" creating a file
// in Program Files / C:\Windows, but that is not the location the installer would actually write to. Here we use
// identity impersonation + per-ACE matching to compute effective permissions.
#pragma once

#include <QString>

namespace MSOpen {

enum class Access {
    Writable, // Can create new files in the directory
    ReadOnly, // Directory exists but there is no modify permission
    Missing,  // Directory does not exist (or its parent does not)
    Unknown,  // Enumeration failed: cannot determine
};

QString accessName(Access a);

// Whether the process runs as administrator (the Administrators group is enabled in the token, i.e. elevated).
bool isAdmin();

// Directory access: for a nonexistent directory, returns the access state of the first existing ancestor.
Access effectiveAccess(const QString &dirPath);

// Whether there is permission to create a new directory under parentDir (FILE_ADD_SUBDIRECTORY on the parent).
// parentDir must already exist; the caller is responsible for checking. Unknown is treated as allowed.
Access accessForNewDirectory(const QString &parentDir);

} // namespace MSOpen
