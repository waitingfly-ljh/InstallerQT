// UiBtn.qml
import QtQuick
import SetupUi

// Generic button (corresponds to design mockup .button / .button.primary / .button.danger).
// Kept as a separate file instead of an inline component in Ui.qml: this project loads modules via absolute qrc paths, and
// type references and Theme instances inside inline components resolve to undefined under Qt 6.8 (see UiTheme.qml).
Rectangle {
    id: b
    UiTheme { id: theme }   // Plain property object placed after the id (under Qt 6.8 the id must immediately follow the root object)

    property string text: ""
    property bool primary: false
    property bool danger: false
    property bool enabledState: true
    // The disabled state keeps the button's own color and dims the whole button to 45% opacity (design mockup .button:disabled { opacity: .45 }),
    // otherwise the primary button would degrade into gray background with dark text, heavier than the design mockup.
    opacity: enabledState ? 1 : 0.45
    Behavior on opacity { NumberAnimation { duration: theme.animFast } }
    signal clicked()

    // Design mockup .button { min-width: 88px; padding: 0 16px }; height 36px (adjust individually when aligning directory boxes, etc.).
    // Hover: .button:hover { border-color: brand light color; color: var(--brand-dark) };
    // the primary button switches to brand-dark on hover; the primary button also gets a matching-color border on hover, size unchanged.
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
