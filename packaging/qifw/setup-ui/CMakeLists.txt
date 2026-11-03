cmake_minimum_required(VERSION 3.21)
project(OrbbecSlicerSetup VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# 截图构建：build-shot/ 里额外注册 OrbbecShot.QmlShot 单例，供 tools/capture-ui.ps1
# 把界面摆到某个视图后抓图。普通构建不注册，QML 里读不到这个模块（QmlSmoke 也不会被创建）。
option(ORBBEC_SETUP_SHOT "Build the screenshot harness (QmlShot singleton)" OFF)

# 只依赖 Qt 的 Core / Gui / Quick / Qml：不链接 QuickControls2，
# 控件在 QML 里从 QtQuick.Controls.Basic 导入（windeployqt 负责部署运行时模块）。
find_package(Qt6 REQUIRED COMPONENTS Core Gui Quick Qml)
qt_standard_project_setup()

qt_add_executable(OrbbecSlicerSetup
    WIN32
    src/main.cpp
)

# 版本号由构建脚本通过 -DORBBEC_SETUP_VERSION=... 传入；缺省 1.0.0。
if (NOT DEFINED ORBBEC_SETUP_VERSION)
    set(ORBBEC_SETUP_VERSION "1.0.0")
endif()
target_compile_definitions(OrbbecSlicerSetup PRIVATE ORBBEC_SETUP_VERSION="${ORBBEC_SETUP_VERSION}")

if (ORBBEC_SETUP_SHOT)
    target_compile_definitions(OrbbecSlicerSetup PRIVATE ORBBEC_SETUP_SHOT)
endif()

# QML 源码全部平铺在源码根目录（通用组件 + pages/ 页面）。
#
# 为什么不放进 qml/ 子目录：qt_add_qml_module 生成 qmldir 时写的是 "App 1.0 <相对
# CMAKE_CURRENT_SOURCE_DIR 的路径>"，而资源别名也是按同一相对路径算的；当 QML 文件
# 位于调用目录之外（如 <src>/qml/App.qml），两者都会变成 "qml/App.qml"，模块根目录
# 下反而没有 qmldir，loadFromModule 报 "Module contains no type named ..."。
# 平铺后模块根 = 源码根，qmldir 与资源一一对应。
# 也不要开 QTP0004：页面与根目录同一个模块，不需要子目录 qmldir。
# 页面在 pages/ 子目录：开启 QTP0004 让 qt_add_qml_module 为子目录生成 qmldir，
# 否则 pages/*.qml 里的 `import SetupUi` 解析不到根目录的类型（如 UiTheme）。
qt_policy(SET QTP0004 NEW)

qt_add_qml_module(OrbbecSlicerSetup
    URI SetupUi
    VERSION 1.0
    RESOURCE_PREFIX /
    QML_FILES
        App.qml
        Main.qml
        UiBtn.qml
        BrandMark.qml
        SetupController.qml
        UiTheme.qml
        LoadEntry.qml
        StepList.qml
        QmlSmoke.qml
        AppFrame.qml
        SideGlow.qml
        pages/OptionsPage.qml
        pages/ProgressPage.qml
        pages/CompletePage.qml
        pages/MaintenancePage.qml
        pages/FailurePage.qml
        pages/DataScopePage.qml
        pages/UninstallConfirmPage.qml
    SOURCES
        src/setuphost.h
        src/setuphost.cpp
        src/setupengine.h
        src/setupengine.cpp
        src/environment.h
        src/environment.cpp
        src/msopen.h
        src/msopen.cpp
)

target_link_libraries(OrbbecSlicerSetup PRIVATE Qt6::Core Qt6::Gui Qt6::Quick Qt6::Qml)

# 侧栏光斑：SideGlow.qml 的同一公式预生成成一张 228×300 的 PNG（AppFrame 用 Image 拉伸显示）。
# 资源别名固定成 /glow.png，QML 里引用 qrc:/glow.png。
set_source_files_properties(resources/glow.png PROPERTIES QT_RESOURCE_ALIAS glow.png)
qt_add_resources(OrbbecSlicerSetup "glow"
    PREFIX "/"
    FILES resources/glow.png
)

# QmlSmoke 只在截图构建里被实例化；它 import 的 OrbbecShot 模块是运行期注册的。
# 跳过该文件的 qmlcachegen，避免普通构建在编译期解析一个尚未注册的模块。
set_source_files_properties(QmlSmoke.qml PROPERTIES QT_QML_SKIP_QMLCACHEGEN TRUE)

set_target_properties(OrbbecSlicerSetup PROPERTIES
    OUTPUT_NAME "OrbbecSlicerSetup"
)

# 单文件启动器：不链接 Qt，负责从自身尾部释放 ui/ + payload/ 再启动界面。
add_executable(OrbbecSlicerSetupLauncher WIN32 src/launcher.cpp)
target_compile_definitions(OrbbecSlicerSetupLauncher PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(OrbbecSlicerSetupLauncher PRIVATE shell32)
set_target_properties(OrbbecSlicerSetupLauncher PROPERTIES
    OUTPUT_NAME "OrbbecSlicerSetupLauncher"
)

if (WIN32)
    target_compile_definitions(OrbbecSlicerSetup PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
endif()
