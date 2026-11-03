// 自检入口：以最小平台加载同一套界面组件，验证 QML 模块与运行时依赖可用。
// 主程序 --selftest 时加载本组件而不是 Main（Main 的根是 Window，最小平台下也
// 可以创建，但这里刻意只做"编译 + 实例化"，不进入窗口展示流程）。
import QtQuick
import SetupUi

AppFrame {
}
