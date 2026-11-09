import RealityKit
import SwiftUI
import UIKit

/// A RealityKit host for the same renderable scene the Metal viewport draws.
///
/// The shipping viewport is Metal: it owns the outline, the shadow and the
/// grid. This host exists so a scene can be handed to RealityKit unchanged for
/// AR and future spatial modes, and so the mesh feed is tested against a second
/// consumer. The scene is treated as immutable; a new scene replaces the view.
struct FFRealityViewport: View {
    let scene: FFViewportScene

    var body: some View {
        RealityView { content in
            content.add(FFRealitySceneBuilder.makeRoot(for: scene))
        }
        .accessibilityIdentifier("shell.viewport.reality")
    }
}

/// Translates kernel meshes into RealityKit's mesh descriptors. Kept separate
/// from the SwiftUI host so the entity tree can be built and asserted without
/// a rendering surface.
@MainActor
enum FFRealitySceneBuilder {
    static func makeRoot(for scene: FFViewportScene) -> Entity {
        let root = Entity()
        root.name = "FacetForgeScene"

        for node in scene.nodes {
            let surfaces: [(FFRenderMesh, FFRenderMaterial, String)] = node.parts.isEmpty
                ? [(node.mesh, node.material, node.name)]
                : node.parts.map { ($0.mesh, $0.material, "\(node.name) · material") }
            for (mesh, surface, name) in surfaces {
                guard let resource = try? MeshResource.generate(from: [descriptor(for: mesh)]) else {
                    continue
                }
                let material = SimpleMaterial(
                    color: uiColor(for: surface),
                    isMetallic: surface.metallic > 0.5
                )
                let entity = ModelEntity(mesh: resource, materials: [material])
                entity.name = name
                entity.transform = Transform(matrix: node.transform.simdMatrix)
                root.addChild(entity)
            }
        }
        return root
    }

    static func descriptor(for mesh: FFRenderMesh) -> MeshDescriptor {
        var descriptor = MeshDescriptor(name: "FacetForgeMesh")
        descriptor.positions = MeshBuffers.Positions(
            mesh.positions.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
        )
        descriptor.normals = MeshBuffers.Normals(
            mesh.normals.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
        )
        descriptor.primitives = .triangles(mesh.indices)
        return descriptor
    }

    static func uiColor(for material: FFRenderMaterial) -> UIColor {
        UIColor(
            red: CGFloat(FFMath.clamp(material.baseColor.red, to: 0...1)),
            green: CGFloat(FFMath.clamp(material.baseColor.green, to: 0...1)),
            blue: CGFloat(FFMath.clamp(material.baseColor.blue, to: 0...1)),
            alpha: CGFloat(FFMath.clamp(material.baseColor.alpha, to: 0...1))
        )
    }
}
