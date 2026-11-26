import CoreGraphics

/// Layout of several screens side by side in one video.
public struct CanvasLayout: Equatable, Sendable {
    public let canvas: CGSize
    /// One rect per source, left to right, in Core Image coordinates (origin bottom-left).
    public let slots: [CGRect]

    /// Scales every source to a common height and places them left to right.
    /// - Parameters:
    ///   - sources: native pixel sizes, in left-to-right order.
    ///   - height: requested common height; never above the tallest source (no upscaling past native).
    public static func sideBySide(sources: [CGSize], height requested: Int) -> CanvasLayout {
        let tallest = sources.map(\.height).max() ?? CGFloat(requested)
        let h = CGFloat(FrameGrid.even(Double(min(CGFloat(requested), tallest))))
        var x: CGFloat = 0
        var slots: [CGRect] = []
        for s in sources {
            let w = CGFloat(FrameGrid.even(Double(s.width * h / s.height)))
            slots.append(CGRect(x: x, y: 0, width: w, height: h))
            x += w
        }
        return CanvasLayout(canvas: CGSize(width: x, height: h), slots: slots)
    }

    /// Scales a size down so its shorter side is at most `maxShortSide` (0 = no cap). Even dimensions.
    public static func capped(_ size: CGSize, maxShortSide: Int) -> CGSize {
        var w = Double(size.width), h = Double(size.height)
        if maxShortSide > 0, min(w, h) > Double(maxShortSide) {
            let f = Double(maxShortSide) / min(w, h)
            w *= f
            h *= f
        }
        return CGSize(width: FrameGrid.even(w), height: FrameGrid.even(h))
    }

    /// Scales a size down (if needed) so neither side exceeds `maxDimension`. Even dimensions.
    public static func fit(_ size: CGSize, maxDimension: Int) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > CGFloat(maxDimension) else { return size }
        let f = CGFloat(maxDimension) / longest
        return CGSize(width: FrameGrid.even(Double(size.width * f)), height: FrameGrid.even(Double(size.height * f)))
    }

    /// Side-by-side layout whose canvas also fits within `maxDimension` (e.g. 4096 for H.264).
    public static func sideBySide(sources: [CGSize], height: Int, maxDimension: Int) -> CanvasLayout {
        var layout = sideBySide(sources: sources, height: height)
        var h = Int(layout.canvas.height)
        while max(layout.canvas.width, layout.canvas.height) > CGFloat(maxDimension), h > 2 {
            h = Int(Double(h) * Double(maxDimension) / Double(max(layout.canvas.width, layout.canvas.height)))
            layout = sideBySide(sources: sources, height: h)
        }
        return layout
    }

    /// Aspect-fit `content` inside `box`, centered.
    public static func aspectFit(_ content: CGSize, in box: CGRect) -> CGRect {
        let s = min(box.width / content.width, box.height / content.height)
        let w = content.width * s, h = content.height * s
        return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }

    /// In separate-files mode, which file (by left-to-right index) gets the camera overlay:
    /// left corners go to the leftmost screen, right corners to the rightmost.
    public static func overlayTarget(corner: OverlayCorner, count: Int) -> Int {
        switch corner {
        case .topLeft, .bottomLeft: return 0
        case .topRight, .bottomRight: return max(0, count - 1)
        }
    }
}
