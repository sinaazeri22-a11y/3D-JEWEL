import Foundation

/// The binary geometry payload used inside an `.ffp` buffer.
///
/// Geometry is the only part of a document that grows without bound, so it does
/// not live in the JSON manifest. Each node's payload is one self-describing
/// block; the manifest records the node id, buffer, offset and length. Blocks
/// are little-endian and fixed-layout so a reader validates every count before
/// touching memory, and a truncated block is a reported error rather than a
/// partly filled mesh.
enum FFPGeometryCodec {
    static let meshMagic: UInt32 = 0x314D_4646 // "FFM1"
    static let curveMagic: UInt32 = 0x3143_4646 // "FFC1"

    enum Kind: String, CaseIterable, Sendable {
        case curve
        case mesh
    }

    static func kind(of geometry: FFNodeGeometry) -> Kind {
        switch geometry {
        case .curve: return .curve
        case .mesh: return .mesh
        }
    }

    static func encode(_ geometry: FFNodeGeometry) throws -> Data {
        switch geometry {
        case .mesh(let payload):
            return try encodeMesh(payload)
        case .curve(let payload):
            return try encodeCurve(payload)
        }
    }

    static func decode(_ data: Data, expecting kind: Kind) throws -> FFNodeGeometry {
        switch kind {
        case .mesh: return .mesh(try decodeMesh(data))
        case .curve: return .curve(try decodeCurve(data))
        }
    }

    // MARK: - Mesh

    private static func encodeMesh(_ payload: FFMeshPayload) throws -> Data {
        var writer = FFPByteWriter()
        writer.u32(meshMagic)
        writer.u32(count: payload.positions.count)
        writer.u32(count: payload.triangles.count)
        for point in payload.positions {
            try writer.finite(point.x)
            try writer.finite(point.y)
            try writer.finite(point.z)
        }
        for triangle in payload.triangles {
            guard triangle.a >= 0, triangle.b >= 0, triangle.c >= 0,
                  triangle.a <= Int(UInt32.max), triangle.b <= Int(UInt32.max),
                  triangle.c <= Int(UInt32.max) else {
                throw FFPFormatError.corruptGeometry("triangle index out of range")
            }
            writer.u32(UInt32(triangle.a))
            writer.u32(UInt32(triangle.b))
            writer.u32(UInt32(triangle.c))
        }
        return writer.data
    }

    private static func decodeMesh(_ data: Data) throws -> FFMeshPayload {
        var reader = FFPByteReader(data)
        guard try reader.u32() == meshMagic else {
            throw FFPFormatError.corruptGeometry("mesh block has the wrong magic")
        }
        let positionCount = try reader.count(maximum: 100_000_000 / 24)
        let triangleCount = try reader.count(maximum: 100_000_000 / 12)
        let expected = 12 + positionCount * 24 + triangleCount * 12
        guard data.count == expected else {
            throw FFPFormatError.corruptGeometry(
                "mesh block is \(data.count) bytes, header says \(expected)"
            )
        }

        var positions: [FFPoint3] = []
        positions.reserveCapacity(positionCount)
        for _ in 0..<positionCount {
            let x = try reader.f64()
            let y = try reader.f64()
            let z = try reader.f64()
            positions.append(FFPoint3(x: x, y: y, z: z))
        }

        var triangles: [FFTriangleIndex] = []
        triangles.reserveCapacity(triangleCount)
        for _ in 0..<triangleCount {
            let a = try reader.u32()
            let b = try reader.u32()
            let c = try reader.u32()
            triangles.append(FFTriangleIndex(a: Int(a), b: Int(b), c: Int(c)))
        }
        return FFMeshPayload(positions: positions, triangles: triangles)
    }

    // MARK: - Curves

    private static func encodeCurve(_ payload: FFCurvePayload) throws -> Data {
        var writer = FFPByteWriter()
        writer.u32(curveMagic)
        writer.u32(payload.isClosed ? 1 : 0)
        writer.u32(count: payload.segments.count)
        for segment in payload.segments {
            writer.u32(segment.kind == .bezier ? 0 : 1)
            writer.u32(count: segment.controlPoints.count)
            writer.u32(count: segment.weights.count)
            writer.u32(count: segment.knots.count)
            writer.u32(UInt32(max(segment.degree, 0)))
            for point in segment.controlPoints {
                try writer.finite(point.x)
                try writer.finite(point.y)
            }
            for weight in segment.weights {
                try writer.finite(weight)
            }
            for knot in segment.knots {
                try writer.finite(knot)
            }
        }
        return writer.data
    }

    private static func decodeCurve(_ data: Data) throws -> FFCurvePayload {
        var reader = FFPByteReader(data)
        guard try reader.u32() == curveMagic else {
            throw FFPFormatError.corruptGeometry("curve block has the wrong magic")
        }
        let flags = try reader.u32()
        guard flags & ~1 == 0 else {
            throw FFPFormatError.corruptGeometry("curve block has unknown flags \(flags)")
        }
        let segmentCount = try reader.count(maximum: 1_000_000)
        var segments: [FFCurveSegment] = []
        segments.reserveCapacity(segmentCount)
        for _ in 0..<segmentCount {
            let kindValue = try reader.u32()
            guard let kind = FFCurveKind(rawValue: kindValue == 0 ? "bezier" : "nurbs") else {
                throw FFPFormatError.corruptGeometry("curve block has an unknown segment kind")
            }
            let pointCount = try reader.count(maximum: 1_000_000)
            let weightCount = try reader.count(maximum: 1_000_000)
            let knotCount = try reader.count(maximum: 1_000_000)
            let degree = try reader.count(maximum: 64)

            var controlPoints: [FFPoint2] = []
            controlPoints.reserveCapacity(pointCount)
            for _ in 0..<pointCount {
                let x = try reader.f64()
                let y = try reader.f64()
                controlPoints.append(FFPoint2(x: x, y: y))
            }
            var weights: [Double] = []
            weights.reserveCapacity(weightCount)
            for _ in 0..<weightCount {
                weights.append(try reader.f64())
            }
            var knots: [Double] = []
            knots.reserveCapacity(knotCount)
            for _ in 0..<knotCount {
                knots.append(try reader.f64())
            }
            segments.append(FFCurveSegment(
                kind: kind,
                controlPoints: controlPoints,
                weights: weights,
                degree: degree,
                knots: knots
            ))
        }
        guard reader.isAtEnd else {
            throw FFPFormatError.corruptGeometry("curve block has \(reader.remaining) trailing bytes")
        }
        return FFCurvePayload(segments: segments, isClosed: flags & 1 == 1)
    }
}

// MARK: - Byte primitives

private struct FFPByteWriter {
    private(set) var data = Data()

    mutating func u32(_ value: UInt32) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }

    mutating func u32(count: Int) {
        u32(UInt32(clamping: count))
    }

    mutating func f64(_ value: Double) {
        data.append(contentsOf: withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) })
    }

    mutating func finite(_ value: Double) throws {
        guard value.isFinite else {
            throw FFPFormatError.corruptGeometry("geometry contains a non-finite coordinate")
        }
        f64(value)
    }
}

private struct FFPByteReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { offset == data.count }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else {
            throw FFPFormatError.corruptGeometry("block ends inside a 32-bit field")
        }
        let value = UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
        offset += 4
        return value
    }

    mutating func f64() throws -> Double {
        var bits: UInt64 = 0
        guard remaining >= 8 else {
            throw FFPFormatError.corruptGeometry("block ends inside a 64-bit field")
        }
        for index in 0..<8 {
            bits |= UInt64(data[offset + index]) << (8 * UInt64(index))
        }
        offset += 8
        let value = Double(bitPattern: bits)
        guard value.isFinite else {
            throw FFPFormatError.corruptGeometry("block contains a non-finite coordinate")
        }
        return value
    }

    /// Reads a count and rejects one that cannot fit in the remaining bytes.
    mutating func count(maximum: Int) throws -> Int {
        let value = try u32()
        let count = Int(value)
        guard count <= maximum else {
            throw FFPFormatError.corruptGeometry("block declares \(count) elements")
        }
        return count
    }
}
