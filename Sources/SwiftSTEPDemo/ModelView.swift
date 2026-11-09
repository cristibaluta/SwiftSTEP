import SwiftUI
import MetalKit
import SwiftSTEP

/// The canvas. Mouse mapping, same as the Stratum CNC app:
/// - drag: orbit (turntable around Z)
/// - shift/option + drag, right or middle drag: pan
/// - scroll wheel / two-finger scroll, pinch: zoom towards the cursor
/// - double click: fit the model
struct ModelView: NSViewRepresentable {
    let document: Document?
    /// Bodies the list has switched off, and the one it has selected.
    var hidden: Set<STEP.BodyID> = []
    var selected: STEP.BodyID?

    final class Coordinator {
        var renderer: Renderer?
        var loadedID: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CanvasView {
        let view = CanvasView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        if let renderer = Renderer(view: view) {
            context.coordinator.renderer = renderer   // the view's delegate is weak
            view.renderer = renderer
            view.delegate = renderer
        }
        return view
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.loadedID != document?.id {
            coordinator.loadedID = document?.id
            coordinator.renderer?.load(document)
        }
        coordinator.renderer?.setVisibility(hidden: hidden, selected: selected)
        view.needsDisplay = true
    }
}

final class CanvasView: MTKView {
    weak var renderer: Renderer?

    override var acceptsFirstResponder: Bool { true }

    // The drag events follow the view that took the mouse-down.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            renderer?.fit()
            needsDisplay = true
        }
    }
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
            pan(event)
        } else {
            // AppKit deltas are y-down; the camera takes y-up.
            renderer?.camera.orbit(yaw: -Float(event.deltaX) * 0.005, pitch: -Float(event.deltaY) * 0.005)
            needsDisplay = true
        }
    }
    override func rightMouseDragged(with event: NSEvent) { pan(event) }
    override func otherMouseDragged(with event: NSEvent) { pan(event) }

    override func scrollWheel(with event: NSEvent) {
        let rate: Float = event.hasPreciseScrollingDeltas ? 0.004 : 0.05
        zoom(by: exp(-Float(event.scrollingDeltaY) * rate), at: event.locationInWindow)
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 - Float(event.magnification), at: event.locationInWindow)
    }

    private func pan(_ event: NSEvent) {
        guard bounds.height > 0 else { return }
        renderer?.camera.pan(by: SIMD2<Float>(Float(event.deltaX), -Float(event.deltaY)),
                             viewportHeight: Float(bounds.height))
        needsDisplay = true
    }

    private func zoom(by factor: Float, at windowPoint: NSPoint) {
        guard let camera = renderer?.camera, bounds.width > 0, bounds.height > 0, factor.isFinite, factor > 0 else { return }
        let point = convert(windowPoint, from: nil)
        let ndc = SIMD2<Float>(Float(point.x / bounds.width) * 2 - 1, Float(point.y / bounds.height) * 2 - 1)
        camera.zoom(to: camera.halfHeight * factor, towards: ndc)
        needsDisplay = true
    }
}
