// MaintenancePage.qml
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import SetupUi

// Maintenance screens (design: 覆盖升级 / 降级安装 / 修复): current vs. installer version cards, the
// list of data that survives the operation, and - for a downgrade - the incompatibility warning that
// must be acknowledged before the primary button becomes available.
Item {
    id: page
    UiTheme { id: theme }

    width: theme.contentW
    height: theme.contentH

    property string mode: "repair"           // repair | upgrade | downgrade
    property string currentVersion: ""
    property string targetVersion: ""
    property bool riskAcknowledged: false
    signal proceedRequested(mode: string)
    signal cancelRequested()
    signal riskToggled(bool checked)

    readonly property string title: mode === "repair" ? qsTr("Repair OrbbecSlicer")
                                  : mode === "upgrade" ? qsTr("Upgrade OrbbecSlicer")
                                  : qsTr("Downgrade OrbbecSlicer")
    // Leads stay short enough to render on one line inside the 442px content column (the design
    // shows a single lead line on all three maintenance screens).
    readonly property string lead: mode === "repair"
        ? qsTr("Same version installed; repair keeps all your data.")
        : mode === "upgrade"
        ? qsTr("Overwrites program files; your data is kept.")
        : qsTr("Older installer: acknowledge the risk to continue.")
    readonly property string primaryText: mode === "repair" ? qsTr("Start repair")
                                        : mode === "upgrade" ? qsTr("Start upgrade")
                                        : qsTr("Confirm and downgrade")
    readonly property var retained: [
        qsTr("Custom presets"), qsTr("Software preferences"), qsTr("Account session"),
        qsTr("Calibration results"), qsTr("Printer info"), qsTr("LAN access code")
    ]

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Text {
            Layout.fillWidth: true
            text: page.title
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontTitle
            font.weight: Font.Bold
            color: theme.brand
        }
        Item { Layout.preferredHeight: 6 }

        Text {
            Layout.fillWidth: true
            text: page.lead
            wrapMode: Text.WordWrap
            lineHeight: 1.5
            font.family: theme.fontFamily
            font.pixelSize: theme.fontLead
            color: theme.textBody
        }
        Item { Layout.preferredHeight: 5 }

        // Version comparison (design: two 80px cards, 170 wide, ~100px apart with a teal arrow;
        // the installed side is white with a #ececec border, the installer side is #f2faf9 with a
        // brand border).
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 80
            Layout.minimumHeight: 80
            Layout.maximumHeight: 80
            spacing: 0

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 80
                radius: theme.radiusCard
                color: theme.white
                border.width: 1
                border.color: theme.btnSecondaryLine
                Column {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 15
                    anchors.rightMargin: 15
                    spacing: 6
                    Text {
                        text: qsTr("Current version")
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontBody
                        color: theme.textBody
                    }
                    Text {
                        text: page.currentVersion.length > 0 ? page.currentVersion : qsTr("Unknown")
                        font.family: theme.fontFamily
                        font.pixelSize: 20
                        font.weight: Font.Bold
                        color: theme.text
                    }
                }
            }

            Item {
                Layout.preferredWidth: 100
                Layout.fillHeight: true
                Text {
                    anchors.centerIn: parent
                    text: "→"
                    font.family: theme.fontFamily
                    font.pixelSize: 20
                    color: theme.brand
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 80
                radius: theme.radiusCard
                color: theme.cardTeal
                border.width: 1
                border.color: theme.brand
                Column {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 15
                    anchors.rightMargin: 15
                    spacing: 6
                    Text {
                        text: qsTr("Installer version")
                        font.family: theme.fontFamily
                        font.pixelSize: theme.fontBody
                        color: theme.textBody
                    }
                    Text {
                        text: page.targetVersion
                        font.family: theme.fontFamily
                        font.pixelSize: 20
                        font.weight: Font.Bold
                        color: theme.brand
                    }
                }
            }
        }

        Item { Layout.preferredHeight: 10 }

        // Data that survives the operation (design: 以下数据将继续保留 + ✓ items, 2 columns x 3 rows,
        // 240px column pitch, 28px row pitch, on a #f9fcff card with a #9acdff border).
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 139
            Layout.minimumHeight: 139
            Layout.maximumHeight: 139
            radius: theme.radiusCard
            color: theme.cardBlue
            border.width: 1
            border.color: theme.cardBlueLine

            Column {
                id: retain
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                anchors.topMargin: 17
                spacing: 6

                Text {
                    text: qsTr("The following data will be kept")
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontSection
                    font.weight: Font.DemiBold
                    color: theme.text
                }

                Grid {
                    width: parent.width
                    columns: 2
                    columnSpacing: 0
                    rowSpacing: 4
                    Repeater {
                        model: page.retained
                        delegate: Row {
                            required property string modelData
                            width: 240
                            height: 24
                            spacing: 8
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "✓"
                                font.family: theme.fontFamily
                                font.pixelSize: theme.fontBody
                                font.weight: Font.Bold
                                color: theme.brand
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData
                                font.family: theme.fontFamily
                                font.pixelSize: theme.fontBody
                                color: theme.textBody
                            }
                        }
                    }
                }
            }
        }

        // Downgrade warning (design: 降级可能导致配置不兼容 + snapshot explanation + risk checkbox)
        Item { Layout.preferredHeight: 12; visible: page.mode === "downgrade" }

        Rectangle {
            visible: page.mode === "downgrade"
            Layout.fillWidth: true
            implicitHeight: warn.implicitHeight + 32
            radius: theme.radiusCard
            color: theme.warningSoft
            border.width: 1
            border.color: theme.warningLine

            Column {
                id: warn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 16
                spacing: 8

                Text {
                    text: qsTr("Downgrading may cause configuration incompatibility")
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontBody
                    font.weight: Font.DemiBold
                    color: theme.warningInk
                }
                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    lineHeight: 1.5
                    text: qsTr("A recoverable snapshot is created before installation. Configuration the old version cannot read is quarantined instead of being overwritten.")
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontBody
                    color: theme.text
                }
                Item { width: 1; height: 2 }
                UiCheck {
                    text: qsTr("I understand the risk and want to install the older version")
                    checked: page.riskAcknowledged
                    onToggled: page.riskToggled(!page.riskAcknowledged)
                }
            }
        }

        Item { Layout.fillHeight: true }

        RowLayout {
            Layout.fillWidth: true
            spacing: theme.btnGap
            Item { Layout.fillWidth: true }
            UiBtn { text: qsTr("Cancel"); onClicked: page.cancelRequested() }
            UiBtn {
                text: page.primaryText
                primary: true
                chevron: "right"
                enabledState: page.mode !== "downgrade" || page.riskAcknowledged
                onClicked: page.proceedRequested(page.mode)
            }
        }
    }
}
