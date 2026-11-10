function Component()
{
    console.log("[smoke] component loaded from " + component.name);
}

Component.prototype.createOperations = function()
{
    component.createOperations();

    console.log("[smoke] installing " + component.name + " to " + installer.value("TargetDir"));

    // The smoke goal is to have "install -> verify -> uninstall -> verify cleanup" cover the shortcut.
    // The shortcut points to payload/README.txt (falls back to opening the install dir if missing);
    // run-smoke.ps1 asserts it exists after install and is deleted after uninstall.
    // Note: on Windows, systemInfo.kernelType is "winnt", not "win"
    var target = installer.value("TargetDir") + "\\payload\\README.txt";
    if (systemInfo.kernelType === "winnt") {
        component.addOperation("CreateShortcut", target,
                               "@StartMenuDir@/OrbbecSlicer QIFW Smoke.lnk",
                               "workingDirectory=@TargetDir@");
    }
    else {
        console.log("[smoke] non-Windows platform (" + systemInfo.kernelType + "), skipping shortcut");
    }
}
