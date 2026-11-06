import MetalKit
import simd
import SwiftSTEP

/// Shaded faces with the model's edges on top, both from the library's output. Faces use the
/// library's analytic normals and a camera-following headlight; edges are the sampled polylines.
final class Renderer: NSObject, MTKViewDelegate {

    private struct Uniforms {
        var viewProjection: simd_float4x4
        var color: SIMD4<Float>
        var light: SIMD4<Float>
        var ambient: Float
    }

    private struct SolidVertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
    }

    let camera = Camera()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let linePipeline: MTLRenderPipelineState
    private let solidPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    private var lineBuffer: MTLBuffer?
    private var lineVertexCount = 0
    private var solidBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0

    private var center = SIMD3<Float>.zero
    private var radius: Float = 1
    private var needsFit = false

    private let faceColor = SIMD4<Float>(0.55, 0.62, 0.72, 1)
    private let edgeColor = SIMD4<Float>(0.08, 0.09, 0.10, 1)
    // Faces sit a hair behind the edges drawn on them, so the edges win the depth test.
    private let depthBias: Float = 4
    private let depthBiasSlope: Float = 4

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0.90, green: 0.91, blue: 0.92, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true

        do {
            let library: MTLLibrary = try! device.makeDefaultLibrary(bundle: Bundle.module)

            let lineLayout = MTLVertexDescriptor()
            lineLayout.attributes[0].format = .float3
            lineLayout.attributes[0].offset = 0
            lineLayout.attributes[0].bufferIndex = 0
            lineLayout.layouts[0].stride = MemoryLayout<SIMD3<Float>>.stride

            let solidLayout = MTLVertexDescriptor()
            solidLayout.attributes[0].format = .float3
            solidLayout.attributes[0].offset = 0
            solidLayout.attributes[0].bufferIndex = 0
            solidLayout.attributes[1].format = .float3
            solidLayout.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
            solidLayout.attributes[1].bufferIndex = 0
            solidLayout.layouts[0].stride = MemoryLayout<SolidVertex>.stride

            func pipeline(vertex: String, fragment: String, layout: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: vertex)
                descriptor.fragmentFunction = library.makeFunction(name: fragment)
                descriptor.vertexDescriptor = layout
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
                descriptor.rasterSampleCount = view.sampleCount
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            linePipeline = try pipeline(vertex: "line_vertex", fragment: "line_fragment", layout: lineLayout)
            solidPipeline = try pipeline(vertex: "solid_vertex", fragment: "solid_fragment", layout: solidLayout)
        } catch {
            print("Metal setup failed: \(error)")
            return nil
        }

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else { return nil }

        self.device = device
        self.queue = queue
        self.depthState = depthState
        super.init()

        // A three-quarter view to start from.
        camera.orbit(yaw: -.pi / 4, pitch: .pi / 4)
    }

    // MARK: Model

    /// Replaces what is drawn. Pass `nil` to clear.
    func load(_ geometry: STEP.Geometry?) {
        lineBuffer = nil
        lineVertexCount = 0
        solidBuffer = nil
        indexBuffer = nil
        indexCount = 0
        guard let geometry else { return }

        // Edge points are Double in source coordinates; recentre on the workpiece corner before
        // dropping to Float, the same origin the library uses for its meshes.
        let model = geometry.edges
        let origin = model.bounds?.workpieceOrigin ?? .zero

        var lines: [SIMD3<Float>] = []
        for edge in model.edges {
            guard var previous = edge.points.first.map({ SIMD3<Float>($0 - origin) }) else { continue }
            for point in edge.points.dropFirst() {
                let current = SIMD3<Float>(point - origin)
                lines.append(previous)
                lines.append(current)
                previous = current
            }
        }

        // Meshes are relative to `surfaces.origin`; shift them onto the same origin as the edges.
        let shift = SIMD3<Float>(geometry.surfaces.origin - origin)
        var vertices: [SolidVertex] = []
        var indices: [UInt32] = []
        for mesh in geometry.surfaces.bodies {
            let base = UInt32(vertices.count)
            for (position, normal) in zip(mesh.positions, mesh.normals) {
                vertices.append(SolidVertex(position: position + shift, normal: normal))
            }
            indices.append(contentsOf: mesh.indices.map { $0 + base })
        }

        lineVertexCount = lines.count
        lineBuffer = makeBuffer(lines)
        solidBuffer = makeBuffer(vertices)
        indexBuffer = makeBuffer(indices)
        indexCount = indices.count

        if let bounds = model.bounds {
            center = SIMD3<Float>((bounds.min + bounds.max) / 2 - origin)
            radius = max(Float(simd_length(bounds.size) / 2), 1e-3)
        } else {
            center = .zero
            radius = 1
        }
        needsFit = true
    }

    /// Frames the whole model on the next draw.
    func fit() { needsFit = true }

    private func makeBuffer<T>(_ array: [T]) -> MTLBuffer? {
        guard !array.isEmpty else { return nil }
        return device.makeBuffer(bytes: array, length: array.count * MemoryLayout<T>.stride, options: .storageModeShared)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        let size = view.drawableSize
        guard size.width > 0, size.height > 0,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        camera.aspect = Float(size.width / size.height)
        if needsFit {
            camera.fit(center: center, radius: radius)
            needsFit = false
        }
        let viewProjection = camera.viewProjection()
        encoder.setDepthStencilState(depthState)

        if let solidBuffer, let indexBuffer, indexCount > 0 {
            var uniforms = Uniforms(viewProjection: viewProjection, color: faceColor,
                                    light: SIMD4<Float>(camera.headlight, 0), ambient: 0.5)
            encoder.setRenderPipelineState(solidPipeline)
            encoder.setCullMode(.none)   // two-sided: a flipped face shows as an ambient patch, not a hole
            encoder.setDepthBias(depthBias, slopeScale: depthBiasSlope, clamp: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setVertexBuffer(solidBuffer, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                          indexBuffer: indexBuffer, indexBufferOffset: 0)
            encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
        }

        if let lineBuffer, lineVertexCount > 0 {
            var uniforms = Uniforms(viewProjection: viewProjection, color: edgeColor,
                                    light: .zero, ambient: 1)
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineVertexCount)
        }

        encoder.endEncoding()
        if let drawable = view.currentDrawable { commandBuffer.present(drawable) }
        commandBuffer.commit()
    }
}
