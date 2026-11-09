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
    /// A version-2 bundle left an owned file out of `checksums.json`. Without
    /// an entry the file's bytes are never verified, which is the one way a
    /// document body could change without the reader noticing.
    case unlistedEntry(String)
    /// A version-2 geometry reference names a node the document does not have.
    case danglingGeometryReference(String)
}

extension FFPFormatError {
    /// A newer format is never masked by an older saved copy, and an unsafe
    /// path is a security failure rather than damage. Every other case means
    /// bytes on disk are wrong, which is what the last-good save is for.
    var allowsLastGoodRecovery: Bool {
        switch self {
        case .unsupportedFormatVersion, .unsafePath:
            return false
        case .malformedManifest, .corruptGeometry, .missingEntry, .checksumMismatch,
             .unlistedEntry, .danglingGeometryReference:
            return true
        }
    }

    var damagedEntry: String? {
        switch self {
        case .missingEntry(let path), .checksumMismatch(let path), .unlistedEntry(let path):
            return path
        case .malformedManifest, .corruptGeometry, .unsupportedFormatVersion, .unsafePath,
             .danglingGeometryReference:
            return nil
        }
    }

    var recoveryDescription: String {
        switch self {
        case .unsupportedFormatVersion(let version):
            return "format version \(version) is newer than this app"
        case .malformedManifest(let detail):
            return "manifest is malformed (\(detail))"
        case .corruptGeometry(let detail):
            return "geometry is corrupt (\(detail))"
        case .missingEntry(let path):
            return "\(path) is missing"
        case .checksumMismatch(let path):
            return "checksum mismatch for \(path)"
        case .unsafePath(let path):
            return "unsafe path \(path)"
        case .unlistedEntry(let path):
            return "\(path) is not listed in checksums.json"
        case .danglingGeometryReference(let identifier):
            return "the geometry table names node \(identifier), which the document does not contain"
        }
    }
}

/// What happened when a damaged bundle was replaced by its last good save in
/// memory. The damaged bundle is never deleted or rewritten by a read.
struct FFPRecoveryNotice: Equatable, Sendable {
    var message: String
    var damagedEntry: String?
}

/// Everything a reader needs to rewrite a bundle without dropping what it did
/// not understand. The writer only preserves fields and files; typed values
/// always win, so an edit is never shadowed by a stale preserved copy.
struct FFPBundlePreservation: Equatable, Sendable {
    var manifest: FFPJSONValue
    var document: FFPJSONValue
    /// Unknown bundle files, keyed by relative path. Carrying the bytes in the
    /// token is what lets a save to a new destination keep them; the writer
    /// also consults the destination for files it does not own.
    var files: [String: Data] = [:]
}

/// The `.ffp` bundle constants and the manifest codec.
enum FFPFormat {
    static let identifier = "facetforge-document"
    /// The container revision this build writes.
    ///
    /// Version 2 tightens two reader rules that version 1 assumed: every owned
    /// file is listed in `checksums.json`, and the geometry table resolves
    /// one-to-one against the document. Both are container-level, so the
    /// document model stays at schema version 1 and no state hash moves.
    static let version = 2
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
    /// needed to preserve unknown fields on the next save. The version is
    /// returned so the bundle can apply that revision's container rules.
    static func read(
        manifest: FFPJSONValue,
        loadBuffer: (String) throws -> Data
    ) throws -> (document: FFDocument, preservation: FFPBundlePreservation, formatVersion: Int) {
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
        guard version >= 1 else {
            throw FFPFormatError.malformedManifest("formatVersion \(version) is not a known revision")
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
                let geometry = try FFPGeometryCodec.decode(block, expecting: kind)
                if version >= 2, geometryByNode[nodeID] != nil {
                    throw FFPFormatError.malformedManifest(
                        "geometry reference for \(idString) appears twice"
                    )
                }
                geometryByNode[nodeID] = geometry
            }
        }

        if version >= 2 {
            let nodes = nodeIdentifiers(in: documentTree)
            for nodeID in geometryByNode.keys.sorted(by: { $0.uuidString < $1.uuidString })
            where !nodes.contains(nodeID) {
                throw FFPFormatError.danglingGeometryReference(nodeID.uuidString)
            }
        }

        documentTree = try attachingGeometry(geometryByNode, to: documentTree)
        let document = try FFDocument.decoded(from: documentTree.encoded())
        return (
            document,
            FFPBundlePreservation(manifest: manifest, document: documentTree),
            version
        )
    }

    /// Every node id in a document tree. Used by the version-2 geometry rule:
    /// a reference that no node answers would silently drop its block.
    private static func nodeIdentifiers(in tree: FFPJSONValue) -> Set<UUID> {
        var result: Set<UUID> = []
        func visit(_ value: FFPJSONValue) {
            guard case .object(let values) = value else { return }
            if let idString = values["id"]?.stringValue,
               let id = UUID(uuidString: idString) {
                result.insert(id)
            }
            for child in values["children"]?.arrayValue ?? [] {
                visit(child)
            }
        }
        for node in tree["rootNodes"]?.arrayValue ?? [] {
            visit(node)
        }
        return result
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
