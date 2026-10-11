import CoreImage
import MetalKit
import SwiftUI

/// Draws Core Image frames on the GPU, 60 times a second.
struct MetalPreview: UIViewRepresentable {
    let provider: (CGSize) -> CIImage?

    func makeCoordinator() -> Coordinator { Coordinator(provider: provider) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: Rendering.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.backgroundColor = .black
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.provider = provider
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var provider: (CGSize) -> CIImage?
        private let queue = Rendering.device.makeCommandQueue()

        init(provider: @escaping (CGSize) -> CIImage?) {
            self.provider = provider
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            let size = view.drawableSize
            guard size.width > 0, size.height > 0,
                  let image = provider(size),
                  let drawable = view.currentDrawable,
                  let commandBuffer = queue?.makeCommandBuffer()
            else { return }

            // Centre the (already fitted) image on a black background.
            let dx = (size.width - image.extent.width) / 2 - image.extent.minX
            let dy = (size.height - image.extent.height) / 2 - image.extent.minY
            let canvas = CGRect(origin: .zero, size: size)
            let output = image
                .transformed(by: CGAffineTransform(translationX: dx, y: dy))
                .composited(over: CIImage(color: .black).cropped(to: canvas))

            Rendering.context.render(output,
                                     to: drawable.texture,
                                     commandBuffer: commandBuffer,
                                     bounds: canvas,
                                     colorSpace: Rendering.sRGB)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
