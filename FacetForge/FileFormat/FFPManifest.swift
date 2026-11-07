import CoreGraphics
import CryptoKit
import Foundation

/// Errors a reader reports instead of loading a document it cannot trust.
enum FFPFormatError: Error, Equatable {
    case unsupportedFormatVersion(Int)
    case malformedManifest(String)
    case corruptGeometry(String)
    case missingEntry(String)
    case checksumMismatch(String)
    case unsafePath(String)
}

/// Everything a reader needs to rewrite a bundle without dropping what it did
/// not understand. The writer only preserves fields and files; typed values
/// always win, so an edit is never shadowed by a stale preserved copy.
struct FFPBundlePreservation: Equatable, Sendable {
    var manifest: FFPJSONValue
    var document: FFPJSONValue
}

/// The `.ffp` v1 bundle constants and the manifest codec.
enum FFPFormat {
    static let identifier = "facetforge-document"
    static let version = 1
    static let manifestName = "manifest.json"
    static let checksumsName = "checksums.json"
    static let thumbnailName = "preview.png"
    static let geometryDirectory = "geometry"
    /// A single geometry file is capped so a large document cannot produce one
    /// multi-gigabyte blob that a reader must map whole. A block bigger than
    /// the cap still gets a buffer of its own.
    static let maximumBufferBytes = 4 * 1024 * 1024
    static let thumbnailSize = CGSize(width: 256, height: 192)

    /// Names the writer owns. Every other entry in an existing bundle is
    /// copied through unchanged, which is how a future minor writer's files
    /// survive a save by this version.
    static var ownedNames: Set<String> {
        [manifestName, checksumsName, thumbnailName, geometryDirectory]
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// Geometry reference table entry. Offsets are byte offsets inside one buffer
/// and lengths are the exact block size, so a reader never scans.
struct FFPGeometryReference: Equatable, Sendable {
    var nodeID: UUID
    var buffer: Int
    var offset: Int
    var length: Int
    var kind: FFPGeometryCodec.Kind
}

/// A fully built manifest plus the bytes it references.
struct FFPManifestPayload {
    var manifest: FFPJSONValue
    var buffers: [Data]
    var references: [FFPGeometryReference]

    var bufferPaths: [String] {
        buffers.indices.map { String(format: "geometry/geometry-%03d.bin", $0) }
    }
}

enum FFPManifest {
    // MARK: - Write

    static func makePayload(
        document: FFDocument,
        preservation: FFPBundlePreservation?,
        now: Date = Date()
    ) throws -> FFPManifestPayload {
        let typedDocument = FFPJSONValue.merge(
            typed: strippingGeometry(try FFPJSONValue.parse(document.encoded())),
            over: preservation.map { strippingGeometry($0.document) }
        )

        var buffers: [Data] = []
        var references: [FFPGeometryReference] = []
        for (nodeID, geometry) in orderedGeometry(in: document.rootNodes) {
            let block = try FFPGeometryCodec.encode(geometry)
            if buffers.isEmpty
                || (buffers[buffers.count - 1].count > 0
                    && buffers[buffers.count - 1].count + block.count > FFPFormat.maximumBufferBytes) {
                buffers.append(Data())
            }
            let bufferIndex = buffers.count - 1
            let offset = buffers[bufferIndex].count
            buffers[bufferIndex].append(block)
            references.append(FFPGeometryReference(
                nodeID: nodeID,
                buffer: bufferIndex,
                offset: offset,
                length: block.count,
                kind: FFPGeometryCodec.kind(of: geometry)
            ))
        }

        let geometry = geometryObject(buffers: buffers, references: references)
        var fields: [String: FFPJSONValue] = [
            "format": .string(FFPFormat.identifier),
            "formatVersion": .int(FFPFormat.version),
            "documentVersion": .int(document.schemaVersion),
            "modifiedAt": .string(FFPFormat.timestamp(now)),
            "generator": .object([
                "name": .string("FacetForge"),
                "format": .string("ffp")
            ]),
            "document": typedDocument,
            "geometry": geometry
        ]
        if let createdAt = preservation?.manifest["createdAt"]?.stringValue {
            fields["createdAt"] = .string(createdAt)
        } else {
            fields["createdAt"] = .string(FFPFormat.timestamp(now))
        }

        var merged = FFPJSONValue.merge(typed: .object(fields), over: preservation?.manifest)
        // The manifest's own identity and its geometry table are always this
        // writer's values; a preserved copy must never shadow them.
        merged = merged
            .setting("format", to: .string(FFPFormat.identifier))
            .setting("formatVersion", to: .int(FFPFormat.version))
            .setting("documentVersion", to: .int(document.schemaVersion))
            .setting("modifiedAt", to: .string(FFPFormat.timestamp(now)))
            .setting("document", to: typedDocument)
            .setting("geometry", to: geometry)

        return FFPManifestPayload(manifest: merged, buffers: buffers, references: references)
    }

    private static func orderedGeometry(in roots: [FFNode]) -> [(UUID, FFNodeGeometry)] {
        var result: [(UUID, FFNodeGeometry)] = []
        func visit(_ node: FFNode) {
            if let geometry = node.geometry {
                result.append((node.id, geometry))
            }
            node.children.forEach(visit)
        }
        roots.forEach(visit)
        return result
    }

    private static func geometryObject(
        buffers: [Data],
        references: [FFPGeometryReference]
    ) -> FFPJSONValue {
        let bufferValues = buffers.enumerated().map { index, data -> FFPJSONValue in
            .object([
                "path": .string(String(format: "geometry/geometry-%03d.bin", index)),
                "byteLength": .int(data.count),
                "sha256": .string(FFPSHA256.hex(data))
            ])
        }
        let referenceValues = references.map { reference -> FFPJSONValue in
            .object([
                "nodeID": .string(reference.nodeID.uuidString),
                "buffer": .int(reference.buffer),
                "offset": .int(reference.offset),
                "length": .int(reference.length),
                "kind": .string(reference.kind.rawValue)
            ])
        }
        return .object([
            "buffers": .array(bufferValues),
            "nodes": .array(referenceValues)
        ])
    }

    /// Removes `geometry` from every node object in a document tree. Geometry
    /// is represented by the buffer table, not by inline JSON; stripping it
    /// here is also what stops a preserved tree from reintroducing an old copy.
    static func strippingGeometry(_ tree: FFPJSONValue) -> FFPJSONValue {
        switch tree {
        case .object(let values):
            var result: [String: FFPJSONValue] = [:]
            for (key, value) in values where key != "geometry" {
                result[key] = strippingGeometry(value)
            }
            return .object(result)
        case .array(let values):
            return .array(values.map(strippingGeometry))
        default:
            return tree
        }
    }

    // MARK: - Read

    /// Reads a manifest tree and its buffers into a document plus the token
    /// needed to preserve unknown fields on the next save.
    static func read(
        manifest: FFPJSONValue,
        loadBuffer: (String) throws -> Data
    ) throws -> (document: FFDocument, preservation: FFPBundlePreservation) {
        guard let values = manifest.objectValue else {
            throw FFPFormatError.malformedManifest("manifest is not a JSON object")
        }
        guard values["format"]?.stringValue == FFPFormat.identifier else {
            throw FFPFormatError.malformedManifest("manifest is not a FacetForge document")
        }
        guard let version = values["formatVersion"]?.intValue else {
            throw FFPFormatError.malformedManifest("manifest has no integer formatVersion")
        }
        guard version <= FFPFormat.version else {
            throw FFPFormatError.unsupportedFormatVersion(version)
        }
        guard var documentTree = values["document"] else {
            throw FFPFormatError.malformedManifest("manifest has no document")
        }

        var buffers: [Data] = []
        if let geometry = values["geometry"]?.objectValue {
            guard let bufferValues = geometry["buffers"]?.arrayValue else {
                throw FFPFormatError.malformedManifest("geometry has no buffer table")
            }
            for bufferValue in bufferValues {
                guard let entry = bufferValue.objectValue,
                      let path = entry["path"]?.stringValue,
                      let byteLength = entry["byteLength"]?.intValue else {
                    throw FFPFormatError.malformedManifest("geometry buffer entry is incomplete")
                }
                try validateRelativePath(path)
                let data = try loadBuffer(path)
                guard data.count == byteLength else {
                    throw FFPFormatError.malformedManifest(
                        "\(path) is \(data.count) bytes, manifest says \(byteLength)"
                    )
                }
                if let expected = entry["sha256"]?.stringValue,
                   expected != FFPSHA256.hex(data) {
                    throw FFPFormatError.checksumMismatch(path)
                }
                buffers.append(data)
            }
        }

        var geometryByNode: [UUID: FFNodeGeometry] = [:]
        if let nodes = values["geometry"]?["nodes"]?.arrayValue {
            for nodeValue in nodes {
                guard let entry = nodeValue.objectValue,
                      let idString = entry["nodeID"]?.stringValue,
                      let nodeID = UUID(uuidString: idString),
                      let bufferIndex = entry["buffer"]?.intValue,
                      let offset = entry["offset"]?.intValue,
                      let length = entry["length"]?.intValue,
                      let kindName = entry["kind"]?.stringValue,
                      let kind = FFPGeometryCodec.Kind(rawValue: kindName) else {
                    throw FFPFormatError.malformedManifest("geometry reference is incomplete")
                }
                guard buffers.indices.contains(bufferIndex) else {
                    throw FFPFormatError.malformedManifest("geometry references buffer \(bufferIndex)")
                }
                let buffer = buffers[bufferIndex]
                guard offset >= 0, length > 0, offset <= buffer.count,
                      length <= buffer.count - offset else {
                    throw FFPFormatError.corruptGeometry("geometry slice is outside its buffer")
                }
                let block = buffer.subdata(in: offset..<(offset + length))
                geometryByNode[nodeID] = try FFPGeometryCodec.decode(block, expecting: kind)
            }
        }

        documentTree = try attachingGeometry(geometryByNode, to: documentTree)
        let document = try FFDocument.decoded(from: documentTree.encoded())
        return (
            document,
            FFPBundlePreservation(manifest: manifest, document: documentTree)
        )
    }

    private static func attachingGeometry(
        _ geometry: [UUID: FFNodeGeometry],
        to tree: FFPJSONValue
    ) throws -> FFPJSONValue {
        switch tree {
        case .object(var values):
            if let idString = values["id"]?.stringValue,
               let id = UUID(uuidString: idString),
               let payload = geometry[id] {
                let encoded = try JSONEncoder().encode(payload)
                values["geometry"] = try FFPJSONValue.parse(encoded)
            }
            var result: [String: FFPJSONValue] = [:]
            for (key, value) in values {
                result[key] = try attachingGeometry(geometry, to: value)
            }
            return .object(result)
        case .array(let values):
            return .array(try values.map { try attachingGeometry(geometry, to: $0) })
        default:
            return tree
        }
    }

    static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.split(separator: "/").contains(".."),
              !path.split(separator: "/").contains(".") else {
            throw FFPFormatError.unsafePath(path)
        }
    }
}

enum FFPSHA256 {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
