function Component()
{
    console.log("[smoke] component loaded from " + component.name);
}

Component.prototype.createOperations = function()
{
    component.createOperations();

    console.log("[smoke] installing " + component.name + " to " + installer.value("TargetDir"));

    // 冒烟目标是让"安装 → 校验 → 卸载 → 校验清理"覆盖到快捷方式。
    // 快捷方式指向 payload/README.txt（不存在就退化为打开安装目录），
    // run-smoke.ps1 会在安装后断言它存在、卸载后断言它被删除。
    // 注意：Windows 上 systemInfo.kernelType 的值是 "winnt"，不是 "win"
    var target = installer.value("TargetDir") + "\\payload\\README.txt";
    if (systemInfo.kernelType === "winnt") {
        component.addOperation("CreateShortcut", target,
                               "@StartMenuDir@/OrbbecSlicer QIFW Smoke.lnk",
                               "workingDirectory=@TargetDir@");
    }
    else {
        console.log("[smoke] 非 Windows 平台（" + systemInfo.kernelType + "），跳过快捷方式");
    }
}
