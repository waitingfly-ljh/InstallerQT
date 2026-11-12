// UiScrollArea.qml
import QtQuick
import SetupUi

// Scrollable page body with the design's own scroll bar.
//
// The frames 卸载 / 降级安装 show a page whose content is taller than the viewport: a 4px #c4c4c4
// pill in the gutter right of the content column (window x=948..951, i.e. x=450 inside the page)
// running from 4px below the content top down to the content bottom. Qt's ScrollBar is not used
// because it draws its own styled track inside the item.
//
// Usage: UiScrollArea { anchors.fill: parent; Column { width: parent.width; ... } } — children are
// added to the scrolling content item, so `parent.width` is the content column width.
Item {
    id: area
    UiTheme { id: theme }

    default property alias contentData: inner.data

    readonly property int contentHeight: inner.height
    readonly property real scrollable: Math.max(0, contentHeight - height)
    readonly property bool needsScroll: scrollable > 0.5

    Flickable {
        id: flick
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: Math.max(height, area.contentHeight)
        boundsBehavior: Flickable.StopAtBounds
        interactive: area.needsScroll
        // Wheel scrolling only: the design has no visible track, so a plain flick is what the page
        // behaves like; keyboard-less kiosk users only have the wheel anyway.
        flickableDirection: Flickable.VerticalFlick

        Item {
            id: inner
            width: flick.width
            height: childrenRect.height
        }
    }

    // Page scroll bar (design x=948..951, y=40.., #c4c4c4).
    Item {
        id: bar
        x: theme.scrollBarX
        y: theme.scrollBarTop
        width: theme.scrollBarW
        height: area.height - theme.scrollBarTop
        visible: area.needsScroll

        readonly property real travel: Math.max(0, height - thumb.height)

        Rectangle {
            id: thumb
            width: theme.scrollBarW
            radius: 2
            color: theme.scrollThumbPage
            height: Math.min(bar.height,
                             Math.max(40, bar.height * area.height / Math.max(area.height, area.contentHeight)))
            y: bar.travel * Math.max(0, Math.min(1, flick.contentY / Math.max(1, area.scrollable)))

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
                    if (!pressed || bar.travel <= 0)
                        return
                    flick.contentY = Math.max(0, Math.min(area.scrollable,
                                                        pressContentY
                                                        + (m.y - pressY) / bar.travel * area.scrollable))
                }
            }
        }
    }
}
