// LicensePage.qml
pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import SetupUi

// License agreement (design: 许可协议). The text itself lives in resources/eula.txt (embedded as
// qrc:/eula.txt) so the legal copy can be replaced without touching QML; the page only scrolls it.
// main.cpp injects the file contents as the `eulaText` context property (XMLHttpRequest is blocked
// for qrc:/ by default), and the fallback below keeps the card meaningful if that ever fails.
// "Next" stays disabled until the acceptance box is checked.
Item {
    id: page
    UiTheme { id: theme }

    width: theme.contentW
    height: theme.contentH

    property bool accepted: false
    readonly property string eulaBody: (typeof eulaText !== "undefined" && eulaText !== null
                                        && String(eulaText).length > 0)
                                       ? String(eulaText)
                                       : qsTr("The license text could not be loaded. Please refer to the license file shipped with the installer.")

    signal acceptToggled(bool accepted)
    signal nextRequested()
    signal backRequested()
    signal cancelRequested()

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Text {
            Layout.fillWidth: true
            text: qsTr("License agreement")
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontTitle
            font.weight: theme.fontTitleWeight
            color: theme.brand
        }
        // Design: title ink 41..64, lead ink 86..99, card 116..421 (page y: 5 / 50 / 80).
        Item { Layout.preferredHeight: 18 }
        Text {
            Layout.fillWidth: true
            text: qsTr("Please read the license terms; you must accept them to continue.")
            wrapMode: Text.WordWrap
            lineHeight: 1.5
            font.family: theme.fontFamily
            // Measured on the design frame: the license lead line is 14px (the options / maintenance
            // leads are 16px; this page carries a longer sentence).
            font.pixelSize: theme.fontBody
            color: theme.textBody
        }
        Item { Layout.preferredHeight: 7 }

        // Agreement card (design: #EEEEEE, rx12, 442x305). The heading and the divider run edge to
        // edge, the scrollable body keeps the 20px inner padding.
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 180
            radius: theme.radiusLicenseCard
            color: theme.cardAlt
            clip: true

            Text {
                id: cardTitle
                x: 20
                y: 22
                width: parent.width - 40
                text: qsTr("OrbbecSlicer End User License Agreement")
                elide: Text.ElideRight
                font.family: theme.fontFamily
                font.pixelSize: theme.fontCardTitle
                font.weight: Font.DemiBold
                color: theme.text
            }

            Rectangle {
                id: divider
                y: 65
                width: parent.width
                height: 1
                color: theme.hairline
            }

            Flickable {
                id: flick
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: divider.bottom
                anchors.bottom: parent.bottom
                // The body keeps the design's 20px inner padding (text ink ends at x=896 of the
                // 442px card). The scroll bar is drawn separately below: Qt's built-in ScrollBar is
                // parented to the flickable, so it inherited this padding and sat 20px away from the
                // card edge with a track only as tall as the padded area.
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                anchors.topMargin: 20
                anchors.bottomMargin: 20
                clip: true
                contentWidth: width
                contentHeight: body.implicitHeight
                boundsBehavior: Flickable.StopAtBounds

                Text {
                    id: body
                    width: flick.width - 12
                    text: page.eulaBody
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    // Measured: em≈14 with a 23px baseline pitch (lineHeight 23/14).
                    lineHeight: 1.64
                    font.family: theme.fontFamily
                    font.pixelSize: theme.fontLabel
                    color: theme.textBody
                }
            }

            // Scroll bar measured on the 许可协议 frame: a 4px #bababa pill whose right edge stops
            // 4px short of the card's right edge, running from the divider down to the card bottom,
            // with a long handle (the frame shows 113px of a 238px track, i.e. ~47%).
            Item {
                id: barTrack
                anchors.right: parent.right
                anchors.rightMargin: 4
                anchors.top: divider.bottom
                anchors.bottom: parent.bottom
                width: 4
                visible: flick.contentHeight > flick.height + 0.5

                readonly property real scrollable: Math.max(1, flick.contentHeight - flick.height)
                readonly property real travel: Math.max(0, height - thumb.height)

                Rectangle {
                    id: thumb
                    width: 4
                    radius: 2
                    color: theme.scrollThumb
                    // Whichever is longer: the true visible/content ratio, or the design's 47% floor,
                    // so the handle stays as easy to grab as the design intends.
                    height: Math.min(barTrack.height,
                                     Math.max(barTrack.height * 0.47,
                                              barTrack.height * flick.height
                                              / Math.max(flick.height, flick.contentHeight)))
                    y: barTrack.travel * Math.max(0, Math.min(1, flick.contentY / barTrack.scrollable))

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        property real pressY: 0
                        property real pressContentY: 0
                        onPressed: (m) => {
                            pressY = m.y
                            pressContentY = flick.contentY
                        }
                        onPositionChanged: (m) => {
                            if (!pressed || barTrack.travel <= 0)
                                return
                            flick.contentY = Math.max(0, Math.min(barTrack.scrollable,
                                                                pressContentY
                                                                + (m.y - pressY) / barTrack.travel
                                                                  * barTrack.scrollable))
                        }
                    }
                }
            }
        }

        Item { Layout.preferredHeight: 15 }

        UiCheck {
            strong: true
            text: qsTr("I accept the license agreement")
            checked: page.accepted
            // The controller owns the flag (Main binds it back), so the page never writes it locally.
            onToggled: page.acceptToggled(!page.accepted)
        }

        Item { Layout.preferredHeight: 16 }

        RowLayout {
            Layout.fillWidth: true
            spacing: theme.btnGap
            Item { Layout.fillWidth: true }
            UiBtn { text: qsTr("Cancel"); onClicked: page.cancelRequested() }
            UiBtn { text: qsTr("Back"); chevron: "left"; onClicked: page.backRequested() }
            UiBtn {
                text: qsTr("Next")
                primary: true
                chevron: "right"
                enabledState: page.accepted
                onClicked: page.nextRequested()
            }
        }
    }
}
