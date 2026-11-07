import Metal
import UIKit
import XCTest
@testable import FacetForge

/// Phase 18's acceptance. Every display mode is rendered offscreen to real
/// pixels, not merely constructed, and the modes are told apart by what they
/// put on screen: Technical's light sheet, Clay's material override, Wireframe's
/// missing faces, Shaded-with-edges' extra line work. The saved document is
/// then written to disk and reopened to prove each viewport's mode survives.
final class Phase18DisplayModeTests: XCTestCase {
    // MARK: - The mode row

    func testModeRowHasFiveModesInChipOrder() {
        XCTAssertEqual(
            FFDisplayMode.allCases,
            [.shaded, .shadedEdges, .clay, .wireframe, .technical]
        )
        XCTAssertEqual(FFDisplayMode.technical.next, .shaded)
        XCTAssertEqual(FFDisplayMode.shaded.next, .shadedEdges)

        XCTAssertFalse(FFDisplayMode.wireframe.drawsFaces)
        XCTAssertTrue(FFDisplayMode.shaded.drawsFaces)
        XCTAssertTrue(FFDisplayMode.technical.drawsEdges)
        XCTAssertFalse(FFDisplayMode.shaded.drawsEdges)
        XCTAssertFalse(FFDisplayMode.wireframe.showsGrid)
        XCTAssertFalse(FFDisplayMode.technical.showsGrid)

        XCTAssertNotNil(FFDisplayMode.clay.materialOverride)
        XCTAssertNotNil(FFDisplayMode.technical.materialOverride)
        XCTAssertNil(FFDisplayMode.shaded.materialOverride)
        XCTAssertNil(FFDisplayMode.wireframe.materialOverride)
    }

    // MARK: - Snapshot render per mode

    /// The row asks for a snapshot render per mode. Every mode is rendered to
    /// real pixels over one coarse fixture and measured only on that fixture's
    /// silhouette (taken from the picking buffer), so the grid and the studio
    /// background cannot flatter or spoil a mode. The snapshot of each mode is
    /// attached for review and the five images must differ.
    func testEveryModeRendersItsOwnSnapshot() throws {
        let renderer = try makeRenderer()
        let fixture = try makeFixtureScene()
        guard let bounds = fixture.bounds else { return XCTFail("fixture has no bounds") }
        var camera = FFCamera.standard
        camera.frame(bounds: bounds, padding: 1.05)

        let width = 320
        let height = 240
        guard let ids = renderer.pickBuffer(
            width: width,
            height: height,
            camera: camera,
            scene: fixture
        ) else {
            return XCTFail("the ID buffer for the fixture did not render")
        }
        XCTAssertGreaterThan(
            ids.objectIDs.filter { $0 != 0 }.count,
            4_000,
            "the mode fixture covers too few pixels to compare"
        )

        var snapshots: [FFDisplayMode: Snapshot] = [:]
        for mode in FFDisplayMode.allCases {
            guard let readback = renderer.renderOffscreen(
                width: width,
                height: height,
                camera: camera,
                scene: fixture,
                mode: mode
            ) else {
                return XCTFail("\(mode.rawValue) produced no readback")
            }
            XCTAssertNil(renderer.lastCommandBufferError, "\(mode.rawValue) command buffer failed")

            let measured = signature(for: readback, ids: ids)
            snapshots[mode] = measured
            print(
                "phase18 \(mode.rawValue) corner=\(measured.corner.0),\(measured.corner.1),"
                    + "\(measured.corner.2) filled=\(String(format: "%.3f", measured.filled))"
                    + " warmth=\(String(format: "%.1f", measured.warmth))"
                    + " silhouette=\(measured.silhouette)"
            )

            if let image = uiImage(from: readback) {
                let attachment = XCTAttachment(image: image)
                attachment.name = "phase18-fixture-\(mode.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }

            XCTAssertGreaterThan(measured.silhouette, 4_000, "\(mode.rawValue) lost the fixture")

            switch mode {
            case .technical:
                XCTAssertGreaterThan(
                    measured.corner.0 + measured.corner.1 + measured.corner.2,
                    600,
                    "Technical did not draw its light sheet"
                )
            case .shaded, .shadedEdges, .clay, .wireframe:
                XCTAssertLessThan(
                    measured.corner.0 + measured.corner.1 + measured.corner.2,
                    300,
                    "\(mode.rawValue) did not draw the dark studio background"
                )
            }

            // Faces fill the fixture's silhouette in every mode but Wireframe,
            // which is nothing but the octahedron's twelve edges.
            switch mode {
            case .shaded, .shadedEdges, .clay, .technical:
                XCTAssertGreaterThan(
                    measured.filled,
                    0.85,
                    "\(mode.rawValue) left holes in its faces"
                )
            case .wireframe:
                XCTAssertGreaterThan(measured.filled, 0.02, "Wireframe drew no edges")
                XCTAssertLessThan(measured.filled, 0.55, "Wireframe filled its faces")
            }
        }

        let shaded = try XCTUnwrap(snapshots[.shaded])
        let edges = try XCTUnwrap(snapshots[.shadedEdges])
        let clay = try XCTUnwrap(snapshots[.clay])
        let wire = try XCTUnwrap(snapshots[.wireframe])
        let technical = try XCTUnwrap(snapshots[.technical])

        // The material override removes the document's warm gold and keeps a
        // near-neutral working grey. Warmth is mean red-minus-blue over the
        // fixture, so it does not depend on how brightly the light falls.
        XCTAssertGreaterThan(shaded.warmth, 12, "Shaded did not shade the gold fixture")
        XCTAssertGreaterThan(edges.warmth, 10, "Shaded with edges lost the gold material")
        // Relative to Shaded, so the check survives any exposure: an override
        // that still showed the document's gold would keep its warmth.
        XCTAssertLessThan(clay.warmth, shaded.warmth * 0.5, "Clay kept the document material instead of overriding it")
        XCTAssertLessThan(technical.warmth, shaded.warmth * 0.5, "Technical kept the document material")
        XCTAssertLessThan(wire.warmth, shaded.warmth * 0.5, "Wireframe drew shaded faces")

        // Shaded-with-edges is Shaded plus line work, not a different shading.
        // The octahedron's twelve edges cover about a fifth of its silhouette,
        // so a tenth is a floor that only real edge work can clear.
        XCTAssertGreaterThan(
            edges.difference(from: shaded),
            0.10,
            "Shaded with edges drew no extra edge pixels"
        )
        XCTAssertGreaterThan(
            shaded.difference(from: wire),
            0.50,
            "Wireframe is indistinguishable from Shaded"
        )

        let fingerprints = snapshots.values.map(\.fingerprint)
        XCTAssertEqual(Set(fingerprints).count, FFDisplayMode.allCases.count, "two modes render identically")

        // Evidence: the same five modes on the real bench sample, not the
        // comparison fixture, so a reviewer sees the shipping scene.
        try attachBenchRenders(renderer: renderer)
    }

    // MARK: - Persistence across save and reopen

    func testModePersistsAcrossSaveAndReopenPerViewport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("facetforge-phase18-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ring.facetforge.json")

        let document = FFDocument.benchSample.document
        let session = FFEditorSession(document: document)
        XCTAssertTrue(session.setDisplayMode(.technical, for: "perspective"))
        XCTAssertTrue(session.setDisplayMode(.wireframe, for: "top"))
        XCTAssertTrue(session.documentSession.canUndo, "the mode did not go through the document session")
        try session.save(to: url)

        // The save path is a Phase 25 `.ffp` bundle, so the file is read
        // through its store rather than as standalone JSON. The assertion is
        // unchanged: the mode reached the saved document.
        let saved = try FFDocumentStore().load(from: url)
        XCTAssertEqual(saved.displayModes["perspective"], .technical)
        XCTAssertEqual(saved.displayModes["top"], .wireframe)

        let reopened = FFEditorSession(document: FFDocument())
        try reopened.reopen(from: url)

        XCTAssertEqual(reopened.displayMode(for: "perspective"), .technical)
        XCTAssertEqual(reopened.displayMode(for: "top"), .wireframe)
        XCTAssertEqual(reopened.displayMode(for: "front"), .shaded, "an unset pane should open Shaded")
        XCTAssertEqual(reopened.scene.nodes.count, 2)
        XCTAssertEqual(reopened.scene.nodes.map(\.name), ["Shank", "Stone"])
        XCTAssertEqual(reopened.scene.nodes.first(where: { $0.name == "Stone" })?.kind, .stone)
        XCTAssertEqual(reopened.documentURL, url)
    }

    func testAnOlderDocumentWithoutDisplayModesStillDecodes() throws {
        let gold = FFMaterial(name: "Gold")
        let legacy = FFDocument(name: "Legacy", materials: [gold], rootNodes: [FFNode(name: "Bench")])
        var json = try XCTUnwrap(
            String(data: legacy.encoded(), encoding: .utf8)
        )
        // A schema-1 file written before this phase has no displayModes key.
        // Sorted keys put the field first, so it is stripped with its comma.
        json = json.replacingOccurrences(of: "\"displayModes\":{},", with: "")
        XCTAssertFalse(json.contains("displayModes"))
        let decoded = try FFDocument.decoded(from: Data(json.utf8))
        XCTAssertTrue(decoded.displayModes.isEmpty)
    }

    // MARK: - Helpers

    /// What one mode put on screen, measured only on the fixture's silhouette
    /// so the reference grid and the studio background cannot flatter a mode.
    private struct Snapshot {
        let corner: (Int, Int, Int)
        let silhouette: Int
        /// Share of the silhouette that is not the clear colour.
        let filled: Double
        /// Mean red-minus-blue across the silhouette. Gold is strongly warm;
        /// the clay and technical overrides are near-neutral greys.
        let warmth: Double
        let fingerprint: Int
        let pixels: [UInt8]
        /// Pixel indices inside the fixture, so two modes are compared where
        /// they compete and not over the empty studio around them.
        let silhouetteOffsets: [Int]

        func difference(from other: Snapshot) -> Double {
            guard pixels.count == other.pixels.count, !silhouetteOffsets.isEmpty else { return 1 }
            var changed = 0
            for pixel in silhouetteOffsets {
                let offset = pixel * 4
                let delta = abs(Int(pixels[offset]) - Int(other.pixels[offset]))
                    + abs(Int(pixels[offset + 1]) - Int(other.pixels[offset + 1]))
                    + abs(Int(pixels[offset + 2]) - Int(other.pixels[offset + 2]))
                if delta > 24 { changed += 1 }
            }
            return Double(changed) / Double(silhouetteOffsets.count)
        }
    }

    private func signature(for readback: FFViewportReadback, ids: FFPickingReadback) -> Snapshot {
        let pixels = readback.pixels
        let corner = (Int(pixels[2]), Int(pixels[1]), Int(pixels[0]))
        var silhouetteOffsets: [Int] = []
        var filled = 0
        var warmth = 0
        var fingerprint = 0

        for pixel in 0..<(readback.width * readback.height) {
            let offset = pixel * 4
            let b = Int(pixels[offset])
            let g = Int(pixels[offset + 1])
            let r = Int(pixels[offset + 2])
            if ids.objectID(atX: pixel % readback.width, y: pixel / readback.width) != 0 {
                silhouetteOffsets.append(pixel)
                warmth += r - b
                let delta = abs(r - corner.0) + abs(g - corner.1) + abs(b - corner.2)
                if delta > 24 { filled += 1 }
            }
            if pixel % 11 == 0 { fingerprint += r &* 31 &+ g &* 7 &+ b }
        }

        return Snapshot(
            corner: corner,
            silhouette: silhouetteOffsets.count,
            filled: Double(filled) / Double(max(1, silhouetteOffsets.count)),
            warmth: Double(warmth) / Double(max(1, silhouetteOffsets.count)),
            fingerprint: fingerprint,
            pixels: pixels,
            silhouetteOffsets: silhouetteOffsets
        )
    }

    /// A single coarse octahedron sits well clear of the grid. At this scale
    /// its eight large facets keep every mode legible; the shipping torus
    /// carries 6,700 triangles, enough for any edge overlay to read as a solid
    /// mass and hide what the mode is actually doing.
    private func makeFixtureScene() throws -> FFViewportScene {
        let facets = try XCTUnwrap(FFMeshFactory.octahedron(radius: 24))
        let facetMesh = try XCTUnwrap(FFRenderMesh(mesh: facets))
        // Phase 20 colours wireframe line work by layer. The fixture keeps
        // the mode's historical neutral line colour so this suite still
        // measures the wireframe itself rather than the layer palette.
        let neutralLine = FFRGBA(red: 0.72, green: 0.78, blue: 0.82)
        let shank = FFRenderNode(
            name: "Fixture shank",
            mesh: facetMesh,
            transform: Mat4.translation(Vec3(x: 0, y: 34, z: 0)),
            material: .gold,
            layerColor: neutralLine
        )

        let stone = try XCTUnwrap(FFMeshFactory.octahedron(radius: 7))
        let stoneMesh = try XCTUnwrap(FFRenderMesh(mesh: stone))
        let gem = FFRenderNode(
            name: "Fixture stone",
            mesh: stoneMesh,
            transform: Mat4.translation(Vec3(x: 0, y: 72, z: 0)),
            material: .gem,
            kind: .stone,
            layerColor: neutralLine
        )
        return FFViewportScene(nodes: [shank, gem])
    }

    private func attachBenchRenders(renderer: FFMetalViewportRenderer) throws {
        let scene = FFViewportScene.jewelleryDemo
        guard let bounds = scene.bounds else { return XCTFail("bench sample has no bounds") }
        var camera = FFCamera.standard
        camera.frame(bounds: bounds, padding: 1.25)

        for mode in FFDisplayMode.allCases {
            guard let readback = renderer.renderOffscreen(
                width: 480,
                height: 360,
                camera: camera,
                scene: scene,
                mode: mode
            ), let image = uiImage(from: readback) else {
                return XCTFail("\(mode.rawValue) bench render produced no image")
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "phase18-mode-\(mode.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
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
