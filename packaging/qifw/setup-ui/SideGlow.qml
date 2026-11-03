// SideGlow.qml
import QtQuick

// 侧栏左上角的径向光斑，对应评审稿：
//   radial-gradient(circle at 10% 18%, rgba(55,192,184,.35), transparent 35%)
// 画在 228×300 的画布上（侧栏宽 × 900px 视口下侧栏高；AppFrame 按实际尺寸拉伸），
// 圆心 (10%, 18%)，渐变半径 = 离圆心最远的角（CSS 的 farthest-corner）。
//
// 为什么不用 Rectangle 拼同心圆：圆角矩形叠起来会露出"台阶"。这里逐像素算径向渐变，但
// 透明度只在 34..255 之间按 14 档量化——全精度的 8 位 alpha 在软件渲染下会出现同心环，
// 量化后相邻档差 14/255，肉眼看不出。
//
// 运行时显示的是 resources/glow.png（qrc:/glow.png），这张 Canvas 只是同一公式的可视化参考：
// 改了 alphaAt 的公式后要按它重新生成 glow.png，否则图像和代码会对不上。
Item {
    id: glow
    width: 228
    height: 300

    readonly property color ink: Qt.rgba(55 / 255, 192 / 255, 184 / 255, 0.35)
    readonly property real cx: width * 0.10
    readonly property real cy: height * 0.18
    readonly property real farCorner: Math.max(Math.sqrt(Math.pow(width - cx, 2) + Math.pow(cy, 2)),
                                               Math.sqrt(Math.pow(cx, 2) + Math.pow(height - cy, 2)))

    // 返回这一点的 alpha（0..255），生成器与 Canvas 预览共用同一份算法。
    function alphaAt(px, py) {
        const d = Math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy)) / farCorner
        const fade = Math.max(0, 1 - d)                  // 线性收尾
        return Math.min(255, 34 + Math.round(fade * 0.35 * (255 - 34) / 14) * 14)
    }

    Canvas {
        anchors.fill: parent
        contextType: "2d"
        renderTarget: Canvas.Image
        antialiasing: false
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            const img = ctx.createImageData(width, height)
            const data = img.data
            const r = Math.round(glow.ink.r * 255), g = Math.round(glow.ink.g * 255)
            const b = Math.round(glow.ink.b * 255)
            for (let y = 0; y < height; ++y) {
                for (let x = 0; x < width; ++x) {
                    const i = (y * width + x) * 4
                    data[i] = r
                    data[i + 1] = g
                    data[i + 2] = b
                    data[i + 3] = glow.alphaAt(x + 0.5, y + 0.5)
                }
            }
            ctx.putImageData(img, 0, 0)
        }
    }
}
