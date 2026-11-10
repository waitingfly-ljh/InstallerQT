cmake_minimum_required(VERSION 3.21)
project(OrbbecSlicerSetup VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# Screenshot build: build-shot/ additionally registers the OrbbecShot.QmlShot singleton, for tools/capture-ui.ps1
# to capture a screenshot after placing the UI on a given view. The normal build does not register it, so QML cannot read this module (and QmlSmoke is not created).
option(ORBBEC_SETUP_SHOT "Build the screenshot harness (QmlShot singleton)" OFF)

# Depends only on Qt's Core / Gui / Quick / Qml: does not link QuickControls2,
# controls are imported in QML from QtQuick.Controls.Basic (windeployqt handles deploying the runtime modules).
# LinguistTools provides lupdate/lrelease so the shell can ship an embedded zh_CN translation.
find_package(Qt6 REQUIRED COMPONENTS Core Gui Quick Qml LinguistTools)
qt_standard_project_setup()

qt_add_executable(OrbbecSlicerSetup
    WIN32
    src/main.cpp
    src/app.rc
)

# The version is passed by the build script via -DORBBEC_SETUP_VERSION=...; defaults to 1.0.0.
if (NOT DEFINED ORBBEC_SETUP_VERSION)
    set(ORBBEC_SETUP_VERSION "1.0.0")
endif()
target_compile_definitions(OrbbecSlicerSetup PRIVATE ORBBEC_SETUP_VERSION="${ORBBEC_SETUP_VERSION}")

if (ORBBEC_SETUP_SHOT)
    target_compile_definitions(OrbbecSlicerSetup PRIVATE ORBBEC_SETUP_SHOT)
endif()

# All QML sources are flat in the source root (common components + pages/ pages).
#
# Why not put them in a qml/ subdirectory: qt_add_qml_module writes "App 1.0 <path relative
# to CMAKE_CURRENT_SOURCE_DIR>" when generating qmldir, and the resource alias is computed from the same relative path; when the QML files
# live outside the calling directory (e.g. <src>/qml/App.qml), both become "qml/App.qml", so the module root
# has no qmldir and loadFromModule reports "Module contains no type named ...".
# Flattened, the module root = the source root, and qmldir maps one-to-one to resources.
# Also do not enable QTP0004: the pages and the root are the same module, so no subdirectory qmldir is needed.
# Pages are in the pages/ subdirectory: enabling QTP0004 lets qt_add_qml_module generate a qmldir for the subdirectory,
# otherwise `import SetupUi` in pages/*.qml cannot resolve types in the root directory (such as UiTheme).
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

# Translations: English is the source language (every user-visible string is written in English
# and wrapped in qsTr()/tr()); zh_CN is the optional second language.
#
# qt_add_translations runs lrelease at build time and embeds the resulting .qm into the target
# resource at :/i18n/<ts-basename>.qm (default RESOURCE_PREFIX "/i18n"), so the translation travels
# inside the executable and cannot be dropped by the dist/ packaging step. Run the
# "update_translations" target after changing user-visible strings to refresh the .ts.
qt_add_translations(OrbbecSlicerSetup
    TS_FILES translations/OrbbecSlicerSetup_zh_CN.ts
    SOURCES
        src/setuphost.h
        src/setuphost.cpp
        src/setupengine.h
        src/setupengine.cpp
        src/environment.h
        src/environment.cpp
        src/msopen.h
        src/msopen.cpp
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
)

# Sidebar glow: the same formula from SideGlow.qml is pre-generated as a 228x300 PNG (AppFrame displays it stretched with Image).
# The resource alias is fixed to /glow.png, referenced in QML as qrc:/glow.png.
set_source_files_properties(resources/app.ico PROPERTIES QT_RESOURCE_ALIAS app.ico)
qt_add_resources(OrbbecSlicerSetup "brandicon"
    PREFIX "/"
    FILES resources/app.ico
)

set_source_files_properties(resources/glow.png PROPERTIES QT_RESOURCE_ALIAS glow.png)
qt_add_resources(OrbbecSlicerSetup "glow"
    PREFIX "/"
    FILES resources/glow.png
)

# QmlSmoke is only instantiated in the screenshot build; the OrbbecShot module it imports is registered at runtime.
# Skip qmlcachegen for this file so the normal build does not try to resolve an as-yet-unregistered module at compile time.
set_source_files_properties(QmlSmoke.qml PROPERTIES QT_QML_SKIP_QMLCACHEGEN TRUE)

set_target_properties(OrbbecSlicerSetup PROPERTIES
    OUTPUT_NAME "OrbbecSlicerSetup"
)

# Single-file launcher: does not link Qt; extracts ui/ + payload/ from its own trailer and then starts the UI.
add_executable(OrbbecSlicerSetupLauncher WIN32 src/launcher.cpp src/app.rc)
target_compile_definitions(OrbbecSlicerSetupLauncher PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(OrbbecSlicerSetupLauncher PRIVATE shell32)
set_target_properties(OrbbecSlicerSetupLauncher PROPERTIES
    OUTPUT_NAME "OrbbecSlicerSetupLauncher"
)

if (WIN32)
    target_compile_definitions(OrbbecSlicerSetup PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
endif()
