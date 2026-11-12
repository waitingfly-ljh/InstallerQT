// UiField.qml
import QtQuick
import SetupUi

// Form field for the 11-11 design (measured on 创建快照): 441x43, white fill, 1px #F5F5F5 outline,
// rx9.5, 10px text inset. States:
//   focused  brand 1px outline
//   danger   red 1px outline (invalid snapshot name)
//   disabled #FAFBFB fill with the normal outline, muted content
// The field itself only draws the chrome: its default property is an Item that fills the 10px
// text inset, so pages keep their own Text / TextInput (and therefore all their editing logic).
Rectangle {
    id: field
    UiTheme { id: theme }

    property bool focused: false
    property bool danger: false
    property bool disabled: false
    default property alias content: body.data

    implicitHeight: theme.snapshotFieldH
    radius: theme.radiusSnapshotField
    color: field.disabled ? theme.panelSoft : theme.panel
    border.width: 1
    border.color: field.danger ? theme.danger
                : field.focused ? theme.brand
                : theme.fieldOutline

    Item {
        id: body
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 10
    }
}
