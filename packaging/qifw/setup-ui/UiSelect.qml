// UiSelect.qml
import QtQuick
import QtQuick.Controls.Basic
import SetupUi

// Dropdown field (design: 创建快照 dropdowns and the suggestion overlay on -1/-2).
// Field: same chrome as UiField (43px, white, 1px #F5F5F5, rx9.5, 10px inset) plus a 12px chevron.
// Overlay (measured on 创建快照-1): 442x100 panel, rx8, white at 98%, 430x44 rows with 6px corners,
// the current row highlighted with brand at 11% and a brand tick at the right edge.
// The overlay is a Popup, so opening it never moves any page element (it is not part of the layout).
// Keyboard: Up / Down move the highlight, Enter activates it, Esc and a click outside close.
// When readOnly or disabled the chevron is hidden and the field is not clickable (used for the
// read-only rows the design draws as dropdowns but that carry a single engine value).
Rectangle {
    id: sel
    UiTheme { id: theme }

    property string text: ""
    property string placeholder: ""
    // Text elision inside the field (paths use ElideMiddle, values ElideRight).
    property int elideMode: Text.ElideRight
    property var model: []                 // ["value", ...] or [{ "label": "..." }]
    property int currentIndex: -1
    property bool readOnly: false
    property bool disabled: false
    property bool focused: false
    // Exposed for the smoke check (--selftest --qml-smoke).
    readonly property bool expanded: popup.visible

    signal activated(int index)

    function itemLabel(i) {
        const v = sel.model[i]
        if (v === undefined || v === null)
            return ""
        return (typeof v === "object") ? String(v.label !== undefined ? v.label : v.value) : String(v)
    }
    function commit(i) {
        if (i < 0 || i >= sel.model.length)
            return
        sel.currentIndex = i
        sel.text = sel.itemLabel(i)
        sel.activated(i)
    }

    implicitHeight: theme.snapshotFieldH
    radius: theme.radiusSnapshotField
    color: sel.disabled ? theme.panelSoft : theme.panel
    border.width: 1
    border.color: sel.focused ? theme.brand : theme.fieldOutline

    Text {
        id: display
        anchors.left: parent.left
        anchors.right: chevron.left
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        text: sel.text.length > 0 ? sel.text : sel.placeholder
        elide: sel.elideMode
        font.family: theme.fontFamily
        font.pixelSize: theme.fontBody
        color: sel.text.length > 0
               ? (sel.disabled ? theme.muted : theme.textStrong)
               : theme.textPlaceholder
    }

    // Chevron: two 2px strokes forming a 12x6 v (design: M912 142.75 L918 148 L924 142.75, ink #222222).
    Item {
        id: chevron
        visible: !sel.readOnly && !sel.disabled
        anchors.right: parent.right
        anchors.rightMargin: 16
        anchors.verticalCenter: parent.verticalCenter
        width: 12
        height: 8
        Rectangle {
            x: 3
            y: 1
            width: 2
            height: 7
            radius: 1
            rotation: -40
            color: theme.text
        }
        Rectangle {
            x: 7
            y: 1
            width: 2
            height: 7
            radius: 1
            rotation: 40
            color: theme.text
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: !sel.readOnly && !sel.disabled && sel.model.length > 0
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: {
            if (popup.visible)
                popup.close()
            else
                popup.open()
        }
    }

    Popup {
        id: popup
        parent: sel
        x: 0
        y: sel.height + 4
        width: theme.selectPanelW
        height: Math.min(theme.selectPanelH, Math.max(theme.selectRowH, rows.implicitHeight) + 2 * padding)
        padding: 4
        modal: false
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        background: Rectangle {
            radius: theme.radiusPanel
            color: theme.selectPanel
            border.width: 1
            border.color: theme.fieldOutline
        }

        contentItem: Column {
            id: rows
            width: theme.selectRowW
            spacing: 0

            Repeater {
                model: sel.model
                delegate: Rectangle {
                    id: row
                    required property int index
                    required property var modelData
                    width: theme.selectRowW
                    height: theme.selectRowH
                    radius: theme.radiusSelectRow
                    color: row.index === sel.currentIndex ? theme.selectHighlight : "transparent"

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 13
                        anchors.verticalCenter: parent.verticalCenter
                        text: sel.itemLabel(row.index)
                        elide: Text.ElideRight
                        width: parent.width - 60
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontBody
                        color: row.index === sel.currentIndex ? theme.brand : theme.selectRowInk
                    }
                    Text {
                        visible: row.index === sel.currentIndex
                        anchors.right: parent.right
                        anchors.rightMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        text: "✓"
                        color: theme.brand
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontCheck
                        font.bold: true
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            sel.commit(row.index)
                            popup.close()
                        }
                    }
                }
            }
        }

        Keys.onDownPressed: {
            if (sel.currentIndex < sel.model.length - 1)
                sel.currentIndex += 1
        }
        Keys.onUpPressed: {
            if (sel.currentIndex > 0)
                sel.currentIndex -= 1
        }
        Keys.onReturnPressed: {
            sel.commit(sel.currentIndex)
            popup.close()
        }
        Keys.onEnterPressed: {
            sel.commit(sel.currentIndex)
            popup.close()
        }
    }
}
