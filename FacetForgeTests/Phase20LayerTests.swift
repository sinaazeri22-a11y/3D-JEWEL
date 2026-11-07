import Metal
import UIKit
import XCTest
@testable import FacetForge

/// Phase 20's acceptance. Layers are document state with one owner, so the
/// tests drive them through `FFEditorSession` and then prove the three row
/// criteria where they actually happen: a locked layer refuses an edit, a
/// hidden layer is absent from the GPU ID buffer, and wireframe line work is
/// drawn in the layer's own colour on real pixels.
final class Phase20LayerTests: XCTestCase {
    private let viewport = Vec2(x: 320, y: 240)

    // MARK: - Membership, visibility and persistence

    func testLayerMembershipIsDocumentState() throws {
        let document = FFDocument.benchSample.document
        let metal = try XCTUnwrap(document.layers.first { $0.name == "Metal" })
        let stones = try XCTUnwrap(document.layers.first { $0.name == "Stones" })
        let shank = try XCTUnwrap(document.rootNodes.first { $0.name == "Shank" })
        let stone = try XCTUnwrap(document.rootNodes.first { $0.name == "Stone" })

        XCTAssertEqual(shank.layerID, metal.id)
        XCTAssertEqual(stone.layerID, stones.id)
        XCTAssertEqual(Set(document.nodeIDs(inLayer: metal.id)), [shank.id])
        XCTAssertEqual(Set(document.nodeIDs(inLayer: stones.id)), [stone.id])

        let session = FFEditorSession()
        XCTAssertEqual(session.layers, document.layers)
        XCTAssertEqual(session.currentLayerID, metal.id)
        XCTAssertEqual(session.scene.node(id: shank.id)?.layerColor, metal.color)
        XCTAssertEqual(session.scene.node(id: stone.id)?.layerColor, stones.color)
        XCTAssertEqual(session.nodeCount(inLayer: metal.id), 1)
        XCTAssertEqual(session.nodeCount(inLayer: stones.id), 1)
    }

    func testHiddenLayerIsUnpickable() throws {
        let renderer = try makeRenderer()
        let session = FFEditorSession()
        let stones = try XCTUnwrap(session.layers.first { $0.name == "Stones" })
        let stone = try XCTUnwrap(session.scene.nodes.first { $0.kind == .stone })

        var camera = FFCamera.standard
        let bounds = try XCTUnwrap(session.scene.bounds)
        camera.frame(bounds: bounds, padding: 1.2)
        let point = try projectedPickPoint(of: stone, camera: camera)

        guard let visibleIDs = renderer.pickBuffer(
            width: Int(viewport.x),
            height: Int(viewport.y),
            camera: camera,
            scene: session.scene
        ) else {
            return XCTFail("the visible pick buffer did not render")
        }
        XCTAssertEqual(
            FFPickResolver.resolve(
                buffer: visibleIDs,
                scene: session.scene,
                point: point
            )?.nodeID,
            stone.id,
            "the stone was not pickable while its layer was visible"
        )

        XCTAssertTrue(session.setLayerVisible(stones.id, isVisible: false))
        let hiddenScene = session.scene
        let hiddenStone = try XCTUnwrap(hiddenScene.node(id: stone.id))
        XCTAssertFalse(hiddenStone.isVisible, "hiding the layer did not hide its nodes")

        guard let hiddenIDs = renderer.pickBuffer(
            width: Int(viewport.x),
            height: Int(viewport.y),
            camera: camera,
            scene: hiddenScene
        ) else {
            return XCTFail("the hidden pick buffer did not render")
        }
        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))
        XCTAssertEqual(
            hiddenIDs.objectID(atX: x, y: y),
            0,
            "the renderer wrote a hidden layer's node into the ID buffer"
        )
        XCTAssertNil(
            FFPickResolver.resolve(buffer: hiddenIDs, scene: hiddenScene, point: point),
            "a hidden layer stayed pickable"
        )

        // Phase 17's selection application must not resurrect the node the
        // layer removed from the drawing.
        let applied = session.selection.applying(to: hiddenScene)
        XCTAssertFalse(try XCTUnwrap(applied.node(id: stone.id)).isVisible)
        XCTAssertTrue(
            session.selection.visibilitySummary(in: hiddenScene).contains("1 hidden")
        )
    }

    func testLayersPersistAcrossSaveAndReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("facetforge-phase20-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layers.facetforge.json")

        let session = FFEditorSession()
        let metal = try XCTUnwrap(session.layers.first { $0.name == "Metal" })
        let stones = try XCTUnwrap(session.layers.first { $0.name == "Stones" })
        let shankID = try XCTUnwrap(session.scene.nodes.first { $0.kind == .solid }?.id)
        let stoneID = try XCTUnwrap(session.scene.nodes.first { $0.kind == .stone }?.id)

        XCTAssertTrue(session.setLayerLocked(metal.id, isLocked: true))
        XCTAssertTrue(session.setLayerVisible(stones.id, isVisible: false))
        XCTAssertTrue(session.setCurrentLayer(stones.id))
        XCTAssertTrue(session.cycleLayerColor(stones.id))

        let expectedLayers = session.layers
        let expectedCurrent = session.currentLayerID
        try session.save(to: url)

        // The save path is a Phase 25 `.ffp` bundle, so the file is read
        // through its store rather than as standalone JSON. The assertions
        // below still prove that every layer field reached the save file.
        let saved = try FFDocumentStore().load(from: url)
        XCTAssertEqual(saved.layers, expectedLayers, "layers did not reach the save file")
        XCTAssertEqual(saved.currentLayerID, expectedCurrent)
        XCTAssertEqual(saved.node(withID: shankID)?.layerID, metal.id)

        let reopened = FFEditorSession(document: FFDocument())
        try reopened.reopen(from: url)
        XCTAssertEqual(reopened.layers, expectedLayers)
        XCTAssertEqual(reopened.currentLayerID, stones.id)
        XCTAssertTrue(reopened.isLocked(nodeID: shankID))
        XCTAssertEqual(reopened.lockedNodeIDs, [shankID])
        XCTAssertFalse(
            try XCTUnwrap(reopened.scene.node(id: stoneID)).isVisible,
            "a hidden layer reopened visible"
        )
        XCTAssertEqual(reopened.document.node(withID: shankID)?.layerID, metal.id)
    }

    func testLegacyDocumentGainsTheDefaultLayer() throws {
        let node = FFNode(name: "Bench")
        let legacy = FFDocument(name: "Legacy", rootNodes: [node])
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacy.encoded()) as? [String: Any]
        )
        // A schema-1 file written before layers has neither key.
        object.removeValue(forKey: "layers")
        object.removeValue(forKey: "currentLayerID")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try FFDocument.decoded(from: data)

        XCTAssertEqual(decoded.layers, [FFLayer.defaultLayer])
        XCTAssertEqual(decoded.currentLayerID, FFLayer.defaultLayerID)
        XCTAssertEqual(decoded.layer(forNodeID: node.id)?.id, FFLayer.defaultLayerID)
        XCTAssertEqual(decoded.nodeIDs(inLayer: FFLayer.defaultLayerID), [node.id])
    }

    // MARK: - Lock

    func testLockedLayerRejectsAssignmentEdits() throws {
        let session = FFEditorSession()
        let metal = try XCTUnwrap(session.layers.first { $0.name == "Metal" })
        let stones = try XCTUnwrap(session.layers.first { $0.name == "Stones" })
        let shankID = try XCTUnwrap(session.scene.nodes.first { $0.kind == .solid }?.id)
        session.selection.select([shankID])

        XCTAssertTrue(session.setLayerLocked(metal.id, isLocked: true))
        XCTAssertEqual(
            session.assignSelection(to: stones.id),
            0,
            "a locked source layer allowed its node to be moved"
        )
        XCTAssertEqual(session.document.node(withID: shankID)?.layerID, metal.id)
        XCTAssertEqual(session.lockedNodeIDs, [shankID])

        // A locked destination is an edit of the destination, so it must
        // refuse as well. Unlocking is still possible: lock is not a dead end.
        XCTAssertTrue(session.setLayerLocked(stones.id, isLocked: true))
        XCTAssertEqual(session.assignSelection(to: stones.id), 0)

        XCTAssertTrue(session.setLayerLocked(metal.id, isLocked: false))
        XCTAssertTrue(session.setLayerLocked(stones.id, isLocked: false))
        XCTAssertEqual(session.assignSelection(to: stones.id), 1)
        XCTAssertEqual(session.document.node(withID: shankID)?.layerID, stones.id)
        XCTAssertEqual(session.nodeCount(inLayer: metal.id), 0)
        XCTAssertEqual(session.nodeCount(inLayer: stones.id), 2)
    }

    func testSelectByLayerAndCurrentLayer() throws {
        let session = FFEditorSession()
        let metal = try XCTUnwrap(session.layers.first { $0.name == "Metal" })
        let stones = try XCTUnwrap(session.layers.first { $0.name == "Stones" })
        let shankID = try XCTUnwrap(session.scene.nodes.first { $0.kind == .solid }?.id)
        let stoneID = try XCTUnwrap(session.scene.nodes.first { $0.kind == .stone }?.id)

        XCTAssertTrue(session.selectLayer(metal.id))
        XCTAssertEqual(session.selection.selectedIDs, [shankID])
        XCTAssertTrue(session.selectLayer(stones.id, extend: true))
        XCTAssertEqual(session.selection.selectedIDs, [shankID, stoneID])

        // A hidden layer is unpickable, and selecting it by name is not a
        // back door around that rule.
        XCTAssertTrue(session.setLayerVisible(stones.id, isVisible: false))
        session.selection.clearSelection()
        XCTAssertFalse(session.selectLayer(stones.id))
        XCTAssertTrue(session.selection.selectedIDs.isEmpty)

        let added = try XCTUnwrap(session.addLayer())
        XCTAssertEqual(session.layers.count, 3)
        XCTAssertEqual(session.layers.last?.id, added)
        XCTAssertEqual(session.layers.last?.name, "Layer 3")
        XCTAssertEqual(session.currentLayerID, added)
        XCTAssertNotEqual(session.layers.last?.color, stones.color)
    }

    // MARK: - Wireframe layer colour

    func testWireframeDrawsEachLayerInItsOwnColour() throws {
        let renderer = try makeRenderer()
        let red = FFLayer(
            name: "Red",
            color: FFRGBA(red: 1.0, green: 0.18, blue: 0.12)
        )
        let blue = FFLayer(
            name: "Blue",
            color: FFRGBA(red: 0.16, green: 0.42, blue: 1.0)
        )
        let document = FFDocument(
            name: "Wire layers",
            rootNodes: [
                wireNode(name: "Left", x: -26, layerID: red.id),
                wireNode(name: "Right", x: 26, layerID: blue.id)
            ],
            layers: [red, blue],
            currentLayerID: red.id
        )
        let scene = FFEditorSession(document: document).scene
        XCTAssertEqual(scene.nodes.count, 2)
        XCTAssertEqual(FFDisplayMode.wireframe.strokeColor(for: scene.nodes[0]), red.color)
        XCTAssertEqual(FFDisplayMode.wireframe.strokeColor(for: scene.nodes[1]), blue.color)
        XCTAssertEqual(
            FFDisplayMode.shadedEdges.strokeColor(for: scene.nodes[0]),
            FFDisplayMode.shadedEdges.edgeColor,
            "a non-wireframe mode took the layer colour"
        )

        var camera = FFCamera.standard
        let bounds = try XCTUnwrap(scene.bounds)
        camera.frame(bounds: bounds, padding: 1.25)

        let width = 360
        let height = 240
        guard let readback = renderer.renderOffscreen(
            width: width,
            height: height,
            camera: camera,
            scene: scene,
            mode: .wireframe
        ) else {
            return XCTFail("the wireframe render produced no readback")
        }
        XCTAssertNil(renderer.lastCommandBufferError)

        var redCount = 0
        var blueCount = 0
        var redX = 0.0
        var blueX = 0.0
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            let b = Int(readback.pixels[offset])
            let g = Int(readback.pixels[offset + 1])
            let r = Int(readback.pixels[offset + 2])
            if r > 200, g < 170, b < 150 {
                redCount += 1
                redX += Double(pixel % width)
            } else if b > 200, r < 170 {
                blueCount += 1
                blueX += Double(pixel % width)
            }
        }

        print("phase20 wireframe red=\(redCount) blue=\(blueCount)")
        XCTAssertGreaterThan(redCount, 100, "the red layer's wireframe is not on screen")
        XCTAssertGreaterThan(blueCount, 100, "the blue layer's wireframe is not on screen")
        XCTAssertGreaterThan(
            abs(redX / Double(redCount) - blueX / Double(blueCount)),
            30,
            "both layers were drawn in one colour"
        )

        if let image = uiImage(from: readback) {
            let attachment = XCTAttachment(image: image)
            attachment.name = "phase20-wireframe-layers"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    // MARK: - Helpers

    private func wireNode(name: String, x: Double, layerID: UUID) -> FFNode {
        let mesh = FFMeshFactory.octahedron(radius: 14)!
        return FFNode(
            name: name,
            transform: FFTransform(
                translation: FFPoint3(x: x, y: 0, z: 0),
                rotation: FFPoint3(x: 0, y: 0, z: 0),
                scale: FFPoint3(x: 1, y: 1, z: 1)
            ),
            geometry: .mesh(FFMeshPayload(mesh)),
            layerID: layerID
        )
    }

    /// A point three quarters up the stone, clear of the ring behind it, so a
    /// hidden-layer miss cannot be confused with the shank showing through.
    private func projectedPickPoint(
        of node: FFRenderNode,
        camera: FFCamera
    ) throws -> Vec2 {
        let bounds = try XCTUnwrap(node.mesh.bounds)
        let local = Vec3(
            x: (bounds.minimum.x + bounds.maximum.x) * 0.5,
            y: bounds.minimum.y + (bounds.maximum.y - bounds.minimum.y) * 0.75,
            z: (bounds.minimum.z + bounds.maximum.z) * 0.5
        )
        let world = node.transform * Vec4(x: local.x, y: local.y, z: local.z, w: 1)
        return try XCTUnwrap(
            camera.screenPoint(
                for: Vec3(x: world.x, y: world.y, z: world.z),
                viewport: viewport
            )
        )
    }

    private func makeRenderer() throws -> FFMetalViewportRenderer {
        guard let renderer = FFMetalViewportRenderer() else {
            throw XCTSkip("Metal device unavailable on this simulator")
        }
        return renderer
    }

    private func uiImage(from readback: FFViewportReadback) -> UIImage? {
        let width = readback.width
        let height = readback.height
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for offset in stride(from: 0, to: readback.pixels.count, by: 4) {
            rgba[offset] = readback.pixels[offset + 2]
            rgba[offset + 1] = readback.pixels[offset + 1]
            rgba[offset + 2] = readback.pixels[offset]
            rgba[offset + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
