// SideGlow.qml
import QtQuick

// Radial glow at the sidebar's top-left, corresponding to the design mockup:
//   radial-gradient(circle at 10% 18%, rgba(55,192,184,.35), transparent 35%)
// Drawn on a 228×300 canvas (sidebar width × sidebar height at a 900px viewport; AppFrame stretches to actual size),
// center (10%, 18%), gradient radius = farthest corner from the center (CSS farthest-corner).
//
// Why not stack Rectangles into concentric circles: rounded rectangles reveal "steps". Here the radial gradient is computed per pixel, but
// alpha is quantized into 14 levels between 34..255 — full-precision 8-bit alpha produces concentric rings under software rendering,
// while after quantization the adjacent level difference is 14/255, invisible to the eye.
//
// At runtime resources/glow.png (qrc:/glow.png) is shown; this Canvas is only a visual reference for the same formula:
// after changing the alphaAt formula, regenerate glow.png accordingly, or the image and code will diverge.
Item {
    id: glow
    width: 228
    height: 300

    readonly property color ink: Qt.rgba(55 / 255, 192 / 255, 184 / 255, 0.35)
    readonly property real cx: width * 0.10
    readonly property real cy: height * 0.18
    readonly property real farCorner: Math.max(Math.sqrt(Math.pow(width - cx, 2) + Math.pow(cy, 2)),
                                               Math.sqrt(Math.pow(cx, 2) + Math.pow(height - cy, 2)))

    // Return the alpha (0..255) at this point; the generator and Canvas preview share the same algorithm.
    function alphaAt(px, py) {
        const d = Math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy)) / farCorner
        const fade = Math.max(0, 1 - d)                  // linear falloff
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
