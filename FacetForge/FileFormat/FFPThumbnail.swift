import Foundation
import UIKit

/// Draws the bundle's preview image.
///
/// A `.ffp` carries a thumbnail so a document browser (Phase 28) can show a
/// grid without opening and rendering every file. The drawing is a deterministic
/// isometric wireframe of the document's own geometry, not a placeholder: the
/// same document always produces the same silhouette, and an edit visibly
/// changes the preview. It runs on the main thread during save and is small
/// (256×192 at scale 1) by design.
enum FFPThumbnail {
    static func png(
        for document: FFDocument,
        size: CGSize = FFPFormat.thumbnailSize
    ) -> Data? {
        let projected = projectedGeometry(for: document)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            draw(projected, in: context.cgContext, size: size)
        }
        return image.pngData()
    }

    // MARK: - Geometry collection

    private struct ScreenTriangle {
        var a: CGPoint
        var b: CGPoint
        var c: CGPoint
        var depth: Double
    }

    private struct Projected {
        var triangles: [ScreenTriangle] = []
        var polylines: [[CGPoint]] = []
        var hasGeometry = false
    }

    /// A world-space edge and the depth of the face that owns it.
    private struct WorldTriangle {
        var a: Vec3
        var b: Vec3
        var c: Vec3
        var depth: Double
    }

    private struct WorldPolyline {
        var points: [Vec3]
        var depth: Double
    }

    private static func projectedGeometry(for document: FFDocument) -> Projected {
        let world = worldGeometry(for: document)
        var points: [Vec3] = []
        world.triangles.forEach { points.append(contentsOf: [$0.a, $0.b, $0.c]) }
        world.polylines.forEach { points.append(contentsOf: $0.points) }
        guard let first = points.first else { return Projected() }

        var bounds = CGRect(origin: projection(first), size: .zero)
        for point in points.dropFirst() {
            bounds = bounds.union(CGRect(origin: projection(point), size: .zero))
        }

        let transform = FitTransform(bounds: bounds, size: FFPFormat.thumbnailSize)
        var result = Projected()
        result.hasGeometry = true
        result.triangles = world.triangles
            .map { triangle in
                ScreenTriangle(
                    a: transform.apply(projection(triangle.a)),
                    b: transform.apply(projection(triangle.b)),
                    c: transform.apply(projection(triangle.c)),
                    depth: triangle.depth
                )
            }
            .sorted { $0.depth < $1.depth }
        result.polylines = world.polylines.compactMap { line in
            let points = line.points.map { transform.apply(projection($0)) }
            return points.count > 1 ? points : nil
        }
        return result
    }

    private static func worldGeometry(for document: FFDocument) -> (
        triangles: [WorldTriangle],
        polylines: [WorldPolyline]
    ) {
        var triangles: [WorldTriangle] = []
        var polylines: [WorldPolyline] = []

        func visit(_ node: FFNode, parent: Mat4) {
            let world = parent * node.transform.matrix
            if let payload = node.geometry?.mesh {
                let positions = payload.positions.map { world.transformedPoint($0.vector) }
                for triangle in payload.triangles {
                    guard positions.indices.contains(triangle.a),
                          positions.indices.contains(triangle.b),
                          positions.indices.contains(triangle.c) else { continue }
                    let a = positions[triangle.a]
                    let b = positions[triangle.b]
                    let c = positions[triangle.c]
                    triangles.append(WorldTriangle(
                        a: a,
                        b: b,
                        c: c,
                        depth: (a.z + b.z + c.z) / 3
                    ))
                }
            }
            if let payload = node.geometry?.curve {
                for segment in payload.segments {
                    let points = segment.controlPoints.map { world.transformedPoint($0.vector) }
                    guard let first = points.first, points.count > 1 else { continue }
                    var line = points
                    if payload.isClosed { line.append(first) }
                    let depth = line.map(\.z).reduce(0, +) / Double(line.count)
                    polylines.append(WorldPolyline(points: line, depth: depth))
                }
            }
            node.children.forEach { visit($0, parent: world) }
        }
        document.rootNodes.forEach { visit($0, parent: .identity) }
        return (triangles, polylines)
    }

    private static func projection(_ point: Vec3) -> CGPoint {
        CGPoint(
            x: (point.x - point.y) * 0.866_025_403_784_438_6,
            y: (point.x + point.y) * 0.5 - point.z
        )
    }

    private struct FitTransform {
        let scale: Double
        let offsetX: Double
        let offsetY: Double

        init(bounds: CGRect, size: CGSize) {
            let padding = 18.0
            let width = max(Double(bounds.width), 1e-9)
            let height = max(Double(bounds.height), 1e-9)
            scale = min(
                (Double(size.width) - 2 * padding) / width,
                (Double(size.height) - 2 * padding) / height
            )
            offsetX = (Double(size.width) - width * scale) / 2 - Double(bounds.minX) * scale
            offsetY = (Double(size.height) - height * scale) / 2 + Double(bounds.maxY) * scale
        }

        /// Projects an isometric point, whose y grows upward, into the canvas's
        /// downward-growing coordinates.
        func apply(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: Double(point.x) * scale + offsetX,
                y: offsetY - Double(point.y) * scale
            )
        }
    }

    // MARK: - Drawing

    private static func draw(_ geometry: Projected, in context: CGContext, size: CGSize) {
        context.setFillColor(UIColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        if !geometry.hasGeometry {
            drawEmptyMark(in: context, size: size)
            return
        }

        let gold = UIColor(red: 0.83, green: 0.68, blue: 0.33, alpha: 1)
        context.setFillColor(gold.withAlphaComponent(0.20).cgColor)
        context.setStrokeColor(gold.withAlphaComponent(0.55).cgColor)
        context.setLineWidth(0.6)
        for triangle in geometry.triangles {
            context.beginPath()
            context.move(to: triangle.a)
            context.addLine(to: triangle.b)
            context.addLine(to: triangle.c)
            context.closePath()
            context.drawPath(using: .fillStroke)
        }

        context.setStrokeColor(gold.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(0.5)
        for line in geometry.polylines {
            guard let first = line.first else { continue }
            context.beginPath()
            context.move(to: first)
            for point in line.dropFirst() {
                context.addLine(to: point)
            }
            context.strokePath()
        }
    }

    private static func drawEmptyMark(in context: CGContext, size: CGSize) {
        let gold = UIColor(red: 0.83, green: 0.68, blue: 0.33, alpha: 0.45)
        context.setStrokeColor(gold.cgColor)
        context.setLineWidth(1)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.22
        context.beginPath()
        context.move(to: CGPoint(x: center.x, y: center.y - radius))
        context.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        context.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        context.addLine(to: CGPoint(x: center.x - radius, y: center.y))
        context.closePath()
        context.strokePath()
    }
}
