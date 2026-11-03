// 品牌标记：绿色圆角方块 + 内嵌浅色方块（对应评审稿 .brand-mark 与 ::after）。
import QtQuick

Item {
    id: root
    UiTheme { id: theme }   // 视觉令牌实例，见 UiTheme.qml 顶部说明
    // 颜色默认取品牌色，使用方可覆盖。
    property color base: theme.brand
    property color accent: theme.brandSoft
    implicitWidth: 14
    implicitHeight: 14

    Rectangle {
        anchors.fill: parent
        radius: 3
        color: root.base
    }
    Rectangle {
        width: Math.round(root.width * 0.42)
        height: width
        radius: Math.round(width * 0.3)
        anchors.centerIn: parent
        color: root.accent
    }
}
