// UiBtn.qml
import QtQuick
import SetupUi

// 通用按钮（与评审稿 .button / .button.primary / .button.danger 对应）。
// 单独成文件而不是 Ui.qml 的内联 component：本工程按绝对 qrc 路径加载模块，
// 内联组件里的类型引用与 Theme 实例在 Qt 6.8 下会解析成 undefined（见 UiTheme.qml）。
Rectangle {
    id: b
    UiTheme { id: theme }   // 普通属性对象，放在 id 之后（Qt 6.8 下 id 必须紧跟根对象）

    property string text: ""
    property bool primary: false
    property bool danger: false
    property bool enabledState: true
    // 禁用态沿用按钮本色、整只按钮压到 45% 不透明度（评审稿 .button:disabled { opacity: .45 }），
    // 否则主按钮会退成一块灰底深字，比评审稿更重。
    opacity: enabledState ? 1 : 0.45
    Behavior on opacity { NumberAnimation { duration: theme.animFast } }
    signal clicked()

    // 评审稿 .button { min-width: 88px; padding: 0 16px }；高度 36px（目录框等需要对齐时单独改）。
    // 悬停：.button:hover { border-color: 品牌浅色; color: var(--brand-dark) }；
    // 主按钮悬停换成 brand-dark；悬停时也给主按钮补上同色描边，尺寸保持不变。
    implicitWidth: Math.max(88, label.implicitWidth + 32)
    implicitHeight: 36
    radius: theme.radius
    border.width: 1
    border.color: ma.containsMouse ? theme.brandHoverLine : theme.line
    color: b.danger ? theme.danger
         : b.primary ? (ma.pressed || ma.containsMouse ? theme.brandDark : theme.brand)
         : (ma.pressed ? theme.line : ma.containsMouse ? theme.lineSoft : theme.panel)
    Behavior on color { ColorAnimation { duration: theme.animFast } }

    Text {
        id: label
        anchors.centerIn: parent
        text: b.text
        font.family: theme.fontFamily
        font.pixelSize: theme.fontButton
        font.bold: b.primary || b.danger
        color: (b.primary || b.danger) ? theme.white : ma.containsMouse ? theme.brandDark : theme.text
    }
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        enabled: b.enabledState
        cursorShape: b.enabledState ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: b.clicked()
    }
}
