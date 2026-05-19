import Metal
import QuartzCore
import UIKit
import SwiftUI

struct NativeMetalPresenterViewRepresenable: UIViewRepresentable {
    var onLayerReady: (UnsafeMutableRawPointer) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> NativeMetalPresenterView {
        let view = NativeMetalPresenterView(frame: .zero)
        let ptr = Unmanaged.passUnretained(view.metalLayer).toOpaque()
        onLayerReady(ptr)
        
        return view
    }

    func updateUIView(_ uiView: NativeMetalPresenterView, context: Context) {
        uiView.updateDrawableSize()
    }
}

final class NativeMetalPresenterView: UIView {
    override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    var metalLayer: CAMetalLayer {
        layer as! CAMetalLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        contentMode = .scaleAspectFit
        configureMetalLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = true
        backgroundColor = .black
        contentMode = .scaleAspectFit
        configureMetalLayer()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    func configureMetalLayer() {
        let layer = metalLayer
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = true
        layer.presentsWithTransaction = false
        layer.allowsNextDrawableTimeout = true
        layer.contentsGravity = .resizeAspect
        MetalHUDLayerConfigurator.apply(to: layer)
        PresentPacingLayerConfigurator.apply(to: layer)
        updateDrawableSize()
    }

    func updateDrawableSize() {
        let scale = window?.windowScene?.screen.scale ?? max(traitCollection.displayScale, 1)
        contentScaleFactor = scale
        metalLayer.contentsScale = scale

        let width = max(1.0, bounds.width * scale)
        let height = max(1.0, bounds.height * scale)
        metalLayer.drawableSize = CGSize(width: width, height: height)
    }
}
