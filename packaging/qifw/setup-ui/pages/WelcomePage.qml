// WelcomePage.qml
pragma ComponentBehavior: Bound
import QtQuick
import SetupUi

// First screen of a fresh install (design: 启动页). Two teal lines vertically centred in the content
// column (product name is the hero line), action row pinned to the bottom.
Item {
    id: page
    UiTheme { id: theme }

    width: theme.contentW
    height: theme.contentH

    signal nextRequested()
    signal cancelRequested()

    Column {
        id: headline
        anchors.horizontalCenter: parent.horizontalCenter
        // Design: the block is optically centred in the content column (measured ink 235..258 and
        // 281..309). The content column starts at y=36, so the centre offset is negative.
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: -8
        width: parent.width
        spacing: 12

        Text {
            width: headline.width
            text: qsTr("Welcome")
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontWelcome
            font.weight: theme.fontTitleWeight
            color: theme.brand
        }

        Text {
            width: headline.width
            text: qsTr("OrbbecSlicer Setup Wizard")
            wrapMode: Text.WordWrap
            font.family: theme.fontFamily
            font.pixelSize: theme.fontHero
            font.weight: theme.fontTitleWeight
            color: theme.brand
        }
    }

    // Action row pinned to the bottom (design: buttons occupy y 476..520 of the 540px window)
    Row {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: theme.btnGap

        UiBtn { text: qsTr("Cancel"); onClicked: page.cancelRequested() }
        UiBtn {
            text: qsTr("Next")
            primary: true
            chevron: "right"
            onClicked: page.nextRequested()
        }
    }
}
