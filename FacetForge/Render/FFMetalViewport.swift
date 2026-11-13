import Foundation
import MetalKit
import QuartzCore
import simd
import SwiftUI
import UIKit

/// One vertex of the viewport's line list. The memory layout is deliberately
/// shared with the Metal shader below: `SIMD3<Float>` occupies 16 bytes, so
/// `color` starts at byte 16 exactly as it does in MSL.
struct FFLineVertex: Equatable {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
}

/// Rolling frame statistics for the viewport overlay. The window is one
/// second; the first frame opens the window and the following frames count
/// into it, so 60 frames in one second reports exactly 60 fps.
struct FFFrameStatistics: Equatable, Sendable {
    private(set) var frameCount = 0
    private(set) var averageFPS = 0.0
    /// Wall time between the last two accepted frames. Phase 21's overlay reads
    /// it directly so a slow frame is visible even when the one-second FPS
    /// window still averages sixty.
    private(set) var lastFrameMilliseconds = 0.0

    private var windowStart: Double?
    private var framesInWindow = 0
    private var lastFrameTime: Double?

    mutating func record(frameAt time: Double) {
        guard time.isFinite else { return }
        if let last = lastFrameTime {
            if time <= last { return }
            lastFrameMilliseconds = (time - last) * 1_000
        }
        lastFrameTime = time
        frameCount += 1

        guard let start = windowStart else {
            windowStart = time
            framesInWindow = 0
            return
        }

        framesInWindow += 1
        let elapsed = time - start
        guard elapsed >= 1 else { return }

        averageFPS = Double(framesInWindow) / elapsed
        windowStart = time
        framesInWindow = 0
    }
}

/// Deterministic line geometry for the empty-scene viewport. The grid lies in
/// the XZ plane and the three world axes are drawn on top of it.
enum FFViewportGeometry {
    /// Phase 11 sets the modelling grid to 1 mm with a 40 mm half-extent and a
    /// major line every 10 mm. The scale bar and the grid share the millimetre
    /// model, so a line is always one real millimetre apart.
    static let defaultExtent = 40.0
    static let defaultSpacing = 1.0

    static let minorColor = SIMD4<Float>(0.30, 0.33, 0.38, 1)
    static let majorColor = SIMD4<Float>(0.44, 0.48, 0.55, 1)
    static let xAxisColor = SIMD4<Float>(0.93, 0.33, 0.30, 1)
    static let yAxisColor = SIMD4<Float>(0.40, 0.88, 0.46, 1)
    static let zAxisColor = SIMD4<Float>(0.32, 0.56, 0.96, 1)

    /// Returns a line-list vertex array. Every pair of vertices is one line.
    static func gridAndAxes(
        extent: Double = defaultExtent,
        spacing: Double = defaultSpacing
    ) -> [FFLineVertex] {
        guard extent.isFinite, spacing.isFinite, extent > 0, spacing > 0 else {
            return []
        }
        let stepCount = Int((extent / spacing).rounded())
        guard stepCount > 0 else { return [] }

        var vertices: [FFLineVertex] = []
        vertices.reserveCapacity(stepCount * 8 + 6)

        for index in -stepCount...stepCount where index != 0 {
            let coordinate = Double(index) * spacing
            let color = index % 10 == 0 ? majorColor : minorColor
            appendLine(
                from: Vec3(x: coordinate, y: 0, z: -extent),
                to: Vec3(x: coordinate, y: 0, z: extent),
                color: color,
                into: &vertices
            )
            appendLine(
                from: Vec3(x: -extent, y: 0, z: coordinate),
                to: Vec3(x: extent, y: 0, z: coordinate),
                color: color,
                into: &vertices
            )
        }

        appendLine(
            from: Vec3(x: -extent, y: 0, z: 0),
            to: Vec3(x: extent, y: 0, z: 0),
            color: xAxisColor,
            into: &vertices
        )
        appendLine(
            from: Vec3(x: 0, y: 0, z: 0),
            to: Vec3(x: 0, y: extent, z: 0),
            color: yAxisColor,
            into: &vertices
        )
        appendLine(
            from: Vec3(x: 0, y: 0, z: -extent),
            to: Vec3(x: 0, y: 0, z: extent),
            color: zAxisColor,
            into: &vertices
        )

        return vertices
    }

    private static func appendLine(
        from start: Vec3,
        to end: Vec3,
        color: SIMD4<Float>,
        into vertices: inout [FFLineVertex]
    ) {
        vertices.append(FFLineVertex(
            position: SIMD3<Float>(Float(start.x), Float(start.y), Float(start.z)),
            color: color
        ))
        vertices.append(FFLineVertex(
            position: SIMD3<Float>(Float(end.x), Float(end.y), Float(end.z)),
            color: color
        ))
    }
}

/// A readback used by the offscreen renderer test. Pixels are BGRA8 in sRGB,
/// matching the viewport's `.bgra8Unorm_srgb` color attachment.
struct FFViewportReadback: Equatable {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

/// Per-node GPU buffers. Kept next to the renderer so a scene swap does not
/// re-upload a mesh whose geometry has not changed.
private struct FFMeshGPUBuffer {
    let vertices: MTLBuffer
    let indices: MTLBuffer
    /// Three line segments per triangle, used by the edge and wireframe
    /// passes. Built with the mesh buffer and reused every frame.
    let edges: MTLBuffer
    let indexCount: Int
    let edgeIndexCount: Int
    let vertexCount: Int
    let triangleCount: Int
    /// Content signature for a face part; zero for a whole-node buffer.
    let signature: UInt64
}

/// The mesh uniforms. The layout mirrors `FFMeshUniforms` in the shader below
/// exactly: three 64-byte matrices, then five 16-byte vectors.
private struct FFMeshUniforms {
    var model: simd_float4x4
    var viewProjection: simd_float4x4
    var normalMatrix: simd_float4x4
    var baseColor: SIMD4<Float>
    var cameraPosition: SIMD4<Float>
    var material: SIMD4<Float>
    var shadow: SIMD4<Float>
    var lightDirection: SIMD4<Float>
    var viewport: SIMD4<Float>
    var overlay: SIMD4<Float>
}

/// Owns the Metal device, the line and mesh pipelines and the immutable grid
/// buffer.
///
/// Phase 13 adds the shaded mesh pass, the selected-node outline and a soft
/// ground shadow on top of the Phase 9 line pass. The offscreen entry point
/// exists to prove the pipelines rasterise real pixels in CI, not just that the
/// app launched.
final class FFMetalViewportRenderer {
    static let preferredSampleCount = 4
    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm_srgb
    static let depthPixelFormat: MTLPixelFormat = .depth32Float
    static let clearColor = MTLClearColor(red: 0.055, green: 0.062, blue: 0.078, alpha: 1)

    static func clearColor(for mode: FFDisplayMode) -> MTLClearColor {
        let background = mode.background
        return MTLClearColor(
            red: background.red,
            green: background.green,
            blue: background.blue,
            alpha: 1
        )
    }

    let device: MTLDevice
    let pixelFormat: MTLPixelFormat
    let sampleCount: Int
    let lineCount: Int

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let meshPipelineState: MTLRenderPipelineState
    private let edgePipelineState: MTLRenderPipelineState
    private let outlinePipelineState: MTLRenderPipelineState
    private let shadowPipelineState: MTLRenderPipelineState
    private let ghostPipelineState: MTLRenderPipelineState
    private let pickPipelineState: MTLRenderPipelineState
    private let meshDepthState: MTLDepthStencilState
    private let edgeDepthState: MTLDepthStencilState
    private let outlineDepthState: MTLDepthStencilState
    private let shadowDepthState: MTLDepthStencilState
    private let ghostDepthState: MTLDepthStencilState
    private let vertexBuffer: MTLBuffer
    private struct FFMeshBufferKey: Hashable {
        let nodeID: UUID
        let partID: UUID?
    }
    private var meshBuffers: [FFMeshBufferKey: FFMeshGPUBuffer] = [:]
    private(set) var statistics = FFFrameStatistics()
    /// Draw calls and triangles submitted by the last encoded pass. Phase 21's
    /// overlay and its exact-count test read this; the counters are incremented
    /// at each draw the encoder issues, so they describe the frame that was
    /// actually sent to Metal rather than a parallel estimate.
    private(set) var lastCounters = FFRenderCounters()
    /// Draw calls in the last frame (kept as the protocol's name).
    private(set) var drawCallCount = 0
    private(set) var lastCommandBufferError: String?
    private(set) var lastSubmitMilliseconds = 0.0

    init?(
        device providedDevice: MTLDevice? = MTLCreateSystemDefaultDevice(),
        pixelFormat: MTLPixelFormat = FFMetalViewportRenderer.colorPixelFormat,
        sampleCount: Int = FFMetalViewportRenderer.preferredSampleCount
    ) {
        guard let device = providedDevice ?? MTLCreateSystemDefaultDevice() else {
            return nil
        }
        guard sampleCount > 0, sampleCount <= 8,
              device.supportsTextureSampleCount(sampleCount)
        else { return nil }
        guard let commandQueue = device.makeCommandQueue() else { return nil }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            return nil
        }
        guard let vertexFunction = library.makeFunction(name: "ff_vertex"),
              let fragmentFunction = library.makeFunction(name: "ff_fragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "FacetForge viewport lines"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = sampleCount
        descriptor.depthAttachmentPixelFormat = Self.depthPixelFormat
        descriptor.colorAttachments[0].pixelFormat = pixelFormat

        let pipelineState: MTLRenderPipelineState
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }

        func makePipeline(
            label: String,
            vertex: String,
            fragment: String,
            blending: Bool = false
        ) -> MTLRenderPipelineState? {
            guard let vertexFunction = library.makeFunction(name: vertex),
                  let fragmentFunction = library.makeFunction(name: fragment)
            else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = label
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.rasterSampleCount = sampleCount
            descriptor.depthAttachmentPixelFormat = Self.depthPixelFormat
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            if blending {
                let attachment = descriptor.colorAttachments[0]
                attachment?.isBlendingEnabled = true
                attachment?.rgbBlendOperation = .add
                attachment?.sourceRGBBlendFactor = .sourceAlpha
                attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment?.sourceAlphaBlendFactor = .one
                attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        guard let meshPipelineState = makePipeline(
            label: "FacetForge viewport meshes",
            vertex: "ff_mesh_vertex",
            fragment: "ff_mesh_fragment"
        ), let edgePipelineState = makePipeline(
            label: "FacetForge viewport edges",
            vertex: "ff_edge_vertex",
            fragment: "ff_edge_fragment"
        ), let outlinePipelineState = makePipeline(
            label: "FacetForge viewport selection outline",
            vertex: "ff_outline_vertex",
            fragment: "ff_outline_fragment"
        ), let shadowPipelineState = makePipeline(
            label: "FacetForge viewport ground shadow",
            vertex: "ff_shadow_vertex",
            fragment: "ff_shadow_fragment",
            blending: true
        ), let ghostPipelineState = makePipeline(
            label: "FacetForge viewport preview ghost",
            vertex: "ff_mesh_vertex",
            fragment: "ff_ghost_fragment",
            blending: true
        ) else { return nil }

        guard let pickVertexFunction = library.makeFunction(name: "ff_pick_vertex"),
              let pickFragmentFunction = library.makeFunction(name: "ff_pick_fragment")
        else { return nil }
        let pickDescriptor = MTLRenderPipelineDescriptor()
        pickDescriptor.label = "FacetForge viewport picking"
        pickDescriptor.vertexFunction = pickVertexFunction
        pickDescriptor.fragmentFunction = pickFragmentFunction
        pickDescriptor.rasterSampleCount = 1
        pickDescriptor.depthAttachmentPixelFormat = Self.depthPixelFormat
        pickDescriptor.colorAttachments[0].pixelFormat = .r32Uint
        guard let pickPipelineState = try? device.makeRenderPipelineState(descriptor: pickDescriptor)
        else { return nil }

        func makeDepthState(
            label: String,
            compare: MTLCompareFunction,
            write: Bool
        ) -> MTLDepthStencilState? {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.label = label
            descriptor.depthCompareFunction = compare
            descriptor.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: descriptor)
        }

        guard let depthState = makeDepthState(
            label: "FacetForge viewport depth",
            compare: .lessEqual,
            write: true
        ), let meshDepthState = makeDepthState(
            label: "FacetForge viewport mesh depth",
            compare: .less,
            write: true
        ), let edgeDepthState = makeDepthState(
            label: "FacetForge viewport edge depth",
            compare: .lessEqual,
            write: false
        ), let outlineDepthState = makeDepthState(
            label: "FacetForge viewport outline depth",
            compare: .lessEqual,
            write: false
        ), let shadowDepthState = makeDepthState(
            label: "FacetForge viewport shadow depth",
            compare: .always,
            write: false
        ), let ghostDepthState = makeDepthState(
            label: "FacetForge viewport preview depth",
            compare: .lessEqual,
            write: false
        ) else { return nil }

        let vertices = FFViewportGeometry.gridAndAxes()
        guard !vertices.isEmpty else { return nil }
        let buffer: MTLBuffer? = vertices.withUnsafeBytes { rawBuffer -> MTLBuffer? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: rawBuffer.count,
                options: .storageModeShared
            )
        }
        guard let vertexBuffer = buffer else { return nil }

        self.device = device
        self.pixelFormat = pixelFormat
        self.sampleCount = sampleCount
        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
        self.depthState = depthState
        self.meshPipelineState = meshPipelineState
        self.edgePipelineState = edgePipelineState
        self.outlinePipelineState = outlinePipelineState
        self.shadowPipelineState = shadowPipelineState
        self.ghostPipelineState = ghostPipelineState
        self.pickPipelineState = pickPipelineState
        self.meshDepthState = meshDepthState
        self.edgeDepthState = edgeDepthState
        self.outlineDepthState = outlineDepthState
        self.shadowDepthState = shadowDepthState
        self.ghostDepthState = ghostDepthState
        self.vertexBuffer = vertexBuffer
        self.lineCount = vertices.count / 2
    }

    /// Draws the grid and axes into an `MTKView`. The caller owns the camera
    /// because Phase 10 will animate it from gestures.
    func draw(
        in view: MTKView,
        camera: FFCamera,
        at time: Double = CACurrentMediaTime(),
        scene: FFViewportScene = .empty,
        mode: FFDisplayMode = .shaded
    ) {
        let width = max(1, view.drawableSize.width)
        let height = max(1, view.drawableSize.height)
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = Self.clearColor(for: mode)
        // Keep MTKView's own store action: with MSAA it is a multisample
        // resolve into the drawable, and overwriting it with `.store` would
        // leave the drawable unresolved.
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1

        let submitStart = CACurrentMediaTime()
        encode(
            pass: pass,
            commandBuffer: commandBuffer,
            camera: camera,
            aspect: Double(width / height),
            scene: scene,
            mode: mode,
            viewport: SIMD2<Float>(Float(width), Float(height))
        )
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] buffer in
            if let error = buffer.error {
                self?.lastCommandBufferError = error.localizedDescription
            }
        }
        commandBuffer.commit()
        lastSubmitMilliseconds = (CACurrentMediaTime() - submitStart) * 1_000

        drawCallCount = lastCounters.drawCalls
        statistics.record(frameAt: time)
    }

    /// Renders to textures and reads the resolved sRGB pixels back. This is the
    /// only way a hosted unit test can prove the shader and pipeline produce
    /// visible geometry rather than merely compiling.
    func renderOffscreen(
        width: Int,
        height: Int,
        camera: FFCamera,
        scene: FFViewportScene = .empty,
        mode: FFDisplayMode = .shaded
    ) -> FFViewportReadback? {
        guard width > 0, height > 0, width <= 4_096, height <= 4_096 else {
            return nil
        }

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        colorDescriptor.usage = .renderTarget
        colorDescriptor.storageMode = .private
        guard let resolveTexture = device.makeTexture(descriptor: colorDescriptor) else {
            return nil
        }

        let multisampleDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        multisampleDescriptor.textureType = .type2DMultisample
        multisampleDescriptor.sampleCount = sampleCount
        multisampleDescriptor.usage = .renderTarget
        multisampleDescriptor.storageMode = .private
        guard let multisampleTexture = device.makeTexture(descriptor: multisampleDescriptor) else {
            return nil
        }

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.depthPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        depthDescriptor.textureType = .type2DMultisample
        depthDescriptor.sampleCount = sampleCount
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        guard let depthTexture = device.makeTexture(descriptor: depthDescriptor) else {
            return nil
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = multisampleTexture
        pass.colorAttachments[0].resolveTexture = resolveTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = Self.clearColor(for: mode)
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        let submitStart = CACurrentMediaTime()
        encode(
            pass: pass,
            commandBuffer: commandBuffer,
            camera: camera,
            aspect: Double(width) / Double(height),
            scene: scene,
            mode: mode,
            viewport: SIMD2<Float>(Float(width), Float(height))
        )

        let bytesPerRow = width * 4
        guard let readbackBuffer = device.makeBuffer(
            length: bytesPerRow * height,
            options: .storageModeShared
        ), let blit = commandBuffer.makeBlitCommandEncoder()
        else { return nil }

        blit.copy(
            from: resolveTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: readbackBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height
        )
        blit.endEncoding()
        commandBuffer.commit()
        lastSubmitMilliseconds = (CACurrentMediaTime() - submitStart) * 1_000
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            lastCommandBufferError = error.localizedDescription
            return nil
        }

        let count = bytesPerRow * height
        let pointer = readbackBuffer.contents().bindMemory(to: UInt8.self, capacity: count)
        let pixels = Array(UnsafeBufferPointer(start: pointer, count: count))
        return FFViewportReadback(width: width, height: height, pixels: pixels)
    }

    /// Renders object IDs into an `r32Uint` texture and reads them back. The
    /// ID pass has no MSAA and no shading: a pick needs one integer per pixel,
    /// and keeping it single-sample makes the readback cheap enough to run on
    /// a tap. Hidden nodes are skipped but keep their index, so the ID for
    /// every visible node is stable.
    func pickBuffer(
        width: Int,
        height: Int,
        camera: FFCamera,
        scene: FFViewportScene
    ) -> FFPickingReadback? {
        guard width > 0, height > 0, width <= 4_096, height <= 4_096 else {
            return nil
        }

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Uint,
            width: width,
            height: height,
            mipmapped: false
        )
        colorDescriptor.usage = .renderTarget
        colorDescriptor.storageMode = .private
        guard let idTexture = device.makeTexture(descriptor: colorDescriptor) else {
            return nil
        }

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.depthPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        guard let depthTexture = device.makeTexture(descriptor: depthDescriptor) else {
            return nil
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = idTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return nil }
        encoder.label = "FacetForge picking"
        encoder.setRenderPipelineState(pickPipelineState)
        encoder.setDepthStencilState(meshDepthState)
        encoder.setCullMode(.back)

        let submitStart = CACurrentMediaTime()
        let viewProjection = camera.viewProjectionMatrix(aspect: Double(width) / Double(height))
        let viewport = SIMD2<Float>(Float(width), Float(height))
        for (index, node) in scene.nodes.enumerated() where node.isVisible {
            guard let buffers = buffers(for: node.mesh, nodeID: node.id) else { continue }
            var uniforms = meshUniforms(
                node: node,
                camera: camera,
                viewProjection: viewProjection,
                viewport: viewport,
                mode: .shaded
            )
            var objectID = UInt32(index + 1)
            encoder.setVertexBuffer(buffers.vertices, offset: 0, index: 0)
            encoder.setVertexBuffer(buffers.indices, offset: 0, index: 2)
            encoder.setVertexBytes(
                &uniforms,
                length: MemoryLayout<FFMeshUniforms>.stride,
                index: 1
            )
            encoder.setFragmentBytes(
                &objectID,
                length: MemoryLayout<UInt32>.stride,
                index: 2
            )
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: buffers.indexCount,
                indexType: .uint32,
                indexBuffer: buffers.indices,
                indexBufferOffset: 0
            )
        }
        encoder.endEncoding()

        let bytesPerRow = width * 4
        guard let readbackBuffer = device.makeBuffer(
            length: bytesPerRow * height,
            options: .storageModeShared
        ), let blit = commandBuffer.makeBlitCommandEncoder()
        else { return nil }

        blit.copy(
            from: idTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: readbackBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bytesPerRow * height
        )
        blit.endEncoding()
        commandBuffer.commit()
        lastSubmitMilliseconds = (CACurrentMediaTime() - submitStart) * 1_000
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            lastCommandBufferError = error.localizedDescription
            return nil
        }

        let count = width * height
        let pointer = readbackBuffer.contents().bindMemory(to: UInt32.self, capacity: count)
        let objectIDs = Array(UnsafeBufferPointer(start: pointer, count: count))
        return FFPickingReadback(width: width, height: height, objectIDs: objectIDs)
    }

    /// One ID pass resolves a whole batch of points. A drag selection or a
    /// dense test sweep must not pay a full render per pixel.
    func pick(
        at points: [Vec2],
        width: Int,
        height: Int,
        camera: FFCamera,
        scene: FFViewportScene,
        filter: FFPickFilter = .all
    ) -> [FFPickResult?] {
        guard let buffer = pickBuffer(
            width: width,
            height: height,
            camera: camera,
            scene: scene
        ) else {
            return Array(repeating: nil, count: points.count)
        }
        return points.map {
            FFPickResolver.resolve(
                buffer: buffer,
                scene: scene,
                point: $0,
                filter: filter
            )
        }
    }

    func pick(
        at point: Vec2,
        width: Int,
        height: Int,
        camera: FFCamera,
        scene: FFViewportScene,
        filter: FFPickFilter = .all
    ) -> FFPickResult? {
        pick(
            at: [point],
            width: width,
            height: height,
            camera: camera,
            scene: scene,
            filter: filter
        ).first ?? nil
    }

    private func encode(
        pass: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        camera: FFCamera,
        aspect: Double,
        scene: FFViewportScene,
        mode: FFDisplayMode,
        viewport: SIMD2<Float>
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }
        encoder.label = "FacetForge viewport"
        var counters = FFRenderCounters()
        let viewProjection = camera.viewProjectionMatrix(aspect: aspect)

        if mode.showsShadow, let bounds = scene.bounds {
            var shadowUniforms = FFMeshUniforms(
                model: Mat4.identity.simdMatrix,
                viewProjection: viewProjection.simdMatrix,
                normalMatrix: Mat4.identity.simdMatrix,
                baseColor: SIMD4<Float>(0, 0, 0, 1),
                cameraPosition: SIMD4<Float>(0, 0, 0, 1),
                material: SIMD4<Float>(0, 1, 0, 0),
                shadow: SIMD4<Float>(
                    Float(bounds.center.x),
                    Float(bounds.center.z),
                    Float(max(bounds.size.x, bounds.size.z) * 0.75 + 1),
                    Float(bounds.minimum.y) - 0.05
                ),
                lightDirection: SIMD4<Float>(0, 1, 0, 0),
                viewport: SIMD4<Float>(viewport.x, viewport.y, 0, 0),
                overlay: .zero
            )
            encoder.setRenderPipelineState(shadowPipelineState)
            encoder.setDepthStencilState(shadowDepthState)
            encoder.setCullMode(.none)
            encoder.setVertexBytes(
                &shadowUniforms,
                length: MemoryLayout<FFMeshUniforms>.stride,
                index: 1
            )
            encoder.setFragmentBytes(
                &shadowUniforms,
                length: MemoryLayout<FFMeshUniforms>.stride,
                index: 1
            )
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            counters.recordTriangles(2)
        }

        if mode.showsGrid {
            encoder.setRenderPipelineState(pipelineState)
            encoder.setDepthStencilState(depthState)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

            var matrix = viewProjection.metalMatrix
            encoder.setVertexBytes(
                &matrix,
                length: MemoryLayout<simd_float4x4>.stride,
                index: 1
            )
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineCount * 2)
            counters.recordLines()
        }

        // The outline is drawn before the meshes. Culling the back faces and
        // expanding the front-facing shell in screen space leaves a rim outside
        // the silhouette; the mesh pass then paints over the interior. Drawing
        // it first is what keeps the rim from colouring the whole selection —
        // with the mesh already in the depth buffer every back-face fragment
        // would either fail the test or flood the object.
        if scene.nodes.contains(where: \.isSelected) {
            encoder.setRenderPipelineState(outlinePipelineState)
            encoder.setDepthStencilState(outlineDepthState)
            encoder.setCullMode(.back)
            for node in scene.nodes where node.isSelected && node.isVisible {
                guard let buffers = buffers(for: node.mesh, nodeID: node.id) else { continue }
                var uniforms = meshUniforms(
                    node: node,
                    camera: camera,
                    viewProjection: viewProjection,
                    viewport: viewport,
                    mode: mode
                )
                encoder.setVertexBuffer(buffers.vertices, offset: 0, index: 0)
                encoder.setVertexBuffer(buffers.indices, offset: 0, index: 2)
                encoder.setVertexBytes(
                    &uniforms,
                    length: MemoryLayout<FFMeshUniforms>.stride,
                    index: 1
                )
                encoder.setFragmentBytes(
                    &uniforms,
                    length: MemoryLayout<FFMeshUniforms>.stride,
                    index: 1
                )
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: buffers.indexCount,
                    indexType: .uint32,
                    indexBuffer: buffers.indices,
                    indexBufferOffset: 0
                )
                counters.recordTriangles(buffers.indexCount / 3)
            }
        }

        if mode.drawsFaces, !scene.nodes.isEmpty {
            encoder.setRenderPipelineState(meshPipelineState)
            encoder.setDepthStencilState(meshDepthState)
            encoder.setCullMode(.back)
            for node in scene.nodes where node.isVisible {
                // A node with face groups draws one indexed range per material
                // over the same vertex buffer; a node without them keeps the
                // single-draw path it had before Phase 35.
                if node.parts.isEmpty {
                    guard let buffers = buffers(for: node.mesh, nodeID: node.id) else { continue }
                    var uniforms = meshUniforms(
                        node: node,
                        camera: camera,
                        viewProjection: viewProjection,
                        viewport: viewport,
                        mode: mode
                    )
                    encoder.setVertexBuffer(buffers.vertices, offset: 0, index: 0)
                    encoder.setVertexBuffer(buffers.indices, offset: 0, index: 2)
                    encoder.setVertexBytes(
                        &uniforms,
                        length: MemoryLayout<FFMeshUniforms>.stride,
                        index: 1
                    )
                    encoder.setFragmentBytes(
                        &uniforms,
                        length: MemoryLayout<FFMeshUniforms>.stride,
                        index: 1
                    )
                    encoder.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: buffers.indexCount,
                        indexType: .uint32,
                        indexBuffer: buffers.indices,
                        indexBufferOffset: 0
                    )
                    counters.recordTriangles(buffers.indexCount / 3)
                } else {
                    for part in node.parts {
                        guard let buffers = buffers(
                            for: part.mesh,
                            nodeID: node.id,
                            partID: part.id,
                            signature: part.signature
                        ) else { continue }
                        var uniforms = meshUniforms(
                            node: node,
                            camera: camera,
                            viewProjection: viewProjection,
                            viewport: viewport,
                            mode: mode,
                            material: part.material
                        )
                        encoder.setVertexBuffer(buffers.vertices, offset: 0, index: 0)
                        encoder.setVertexBuffer(buffers.indices, offset: 0, index: 2)
                        encoder.setVertexBytes(
                            &uniforms,
                            length: MemoryLayout<FFMeshUniforms>.stride,
                            index: 1
                        )
                        encoder.setFragmentBytes(
                            &uniforms,
                            length: MemoryLayout<FFMeshUniforms>.stride,
                            index: 1
                        )
                        encoder.drawIndexedPrimitives(
                            type: .triangle,
                            indexCount: buffers.indexCount,
                            indexType: .uint32,
                            indexBuffer: buffers.indices,
                            indexBufferOffset: 0
                        )
                        counters.recordTriangles(buffers.indexCount / 3)
                    }
                }
            }
        }

        // Phase 54's preview is a ghost: it is drawn after the opaque meshes so
        // it blends over the document, and it writes no depth, so it can never
        // hide the real geometry or be mistaken for a committed solid. It lives
        // in the scene's separate preview list, which picking never reads.
        if !scene.preview.isEmpty {
            encoder.setRenderPipelineState(ghostPipelineState)
            encoder.setDepthStencilState(ghostDepthState)
            encoder.setCullMode(.back)
            for node in scene.preview where node.isVisible {
                guard let buffers = buffers(
                    for: node.mesh,
                    nodeID: node.id,
                    signature: node.cacheSignature
                ) else { continue }
                var uniforms = meshUniforms(
                    node: node,
                    camera: camera,
                    viewProjection: viewProjection,
                    viewport: viewport,
                    mode: .shaded
                )
                encoder.setVertexBuffer(buffers.vertices, offset: 0, index: 0)
                encoder.setVertexBuffer(buffers.indices, offset: 0, index: 2)
                encoder.setVertexBytes(
                    &uniforms,
                    length: MemoryLayout<FFMeshUniforms>.stride,
                    index: 1
                )
                encoder.setFragmentBytes(
                    &uniforms,
                    length: MemoryLayout<FFMeshUniforms>.stride,
                    index: 1
                )
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: buffers.indexCount,
                    indexType: .uint32,
                    indexBuffer: buffers.indices,
                    indexBufferOffset: 0
                )
                counters.recordTriangles(buffers.indexCount / 3)
            }
        }

        // Edges read as a drawing: they sit on top of the shaded faces with a
        // small depth bias. A wireframe has no face pass at all, so the same
        // segments become the whole model and show the far side through it.
        if mode.drawsEdges {
            encoder.setRenderPipelineState(edgePipelineState)
            encoder.setDepthStencilState(edgeDepthState)
            encoder.setCullMode(.none)
            for node in scene.nodes where node.isVisible {
                guard let buffers = buffers(for: node.mesh, nodeID: node.id) else { continue }
                var uniforms = meshUniforms(
                    node: node,
                    camera: camera,
                    viewProjection: viewProjection,
                    viewport: viewport,
                    mode: mode
                )
                encoder.setVertexBuffer(buffers.vertices, offset: 0, index: 0)
                encoder.setVertexBuffer(buffers.edges, offset: 0, index: 2)
                encoder.setVertexBytes(
                    &uniforms,
                    length: MemoryLayout<FFMeshUniforms>.stride,
                    index: 1
                )
                encoder.setFragmentBytes(
                    &uniforms,
                    length: MemoryLayout<FFMeshUniforms>.stride,
                    index: 1
                )
                encoder.drawIndexedPrimitives(
                    type: .line,
                    indexCount: buffers.edgeIndexCount,
                    indexType: .uint32,
                    indexBuffer: buffers.edges,
                    indexBufferOffset: 0
                )
                counters.recordLines()
            }
        }

        lastCounters = counters
        encoder.endEncoding()
    }

    private func meshUniforms(
        node: FFRenderNode,
        camera: FFCamera,
        viewProjection: Mat4,
        viewport: SIMD2<Float>,
        mode: FFDisplayMode,
        material: FFRenderMaterial? = nil
    ) -> FFMeshUniforms {
        let model = node.transform.simdMatrix
        // Clay and Technical replace the document's material on the way to the
        // GPU. The node itself is untouched, so leaving the mode restores it.
        // A face part supplies its own material; the node's is the fallback.
        let surface = mode.materialOverride ?? material ?? node.material
        let color = surface.baseColor
        let edge = mode.strokeColor(for: node)
        let eye = camera.position
        return FFMeshUniforms(
            model: model,
            viewProjection: viewProjection.simdMatrix,
            normalMatrix: model,
            baseColor: SIMD4<Float>(
                Float(color.red),
                Float(color.green),
                Float(color.blue),
                Float(color.alpha)
            ),
            cameraPosition: SIMD4<Float>(Float(eye.x), Float(eye.y), Float(eye.z), 1),
            material: SIMD4<Float>(
                Float(surface.metallic),
                Float(surface.roughness),
                3.0,
                mode.shaderCode
            ),
            shadow: .zero,
            lightDirection: SIMD4<Float>(-0.45, 0.80, 0.55, 0.20),
            viewport: SIMD4<Float>(viewport.x, viewport.y, 0, 0),
            overlay: SIMD4<Float>(Float(edge.red), Float(edge.green), Float(edge.blue), 1)
        )
    }

    private func buffers(
        for mesh: FFRenderMesh,
        nodeID: UUID,
        partID: UUID? = nil,
        signature: UInt64 = 0
    ) -> FFMeshGPUBuffer? {
        let key = FFMeshBufferKey(nodeID: nodeID, partID: partID)
        if let cached = meshBuffers[key],
           cached.indexCount == mesh.indices.count,
           cached.edgeIndexCount == mesh.indices.count * 2,
           cached.vertexCount == mesh.positions.count,
           cached.signature == signature
        {
            return cached
        }
        guard !mesh.positions.isEmpty,
              !mesh.indices.isEmpty,
              mesh.normals.count == mesh.positions.count
        else { return nil }

        var interleaved: [Float] = []
        interleaved.reserveCapacity(mesh.positions.count * 6)
        for index in mesh.positions.indices {
            let position = mesh.positions[index]
            let normal = mesh.normals[index]
            interleaved.append(Float(position.x))
            interleaved.append(Float(position.y))
            interleaved.append(Float(position.z))
            interleaved.append(Float(normal.x))
            interleaved.append(Float(normal.y))
            interleaved.append(Float(normal.z))
        }

        let vertexBuffer: MTLBuffer? = interleaved.withUnsafeBytes { raw -> MTLBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
        }
        let indexBuffer: MTLBuffer? = mesh.indices.withUnsafeBytes { raw -> MTLBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
        }

        // Three line segments per triangle, sharing the triangle's vertices.
        var edgeIndices: [UInt32] = []
        edgeIndices.reserveCapacity(mesh.indices.count * 2)
        for offset in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.indices[offset]
            let b = mesh.indices[offset + 1]
            let c = mesh.indices[offset + 2]
            edgeIndices.append(contentsOf: [a, b, b, c, c, a])
        }
        let edgeBuffer: MTLBuffer? = edgeIndices.withUnsafeBytes { raw -> MTLBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
        }

        guard let vertices = vertexBuffer, let indices = indexBuffer, let edges = edgeBuffer else {
            return nil
        }
        let buffer = FFMeshGPUBuffer(
            vertices: vertices,
            indices: indices,
            edges: edges,
            indexCount: mesh.indices.count,
            edgeIndexCount: edgeIndices.count,
            vertexCount: mesh.positions.count,
            triangleCount: mesh.triangleCount,
            signature: signature
        )
        meshBuffers[key] = buffer
        return buffer
    }

    /// The shader is kept inline so the hand-authored Xcode project does not
    /// need a `.metal` build rule. It is compiled once per renderer instance.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct FFVertex {
        float3 position;
        float4 color;
    };

    struct FFVaryings {
        float4 position [[position]];
        float4 color;
    };

    vertex FFVaryings ff_vertex(
        uint vertexID [[vertex_id]],
        device const FFVertex *vertices [[buffer(0)]],
        constant float4x4 &mvp [[buffer(1)]]
    ) {
        FFVaryings out;
        FFVertex value = vertices[vertexID];
        out.position = mvp * float4(value.position, 1.0);
        out.color = value.color;
        return out;
    }

    fragment float4 ff_fragment(FFVaryings in [[stage_in]]) {
        return in.color;
    }

    struct FFMeshVertex {
        packed_float3 position;
        packed_float3 normal;
    };

    struct FFMeshUniforms {
        float4x4 model;
        float4x4 viewProjection;
        float4x4 normalMatrix;
        float4 baseColor;
        float4 cameraPosition;
        float4 material;
        float4 shadow;
        float4 lightDirection;
        float4 viewport;
        float4 overlay;
    };

    struct FFMeshVaryings {
        float4 position [[position]];
        float3 worldPosition;
        float3 normal;
    };

    vertex FFMeshVaryings ff_mesh_vertex(
        uint vertexID [[vertex_id]],
        device const FFMeshVertex *vertices [[buffer(0)]],
        constant FFMeshUniforms &u [[buffer(1)]]
    ) {
        FFMeshVertex value = vertices[vertexID];
        float4 world = u.model * float4(float3(value.position), 1.0);
        FFMeshVaryings out;
        out.position = u.viewProjection * world;
        out.worldPosition = world.xyz;
        out.normal = (u.normalMatrix * float4(float3(value.normal), 0.0)).xyz;
        return out;
    }

    fragment float4 ff_mesh_fragment(
        FFMeshVaryings in [[stage_in]],
        constant FFMeshUniforms &u [[buffer(1)]]
    ) {
        float3 normal = normalize(in.normal);
        float3 light = normalize(u.lightDirection.xyz);
        float3 view = normalize(u.cameraPosition.xyz - in.worldPosition);
        float ndl = max(dot(normal, light), 0.0);
        float3 halfVector = normalize(light + view);
        float ndh = max(dot(normal, halfVector), 0.0);
        float metallic = u.material.x;
        float roughness = u.material.y;
        float specularPower = mix(96.0, 8.0, roughness);
        float specular = pow(ndh, specularPower) * mix(0.22, 0.85, metallic);
        float3 diffuse = u.baseColor.rgb * (1.0 - metallic) * ndl;
        float3 ambient = u.baseColor.rgb * mix(0.20, 0.38, max(normal.y, 0.0));
        float3 color = ambient + diffuse * 0.9 + specular * light;

        // Technical is a drawing, not a render: per-facet normals flatten the
        // surface and the shading is compressed so the line work reads.
        if (u.material.w > 3.5) {
            float3 facet = normalize(cross(dfdx(in.worldPosition), dfdy(in.worldPosition)));
            if (dot(facet, normalize(u.cameraPosition.xyz - in.worldPosition)) < 0.0) {
                facet = -facet;
            }
            float facetLight = max(dot(facet, light), 0.0);
            color = u.baseColor.rgb * (0.74 + 0.22 * facetLight);
        }
        return float4(color, 1.0);
    }

    // Phase 54's preview ghost. The rim term is what makes a translucent body
    // read as a surface rather than as fog: the silhouette stays solid while
    // the faces facing the eye stay light enough to see the document through.
    fragment float4 ff_ghost_fragment(
        FFMeshVaryings in [[stage_in]],
        constant FFMeshUniforms &u [[buffer(1)]]
    ) {
        float3 normal = normalize(in.normal);
        float3 view = normalize(u.cameraPosition.xyz - in.worldPosition);
        float rim = pow(1.0 - saturate(abs(dot(normal, view))), 1.6);
        float3 color = u.baseColor.rgb * (0.55 + 0.45 * rim);
        float alpha = saturate(u.baseColor.a * (0.55 + 0.65 * rim));
        return float4(color, alpha);
    }

    struct FFEdgeVaryings {
        float4 position [[position]];
    };

    vertex FFEdgeVaryings ff_edge_vertex(
        uint vertexID [[vertex_id]],
        device const FFMeshVertex *vertices [[buffer(0)]],
        constant FFMeshUniforms &u [[buffer(1)]]
    ) {
        FFMeshVertex value = vertices[vertexID];
        float4 clip = u.viewProjection * u.model * float4(float3(value.position), 1.0);
        // Pull the line toward the eye in clip space so it wins the depth test
        // against the face it belongs to without hiding geometry in front.
        clip.z -= 0.00035 * clip.w;
        FFEdgeVaryings out;
        out.position = clip;
        return out;
    }

    fragment float4 ff_edge_fragment(constant FFMeshUniforms &u [[buffer(1)]]) {
        return float4(u.overlay.rgb, 1.0);
    }

    struct FFPickVaryings {
        float4 position [[position]];
    };

    vertex FFPickVaryings ff_pick_vertex(
        uint vertexID [[vertex_id]],
        device const FFMeshVertex *vertices [[buffer(0)]],
        constant FFMeshUniforms &u [[buffer(1)]]
    ) {
        FFMeshVertex value = vertices[vertexID];
        FFPickVaryings out;
        out.position = u.viewProjection * u.model * float4(float3(value.position), 1.0);
        return out;
    }

    fragment uint ff_pick_fragment(
        FFPickVaryings in [[stage_in]],
        constant uint &objectID [[buffer(2)]]
    ) {
        return objectID;
    }

    vertex float4 ff_outline_vertex(
        uint vertexID [[vertex_id]],
        device const FFMeshVertex *vertices [[buffer(0)]],
        constant FFMeshUniforms &u [[buffer(1)]]
    ) {
        FFMeshVertex value = vertices[vertexID];
        float4 clip = u.viewProjection * u.model * float4(float3(value.position), 1.0);
        float3 worldNormal = normalize((u.normalMatrix * float4(float3(value.normal), 0.0)).xyz);
        float4 clipNormal = u.viewProjection * float4(worldNormal, 0.0);
        float magnitude = max(length(clipNormal.xy), 1e-5);
        float2 direction = clipNormal.xy / magnitude;
        float2 offset = direction * (u.material.z * 2.0 / u.viewport.xy) * clip.w;
        clip.xy += offset;
        return clip;
    }

    fragment float4 ff_outline_fragment() {
        return float4(1.0, 0.16, 0.72, 1.0);
    }

    struct FFShadowVaryings {
        float4 position [[position]];
        float2 uv;
    };

    vertex FFShadowVaryings ff_shadow_vertex(
        uint vertexID [[vertex_id]],
        constant FFMeshUniforms &u [[buffer(1)]]
    ) {
        float2 corners[4] = {
            float2(-1.0, -1.0),
            float2(1.0, -1.0),
            float2(-1.0, 1.0),
            float2(1.0, 1.0)
        };
        float2 corner = corners[vertexID];
        float3 world = float3(
            u.shadow.x + corner.x * u.shadow.z,
            u.shadow.w,
            u.shadow.y + corner.y * u.shadow.z
        );
        FFShadowVaryings out;
        out.position = u.viewProjection * float4(world, 1.0);
        out.uv = corner;
        return out;
    }

    fragment float4 ff_shadow_fragment(FFShadowVaryings in [[stage_in]]) {
        float falloff = 1.0 - smoothstep(0.10, 1.0, length(in.uv));
        return float4(0.0, 0.0, 0.0, falloff * 0.34);
    }
    """
}

private extension Mat4 {
    /// `Mat4` is row-major; Metal expects column-major matrix columns. Each
    /// column here is one column of the kernel matrix, not a row.
    var metalMatrix: simd_float4x4 {
        simdMatrix
    }
}

extension FFMetalViewportRenderer: ViewportRendering {
    func render(
        scene: FFViewportScene,
        camera: FFCamera,
        width: Int,
        height: Int
    ) -> FFViewportReadback? {
        renderOffscreen(width: width, height: height, camera: camera, scene: scene)
    }
}

/// The MTKView subclass exists for one reason: `maximumFramesPerSecond` is only
/// meaningful once the view has a window and therefore a screen.
final class FFMetalView: MTKView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyDisplayPacing()
    }

    func applyDisplayPacing() {
        preferredFramesPerSecond = FFDisplayPacing.preferredFramesPerSecond(
            maximumFramesPerSecond: window?.screen.maximumFramesPerSecond
        )
    }
}

/// SwiftUI host for the Metal viewport. It rebuilds no renderer on every
/// camera update: the coordinator owns the device pipeline and only swaps the
/// camera value. Phase 10 adds the gesture layer; every gesture goes through
/// `FFCameraNavigation`, so direct touch, Pencil and trackpad share one tested
/// navigation rule set.
struct FFMetalViewportView: UIViewRepresentable {
    var camera: FFCamera
    var scene: FFViewportScene = .empty
    /// The document's display mode for this pane. Every pane owns its own, so a
    /// shaded Perspective can sit beside a technical Top.
    var mode: FFDisplayMode = .shaded
    /// Four-up panes need distinct identifiers so the accessibility tree keeps
    /// one camera state per pane. The single-pane default keeps the Phase 9/10
    /// identifier for the existing camera navigation tests.
    var accessibilityIdentifier: String = "shell.viewport.metal"
    /// A gizmo drag owns its touches. Letting the camera pan run at the same
    /// time would project the same screen translation onto a moving axis and
    /// break the snap, so the overlay switches camera gestures off until the
    /// drag ends.
    var allowsCameraGestures = true
    /// Which object kinds a tap may resolve. Filtered-out geometry still
    /// occludes, so a stone-only filter does not select the gold behind it.
    var pickFilter: FFPickFilter = .all
    /// A hover sample in top-left-origin viewport points, or `nil` when the
    /// pointer leaves. Taps publish one too, so a finger gets the same markers
    /// on a simulator without a trackpad.
    var onHover: (Vec2?) -> Void = { _ in }
    var onCameraChange: (FFCamera) -> Void = { _ in }
    var onPick: (FFPickResult?) -> Void = { _ in }
    var onPerformance: (FFPerformanceReport) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            camera: camera,
            scene: scene,
            mode: mode,
            pickFilter: pickFilter,
            onCameraChange: onCameraChange,
            onPick: onPick,
            onHover: onHover,
            onPerformance: onPerformance
        )
    }

    func makeUIView(context: Context) -> UIView {
        guard let renderer = FFMetalViewportRenderer() else {
            return Self.makeUnavailableView()
        }

        let view = FFMetalView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = renderer.pixelFormat
        view.depthStencilPixelFormat = FFMetalViewportRenderer.depthPixelFormat
        view.sampleCount = renderer.sampleCount
        view.clearColor = FFMetalViewportRenderer.clearColor(for: mode)
        // At creation there is no screen yet, so this is the safe floor. The
        // subclass raises it to the panel's 120 Hz in `didMoveToWindow`.
        view.preferredFramesPerSecond = FFDisplayPacing.preferredFramesPerSecond(
            maximumFramesPerSecond: nil
        )
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.framebufferOnly = true
        view.delegate = context.coordinator
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = accessibilityIdentifier
        view.accessibilityLabel = "3D Metal viewport"
        view.accessibilityValue = camera.accessibilityState
        context.coordinator.attach(renderer: renderer, view: view)
        context.coordinator.installGestures(on: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // SwiftUI re-renders the host whenever the FPS statistics tick. Writing
        // an unchanged accessibility value on every tick forces XCUITest to
        // rebuild its snapshot continuously, so only a real camera change may
        // touch the accessibility tree.
        if uiView.accessibilityIdentifier != accessibilityIdentifier {
            uiView.accessibilityIdentifier = accessibilityIdentifier
        }
        if uiView.accessibilityIdentifier == accessibilityIdentifier {
            let state = camera.accessibilityState
            if uiView.accessibilityValue != state {
                uiView.accessibilityValue = state
            }
        }
        context.coordinator.camera = camera
        context.coordinator.scene = scene
        context.coordinator.mode = mode
        context.coordinator.pickFilter = pickFilter
        (uiView as? FFMetalView)?.applyDisplayPacing()
        (uiView as? MTKView)?.clearColor = FFMetalViewportRenderer.clearColor(for: mode)
        context.coordinator.onCameraChange = onCameraChange
        context.coordinator.onPick = onPick
        context.coordinator.onHover = onHover
        context.coordinator.onPerformance = onPerformance
        context.coordinator.setCameraGesturesEnabled(allowsCameraGestures)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private static func makeUnavailableView() -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor(
            red: 0.055,
            green: 0.062,
            blue: 0.078,
            alpha: 1
        )

        let label = UILabel()
        label.text = "Metal viewport unavailable on this host"
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .footnote)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.accessibilityIdentifier = "shell.viewport.metalUnavailable"
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, multiplier: 0.8),
        ])
        return container
    }

    final class Coordinator: NSObject, MTKViewDelegate, UIGestureRecognizerDelegate {
        var camera: FFCamera
        var scene: FFViewportScene
        var mode: FFDisplayMode
        var pickFilter: FFPickFilter
        var onCameraChange: (FFCamera) -> Void
        var onPick: (FFPickResult?) -> Void
        var onHover: (Vec2?) -> Void
        var onPerformance: (FFPerformanceReport) -> Void

        private var renderer: FFMetalViewportRenderer?
        private(set) var pickInteraction = FFPickInteraction()
        private weak var metalView: MTKView?
        private var lastReportTime: Double = 0
        private var arbitration = FFTouchArbitration()
        private weak var panRecognizer: UIPanGestureRecognizer?
        private weak var pickTapRecognizer: FFTouchTapGestureRecognizer?

        init(
            camera: FFCamera,
            scene: FFViewportScene,
            mode: FFDisplayMode,
            pickFilter: FFPickFilter,
            onCameraChange: @escaping (FFCamera) -> Void,
            onPick: @escaping (FFPickResult?) -> Void,
            onHover: @escaping (Vec2?) -> Void,
            onPerformance: @escaping (FFPerformanceReport) -> Void
        ) {
            self.camera = camera
            self.scene = scene
            self.mode = mode
            self.pickFilter = pickFilter
            self.onCameraChange = onCameraChange
            self.onPick = onPick
            self.onHover = onHover
            self.onPerformance = onPerformance
        }

        func attach(renderer: FFMetalViewportRenderer, view: MTKView) {
            self.renderer = renderer
            self.metalView = view
        }

        func detach() {
            metalView?.delegate = nil
            metalView = nil
            renderer = nil
        }

        /// One pan recogniser covers direct touch (one finger orbits, two
        /// fingers pan), Pencil drags and indirect trackpad scrolling. Pinch
        /// covers both touch and trackpad zoom. A two-finger double tap frames
        /// the scene, matching the desktop shortcut a jeweller already knows.
        func installGestures(on view: MTKView) {
            // The observer is installed first and stays enabled while the
            // camera recognisers are suspended for a gizmo drag, so the
            // arbitration state cannot go stale across that boundary.
            let observer = FFTouchContactObserver()
            observer.delegate = self
            observer.cancelsTouchesInView = false
            observer.delaysTouchesBegan = false
            observer.delaysTouchesEnded = false
            observer.onBegin = { [weak self] id, kind in
                self?.arbitration.begin(id: id, kind: kind)
            }
            observer.onEnd = { [weak self] id in
                self?.arbitration.end(id: id)
            }
            view.addGestureRecognizer(observer)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 2
            pan.allowedScrollTypesMask = .all
            pan.delegate = self
            pan.cancelsTouchesInView = false
            view.addGestureRecognizer(pan)
            panRecognizer = pan

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            pinch.cancelsTouchesInView = false
            view.addGestureRecognizer(pinch)

            let frameTap = UITapGestureRecognizer(target: self, action: #selector(handleFrameTap(_:)))
            frameTap.numberOfTapsRequired = 2
            frameTap.numberOfTouchesRequired = 2
            frameTap.delegate = self
            view.addGestureRecognizer(frameTap)

            let pickTap = FFTouchTapGestureRecognizer(
                target: self,
                action: #selector(handlePickTap(_:))
            )
            pickTap.numberOfTapsRequired = 1
            pickTap.delegate = self
            view.addGestureRecognizer(pickTap)
            pickTapRecognizer = pickTap

            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            hover.delegate = self
            view.addGestureRecognizer(hover)

            cameraGestureRecognizers = [pan, pinch, frameTap, pickTap, hover]
        }

        private var cameraGestureRecognizers: [UIGestureRecognizer] = []
        private var cameraGesturesEnabled = true

        func setCameraGesturesEnabled(_ enabled: Bool) {
            guard enabled != cameraGesturesEnabled else { return }
            cameraGesturesEnabled = enabled
            for recognizer in cameraGestureRecognizers {
                recognizer.isEnabled = enabled
            }
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = metalView else { return }
            let translation = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)

            let isIndirect = recognizer.numberOfTouches == 0
            guard translation != .zero else { return }

            // The arbiter, not the recogniser's touch count, decides whether
            // this delta is a camera move. A Pencil, a palm or a resting hand
            // returns `.none` here and the translation is discarded.
            let intent = arbitration.cameraIntent(
                isIndirect: isIndirect,
                touchCount: recognizer.numberOfTouches
            )
            guard intent != .none else { return }

            var next = camera
            let delta = Vec2(x: Double(translation.x), y: Double(translation.y))
            switch intent {
            case .pan:
                FFCameraNavigation.pan(
                    &next,
                    screenDelta: delta,
                    viewport: viewportSize(of: view)
                )
            case .orbit:
                FFCameraNavigation.orbit(&next, screenDelta: delta)
            case .none:
                return
            }
            publish(next, in: view)
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = metalView, recognizer.state == .changed else { return }
            guard !arbitration.cameraCommandBlocked else { return }
            let factor = Double(recognizer.scale)
            recognizer.scale = 1
            guard abs(factor - 1) > 1e-4 else { return }

            let location = recognizer.location(in: view)
            var next = camera
            FFCameraNavigation.zoom(
                &next,
                factor: factor,
                around: Vec2(x: Double(location.x), y: Double(location.y)),
                viewport: viewportSize(of: view)
            )
            publish(next, in: view)
        }

        @objc private func handleFrameTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = metalView, recognizer.state == .ended else { return }
            guard !arbitration.cameraCommandBlocked else { return }
            var next = camera
            FFCameraNavigation.frameAll(&next)
            publish(next, in: view)
        }

        /// A pointer hover publishes the snap sample. On a simulator without a
        /// trackpad no `.changed` event ever arrives, so the tap below publishes
        /// the same sample and the markers are still observable in UI tests.
        @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            guard let view = metalView else { return }
            switch recognizer.state {
            case .changed, .began:
                let location = recognizer.location(in: view)
                let callback = onHover
                let point = Vec2(x: Double(location.x), y: Double(location.y))
                DispatchQueue.main.async { callback(point) }
            case .ended, .cancelled, .failed:
                let callback = onHover
                DispatchQueue.main.async { callback(nil) }
            default:
                break
            }
        }

        /// A tap resolves through the ID buffer and publishes the hover result.
        /// The drag gesture keeps its own pick, so a moving finger cannot be
        /// re-targeted by a hover event.
        @objc private func handlePickTap(_ recognizer: FFTouchTapGestureRecognizer) {
            guard let view = metalView,
                  recognizer.state == .ended,
                  let renderer,
                  arbitration.selectionAllowed(kind: recognizer.firstTouchKind)
            else { return }
            let location = recognizer.location(in: view)
            let hoverCallback = onHover
            let hoverPoint = Vec2(x: Double(location.x), y: Double(location.y))
            DispatchQueue.main.async { hoverCallback(hoverPoint) }
            let size = view.bounds.size
            guard size.width >= 1, size.height >= 1 else { return }
            let result = renderer.pick(
                at: Vec2(x: Double(location.x), y: Double(location.y)),
                width: Int(size.width),
                height: Int(size.height),
                camera: camera,
                scene: scene,
                filter: pickFilter
            )
            pickInteraction.hover(result)
            let callback = onPick
            DispatchQueue.main.async {
                callback(result)
            }
        }

        private func viewportSize(of view: UIView) -> Vec2 {
            Vec2(x: Double(view.bounds.width), y: Double(view.bounds.height))
        }

        private func publish(_ next: FFCamera, in view: UIView) {
            guard next != camera else { return }
            camera = next
            view.accessibilityValue = next.accessibilityState
            let callback = onCameraChange
            DispatchQueue.main.async {
                callback(next)
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        /// Refuse a contact before the recogniser starts tracking it. This is
        /// what keeps a direct tap that lands while the Pencil is down out of
        /// the pick path entirely; the pan has a second veto in `handlePan`
        /// because a Pencil can land after a finger gesture has begun.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            let kind = FFTouchKind(touch: touch)
            if gestureRecognizer === pickTapRecognizer {
                return arbitration.selectionAllowed(kind: kind)
            }
            if gestureRecognizer === panRecognizer {
                if kind == .pencil { return false }
                if kind == .finger, arbitration.pencilActive { return false }
            }
            return true
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // MTKView recreates its drawable and multisample texture; the
            // renderer reads `drawableSize` every frame, so no extra work.
        }

        func draw(in view: MTKView) {
            guard let renderer else { return }
            let now = CACurrentMediaTime()
            renderer.draw(in: view, camera: camera, at: now, scene: scene, mode: mode)

            guard now - lastReportTime >= 0.5 else { return }
            lastReportTime = now
            let report = renderer.performanceReport
            DispatchQueue.main.async { [weak self] in
                self?.onPerformance(report)
            }
        }
    }
}
