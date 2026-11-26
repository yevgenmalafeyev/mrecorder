import CoreImage
import CoreVideo
import Metal
import RecorderCore

/// Builds output frames with Core Image on the GPU: places one or more screen frames on a canvas
/// (side by side, scaled, or aspect-fit for a resized window) and draws the camera overlay on top.
final class Compositor {
    struct Layer {
        let buffer: CVPixelBuffer
        let rect: CGRect
        /// Optional part of the buffer to use (Core Image coordinates).
        var crop: CGRect? = nil
    }

    private let context: CIContext
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private var masks: [String: CIImage] = [:]

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
    }

    /// Renders the layers (and the camera, if given) into a new buffer from `pool`.
    func compose(layers: [Layer], canvas: CGSize, camera: CVPixelBuffer?, config: OverlayConfig,
                 pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        let bounds = CGRect(origin: .zero, size: canvas)

        var result = CIImage(color: .black).cropped(to: bounds)
        for layer in layers {
            var img = CIImage(cvPixelBuffer: layer.buffer)
            if let crop = layer.crop {
                img = img.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            }
            let size = img.extent.size
            let target = size == layer.rect.size ? layer.rect : CanvasLayout.aspectFit(size, in: layer.rect)
            img = img.transformed(by: CGAffineTransform(scaleX: target.width / size.width, y: target.height / size.height)
                .concatenating(CGAffineTransform(translationX: target.minX, y: target.minY)))
            result = img.cropped(to: target).composited(over: result)
        }
        if let camera { result = cameraLayer(camera, canvas: canvas, config: config).composited(over: result) }

        if let first = layers.first { CVBufferPropagateAttachments(first.buffer, out) }
        context.render(result, to: out, bounds: bounds, colorSpace: outputColorSpace)
        return out
    }

    private func cameraLayer(_ camera: CVPixelBuffer, canvas: CGSize, config: OverlayConfig) -> CIImage {
        let target = OverlayGeometry.rect(canvas: canvas, config: config)
        var cam = CIImage(cvPixelBuffer: camera)
        if config.mirror {
            cam = cam.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -cam.extent.width, y: 0))
        }
        let crop = OverlayGeometry.aspectCrop(source: cam.extent.size, target: target.size)
        cam = cam.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let scale = target.height / crop.height
        cam = cam.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
            .cropped(to: target)
        return cam.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask(for: target, shape: config.shape),
        ])
    }

    /// Anti-aliased circle or rounded-rectangle alpha mask, cached per size and position.
    private func mask(for rect: CGRect, shape: OverlayShape) -> CIImage {
        let key = "\(shape.rawValue) \(rect)"
        if let cached = masks[key] { return cached }
        let image: CIImage
        switch shape {
        case .circle:
            let r = rect.width / 2
            image = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: rect.midX, y: rect.midY),
                "inputRadius0": max(0, r - 1.5),
                "inputRadius1": r,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.clear,
            ])!.outputImage!.cropped(to: rect)
        case .rectangle:
            image = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: rect),
                "inputRadius": rect.height * 0.08,
                "inputColor": CIColor.white,
            ])!.outputImage!
        }
        if masks.count > 16 { masks.removeAll() }
        masks[key] = image
        return image
    }
}
