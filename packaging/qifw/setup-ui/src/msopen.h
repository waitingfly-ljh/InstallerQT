// 当前令牌与目录访问检查（Windows）：结果与文件管理器里"能不能往这个文件夹里放文件"一致。
// 注意：不要用"试着写一个临时文件"来判断。OpenFile 走的是用户态提升回退
// （AppInfo 自动提升清单、UAC 虚拟化），普通用户往 Program Files / C:\Windows 里建文件
// 常常"成功"，实际那不是安装程序会写入的位置。这里用身份模拟 + 逐条 ACE 匹配算有效权限。
#pragma once

#include <QString>

namespace MSOpen {

enum class Access {
    Writable, // 能在目录里新建文件
    ReadOnly, // 目录存在，但没有修改权限
    Missing,  // 目录不存在（或其上级不存在）
    Unknown,  // 枚举失败：无法判断
};

QString accessName(Access a);

// 进程是否以管理员身份运行（令牌里管理员组可用，即已提升）。
bool isAdmin();

// 目录访问：对不存在的目录，返回第一个存在的祖先的访问情况。
Access effectiveAccess(const QString &dirPath);

// 在 parentDir 下新建目录是否有权限（对父目录的 FILE_ADD_SUBDIRECTORY）。
// parentDir 必须已存在；调用方负责检查。Unknown 视为放行。
Access accessForNewDirectory(const QString &parentDir);

} // namespace MSOpen
