import CoreGraphics

public enum OverlayShape: String, CaseIterable, Sendable {
    case circle, rectangle
}

public enum OverlayCorner: String, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
}

/// Camera overlay settings; read on every frame so changes apply immediately.
public struct OverlayConfig: Equatable, Sendable {
    public var enabled: Bool
    public var shape: OverlayShape
    public var corner: OverlayCorner
    /// Overlay height as a fraction of the shorter side of the video.
    public var size: Double
    public var mirror: Bool

    public init(enabled: Bool = false, shape: OverlayShape = .circle, corner: OverlayCorner = .bottomRight,
                size: Double = 0.22, mirror: Bool = true) {
        self.enabled = enabled
        self.shape = shape
        self.corner = corner
        self.size = size
        self.mirror = mirror
    }
}

public enum OverlayGeometry {
    /// Margin from the video edge, as a fraction of the shorter side.
    public static let marginFraction = 0.025

    /// Overlay rectangle in Core Image coordinates (origin bottom-left), whole pixels.
    public static func rect(canvas: CGSize, config: OverlayConfig) -> CGRect {
        let short = min(canvas.width, canvas.height)
        let h = (short * config.size).rounded()
        let w = config.shape == .circle ? h : (h * 16 / 9).rounded()
        let m = (short * marginFraction).rounded()
        let x: CGFloat
        let y: CGFloat
        switch config.corner {
        case .topLeft: x = m; y = canvas.height - m - h
        case .topRight: x = canvas.width - m - w; y = canvas.height - m - h
        case .bottomLeft: x = m; y = m
        case .bottomRight: x = canvas.width - m - w; y = m
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Centered crop of a source of size `source` to the aspect ratio of `target`.
    public static func aspectCrop(source: CGSize, target: CGSize) -> CGRect {
        let targetAspect = target.width / target.height
        let sourceAspect = source.width / source.height
        if sourceAspect > targetAspect {
            let w = source.height * targetAspect
            return CGRect(x: (source.width - w) / 2, y: 0, width: w, height: source.height)
        } else {
            let h = source.width / targetAspect
            return CGRect(x: 0, y: (source.height - h) / 2, width: source.width, height: h)
        }
    }
}
