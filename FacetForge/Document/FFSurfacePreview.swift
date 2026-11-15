import Dispatch
import Foundation

/// The sampled source of one preview: which document node it follows and the
/// profile sampled from that node's payload.
///
/// The profile is sampled once at begin. A drag rebuilds triangles, never the
/// sample: a 200-span profile would otherwise pay the sampling cost on every
/// touch event, which is exactly what the Phase 54 cost budget forbids.
struct FFSurfaceSource: Equatable, Sendable {
    let nodeID: UUID
    let profile: FFSurfaceSweepProfile
}

/// What the viewport draws and the card reports while a profile sweep preview
/// is open.
///
/// This is session state, never document state. A preview cannot be undone
/// because it commits nothing: the document, its history and its journal are
/// untouched for the whole lifetime of this value.
struct FFSurfacePreview: Equatable, Sendable {
    let nodeID: UUID
    let nodeName: String
    let mode: FFSweepMode
    let height: Double
    let angleDegrees: Double
    let profilePointCount: Int
    let isClosedProfile: Bool
    /// Phase 57's extrusion parameters, the ones the commit will bake. Nil in
    /// revolve mode, which has its own parameters below.
    let extrusion: FFExtrusionParameters?
    /// Phase 58's revolution parameters, the ones the commit will bake. Nil in
    /// extrusion mode, which has no angle of this kind.
    let revolve: FFRevolveParameters?
    /// The sweep in the profile plane's own coordinates.
    let mesh: IndexedMesh
    /// The renderer's form of the same mesh, built once per update.
    let renderMesh: FFRenderMesh
    /// The source node's world placement. The preview follows its profile even
    /// after the node has been moved or scaled.
    let transform: Mat4
    /// The profile centroid pushed to the surface's own plane, in world space.
    /// The drag handle sits here.
    let handleWorld: Vec3
    /// How many successful rebuilds this preview has shown, including the one
    /// that opened it. A drag assertion reads this.
    let updates: Int
    /// How long this update took, sampling excluded.
    let buildMilliseconds: Double
    /// Content hash of the mesh, so the renderer's buffer cache can tell two
    /// previews with the same vertex count apart.
    let meshSignature: UInt64

    var vertexCount: Int { mesh.positions.count }
    var triangleCount: Int { mesh.triangleCount }
    var parameter: Double { mode == .extrude ? height : angleDegrees }

    /// A stable renderer identity per source node. Derived rather than random so
    /// a re-opened preview on the same curve reuses its buffers, and distinct
    /// from the source node's own id so the preview never fights the document
    /// node for a cache slot.
    var renderID: UUID {
        Self.renderID(for: nodeID)
    }

    static func renderID(for nodeID: UUID) -> UUID {
        var bytes = nodeID.uuid
        bytes.0 = 0xF5
        bytes.1 = 0xAC
        bytes.15 = bytes.15 ^ 0x54
        return UUID(uuid: bytes)
    }

    /// The ghost node the viewport draws beside the document geometry. It is a
    /// preview in the scene's separate preview list, so it is never pickable
    /// and never enters the document.
    var renderNode: FFRenderNode {
        FFRenderNode(
            id: renderID,
            name: "\(nodeName) preview",
            mesh: renderMesh,
            transform: transform,
            material: FFRenderMaterial(
                baseColor: FFRGBA(red: 0.36, green: 0.80, blue: 0.93, alpha: 0.46),
                metallic: 0.08,
                roughness: 0.32
            ),
            kind: .solid,
            isVisible: true,
            layerColor: FFRGBA(red: 0.36, green: 0.80, blue: 0.93, alpha: 0.46),
            cacheSignature: meshSignature
        )
    }

    func summary(unit: FFLengthUnit) -> String {
        switch mode {
        case .extrude:
            var line = "\(mode.label) \(FFPrecision.lengthString(millimetres: height, unit: unit))"
            if let detail = extrusion?.detail { line += " · \(detail)" }
            if extrusion?.isSymmetric == true { line += " · symmetric" }
            if extrusion?.direction == .reversed, extrusion?.isSymmetric != true {
                line += " · reversed"
            }
            if extrusion?.caps == .open { line += " · open" }
            return line
        case .revolve:
            var line = "\(mode.label) \(FFPrecision.angleString(degrees: angleDegrees))"
            if let detail = revolve?.detail { line += " · \(detail)" }
            return line
        }
    }

    var detail: String {
        "\(triangleCount) triangles · update \(updates)"
    }

    /// The card's single spoken line: the mode, its parameter and what the
    /// rebuild produced. Updates are included because the acceptance is about
    /// events, and a readout is how a test can see them.
    func valueLabel(unit: FFLengthUnit) -> String {
        "\(summary(unit: unit)) · \(detail)"
    }
}
