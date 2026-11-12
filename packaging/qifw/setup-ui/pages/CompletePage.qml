// CompletePage.qml
import QtQuick
import QtQuick.Layouts
import SetupUi

// Complete page: completion icon + result copy + launch/finish.
// Also used for all three completion states: install, repair/upgrade/downgrade, and uninstall (title and button text are supplied externally).
//
// Geometry from the frames (all measured, content column starts at window y=36):
//   安装完成  icon 60x60 at 200..259, title ink 275..303 (30px), description ink 320..337 (16px),
//            one 124x44 button at 476..519.
//   卸载完成  same 137px icon/title/description group but 53px higher, followed by a 80px tinted
//            card at 313..392 and two buttons.
// The group is centred on window y=269 in both cases, i.e. 9px above the centre of the content area.
Item {
    id: page

    UiTheme { id: theme }
    width: theme.contentW
    height: theme.contentH
    property string title: qsTr("Installation complete")
    property string description: qsTr("OrbbecSlicer is ready.")
    property string primaryText: qsTr("Launch now")
    property bool showSecondary: false
    property string secondaryText: ""
    // Optional tinted card under the description (design: the "sensitive credentials cleared" note
    // on 卸载完成). Empty title hides it.
    property string cardTitle: ""
    property string cardBody: ""
    property bool launchEnabled: true
    signal primaryAction()
    signal secondaryAction()

    Column {
        id: block
        anchors.horizontalCenter: parent.horizontalCenter
        // Designed anchor is the icon top: window y=191 (install/upgrade) and 147 (uninstall, which
        // carries the 80px note card) — content area starts at window y=36, so the margins are 155/111.
        // Anchoring the top (not the centre) keeps the icon fixed when the note card grows for a
        // two-line body in English.
        anchors.top: parent.top
        anchors.topMargin: page.cardTitle.length > 0 ? 111 : 155
        width: parent.width
        spacing: 0

        // Completion icon: 60px teal disc with a vertical gradient and a white 40x26 check
        // (drawn as two strokes so the mark keeps the design's size at any font).
        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 60
            height: 60

            Rectangle {
                anchors.fill: parent
                radius: 30
                gradient: Gradient {
                    GradientStop { position: 0.0; color: theme.completeIconTop }
                    GradientStop { position: 1.0; color: theme.completeIconBottom }
                }
            }
            Rectangle {
                x: 20.5
                y: 33
                width: 4
                height: 18
                radius: 2
                rotation: 42.7
                color: theme.white
            }
            Rectangle {
                x: 40
                y: 11.3
                width: 4
                height: 35.4
                radius: 2
                rotation: -42.7
                color: theme.white
            }
        }
        // Design (升级完成 / 卸载完成): icon bottom 250/206 -> title ink 266/222 (16px gap) and
        // title ink bottom 295/251 -> subtitle ink 311.6/267.6 (16.6px gap); the tinted card starts
        // 30px under the subtitle box. The gaps are box-to-box here because the ink starts a few px
        // inside its 28px/15px line box: 13 / 16.5 / 30.
        Item { width: 1; height: 13 }

        Item {
            width: block.width
            height: 29
            Text {
                anchors.fill: parent
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: page.title
                wrapMode: Text.WordWrap
                font.family: theme.fontFamily
                font.pixelSize: theme.fontHero
                font.weight: theme.fontTitleWeight
                color: theme.brand
            }
        }
        Item { width: 1; height: 16.5 }

        Item {
            width: block.width
            height: 18
            Text {
                anchors.fill: parent
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: page.description
                wrapMode: Text.WordWrap
                font.family: theme.fontFamily
                // Measured: the completion subtitle ink is 17.5 high, em≈15..16.
                font.pixelSize: theme.fontValue
                color: theme.textFaint
            }
        }

        // Tinted note card (design: 80px tall, 16px title ink at +19, 12px body ink at +50,
        // 14px inner padding, #f2f9f9 fill with a brand border).
        Item { width: 1; height: 30; visible: page.cardTitle.length > 0 }
        UiNoteCard {
            visible: page.cardTitle.length > 0
            width: block.width
            height: implicitHeight
            title: page.cardTitle
            body: page.cardBody
        }
    }

    // Action row pinned to the bottom (design: buttons occupy y 476..519 of the 540px window).
    Row {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: theme.btnGap
        UiBtn {
            visible: page.showSecondary
            text: page.secondaryText
            onClicked: page.secondaryAction()
        }
        UiBtn {
            text: page.primaryText
            primary: true
            enabledState: page.launchEnabled
            onClicked: page.primaryAction()
        }
    }
}
