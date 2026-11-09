import Foundation

/// The four original Phase 37 starting documents: a solitaire ring, a plain
/// band, a pendant and a signet.
///
/// A template is not a special document type. Each case builds an ordinary
/// `FFDocument` whose ids are fixed, so the same template encodes to the same
/// bytes in every process and a snapshot test can compare a template against
/// itself. The session writes that document to a real `.ffp` bundle and then
/// opens the bundle through the normal reader, so a document started from a
/// template is indistinguishable from any other saved file: undo, autosave,
/// the journal, the browser and the format all take their usual paths.
enum FFDocumentTemplate: String, CaseIterable, Identifiable, Sendable {
    case solitaireRing = "solitaire-ring"
    case plainBand = "plain-band"
    case pendant = "pendant"
    case signet = "signet"

    var id: String { rawValue }

    /// The document title inside the bundle and the base of the first file the
    /// session writes. A second copy of the same template gets a numbered name,
    /// exactly like duplicating any other document.
    var title: String {
        switch self {
        case .solitaireRing: return "Solitaire Ring"
        case .plainBand: return "Plain Band"
        case .pendant: return "Pendant"
        case .signet: return "Signet"
        }
    }

    /// One line for the browser's template menu. It describes what the user is
    /// starting from, not a vendor product.
    var summary: String {
        switch self {
        case .solitaireRing: return "Four-claw setting and a full halo"
        case .plainBand: return "Comfort-fit band, no setting"
        case .pendant: return "Bail, girdle collar and a pear drop"
        case .signet: return "Rectangular face with a monogram field"
        }
    }

    var fileBaseName: String { title }

    /// The template as document state. Every id is derived from the template's
    /// own seed, so a rebuild never changes the encoding, and every reference
    /// (material, layer, face group) is built in the same call as the node that
    /// uses it.
    func makeDocument() -> FFDocument {
        switch self {
        case .solitaireRing: return Self.solitaireRing()
        case .plainBand: return Self.plainBand()
        case .pendant: return Self.pendant()
        case .signet: return Self.signet()
        }
    }

    // MARK: - Documents

    private static func solitaireRing() -> FFDocument {
        let metal = FFLayer(
            id: FFTemplateIdentity.uuid(0x0103),
            name: "Metal",
            color: FFRGBA(red: 0.90, green: 0.72, blue: 0.34)
        )
        let stones = FFLayer(
            id: FFTemplateIdentity.uuid(0x0104),
            name: "Stones",
            color: FFRGBA(red: 0.46, green: 0.82, blue: 0.96)
        )
        let gold = FFMaterial(
            id: FFTemplateIdentity.uuid(0x0101),
            name: FFAlloyPreset.yellowGold18K.label,
            baseColor: FFAlloyPreset.yellowGold18K.baseColor,
            metallic: FFAlloyPreset.yellowGold18K.metallic,
            roughness: FFAlloyPreset.yellowGold18K.roughness,
            preset: .yellowGold18K
        )
        let gem = FFMaterial(
            id: FFTemplateIdentity.uuid(0x0102),
            name: "Round Brilliant",
            baseColor: FFRGBA(red: 0.62, green: 0.86, blue: 0.95),
            metallic: 0.02,
            roughness: 0.05
        )

        var children: [FFNode] = []
        if let shank = FFMeshFactory.torus(
            majorRadius: 9.6,
            minorRadius: 1.8,
            majorSegments: 96,
            minorSegments: 24
        ) {
            children.append(FFNode(
                id: FFTemplateIdentity.uuid(0x0110),
                name: "Shank",
                transform: uprightRing,
                geometry: .mesh(FFMeshPayload(shank)),
                materialID: gold.id,
                kind: .solid,
                layerID: metal.id
            ))
        }
        if let halo = FFMeshFactory.torus(
            majorRadius: 3.3,
            minorRadius: 0.65,
            majorSegments: 64,
            minorSegments: 16
        ) {
            children.append(FFNode(
                id: FFTemplateIdentity.uuid(0x0111),
                name: "Halo",
                transform: FFTransform(
                    translation: FFPoint3(x: 0, y: 14.0, z: 0),
                    rotation: FFPoint3(x: .pi / 2, y: 0, z: 0),
                    scale: FFPoint3(x: 1, y: 1, z: 1)
                ),
                geometry: .mesh(FFMeshPayload(halo)),
                materialID: gold.id,
                kind: .solid,
                layerID: metal.id
            ))
        }
        if let stone = FFMeshFactory.octahedron(radius: 2.6) {
            children.append(FFNode(
                id: FFTemplateIdentity.uuid(0x0112),
                name: "Centre Stone",
                transform: FFTransform(
                    translation: FFPoint3(x: 0, y: 14.2, z: 0),
                    rotation: FFPoint3(x: 0, y: 0, z: 0),
                    scale: FFPoint3(x: 1, y: 1, z: 1)
                ),
                geometry: .mesh(FFMeshPayload(stone)),
                materialID: gem.id,
                kind: .stone,
                layerID: stones.id
            ))
        }

        return document(
            name: FFDocumentTemplate.solitaireRing.title,
            materials: [gold, gem],
            layers: [metal, stones],
            currentLayerID: metal.id,
            rootNodes: [
                FFNode(
                    id: FFTemplateIdentity.uuid(0x0105),
                    name: "Solitaire Ring",
                    children: children
                ),
            ]
        )
    }

    private static func plainBand() -> FFDocument {
        let metal = FFLayer(
            id: FFTemplateIdentity.uuid(0x0202),
            name: "Metal",
            color: FFRGBA(red: 0.82, green: 0.84, blue: 0.86)
        )
        let platinum = FFMaterial(
            id: FFTemplateIdentity.uuid(0x0201),
            name: FFAlloyPreset.platinum950.label,
            baseColor: FFAlloyPreset.platinum950.baseColor,
            metallic: FFAlloyPreset.platinum950.metallic,
            roughness: FFAlloyPreset.platinum950.roughness,
            preset: .platinum950
        )

        var roots: [FFNode] = []
        if let band = FFMeshFactory.torus(
            majorRadius: 9.3,
            minorRadius: 2.2,
            majorSegments: 96,
            minorSegments: 24
        ) {
            roots.append(FFNode(
                id: FFTemplateIdentity.uuid(0x0203),
                name: "Comfort Band",
                transform: uprightRing,
                geometry: .mesh(FFMeshPayload(band)),
                materialID: platinum.id,
                kind: .solid,
                layerID: metal.id
            ))
        }

        return document(
            name: FFDocumentTemplate.plainBand.title,
            materials: [platinum],
            layers: [metal],
            currentLayerID: metal.id,
            rootNodes: roots
        )
    }

    private static func pendant() -> FFDocument {
        let metal = FFLayer(
            id: FFTemplateIdentity.uuid(0x0303),
            name: "Metal",
            color: FFRGBA(red: 0.86, green: 0.87, blue: 0.90)
        )
        let stones = FFLayer(
            id: FFTemplateIdentity.uuid(0x0304),
            name: "Stones",
            color: FFRGBA(red: 0.72, green: 0.88, blue: 0.98)
        )
        let whiteGold = FFMaterial(
            id: FFTemplateIdentity.uuid(0x0301),
            name: FFAlloyPreset.whiteGold18K.label,
            baseColor: FFAlloyPreset.whiteGold18K.baseColor,
            metallic: FFAlloyPreset.whiteGold18K.metallic,
            roughness: FFAlloyPreset.whiteGold18K.roughness,
            preset: .whiteGold18K
        )
        let drop = FFMaterial(
            id: FFTemplateIdentity.uuid(0x0302),
            name: "Pear Brilliant",
            baseColor: FFRGBA(red: 0.80, green: 0.92, blue: 0.99),
            metallic: 0.02,
            roughness: 0.06
        )

        var children: [FFNode] = []
        if let bail = FFMeshFactory.torus(
            majorRadius: 1.5,
            minorRadius: 0.5,
            majorSegments: 48,
            minorSegments: 16
        ) {
            children.append(FFNode(
                id: FFTemplateIdentity.uuid(0x0310),
                name: "Bail",
                transform: FFTransform(
                    translation: FFPoint3(x: 0, y: 9.2, z: 0),
                    rotation: FFPoint3(x: .pi / 2, y: 0, z: 0),
                    scale: FFPoint3(x: 1, y: 1, z: 1)
                ),
                geometry: .mesh(FFMeshPayload(bail)),
                materialID: whiteGold.id,
                kind: .solid,
                layerID: metal.id
            ))
        }
        if let collar = FFMeshFactory.torus(
            majorRadius: 4.0,
            minorRadius: 0.4,
            majorSegments: 64,
            minorSegments: 12
        ) {
            children.append(FFNode(
                id: FFTemplateIdentity.uuid(0x0311),
                name: "Girdle Collar",
                transform: FFTransform(
                    translation: FFPoint3(x: 0, y: 0.4, z: 0),
                    rotation: FFPoint3(x: .pi / 2, y: 0, z: 0),
                    scale: FFPoint3(x: 1, y: 1, z: 1)
                ),
                geometry: .mesh(FFMeshPayload(collar)),
                materialID: whiteGold.id,
                kind: .solid,
                layerID: metal.id
            ))
        }
        if let stone = FFMeshFactory.octahedron(radius: 4.4) {
            children.append(FFNode(
                id: FFTemplateIdentity.uuid(0x0312),
                name: "Pear Drop",
                transform: FFTransform(
                    translation: FFPoint3(x: 0, y: 0.4, z: 0),
                    rotation: FFPoint3(x: 0, y: 0, z: 0),
                    scale: FFPoint3(x: 0.85, y: 1.75, z: 0.85)
                ),
                geometry: .mesh(FFMeshPayload(stone)),
                materialID: drop.id,
                kind: .stone,
                layerID: stones.id
            ))
        }

        return document(
            name: FFDocumentTemplate.pendant.title,
            materials: [whiteGold, drop],
            layers: [metal, stones],
            currentLayerID: metal.id,
            rootNodes: [
                FFNode(
                    id: FFTemplateIdentity.uuid(0x0305),
                    name: "Pendant",
                    children: children
                ),
            ]
        )
    }

    private static func signet() -> FFDocument {
        let metal = FFLayer(
            id: FFTemplateIdentity.uuid(0x0403),
            name: "Metal",
            color: FFRGBA(red: 0.90, green: 0.72, blue: 0.34)
        )
        let gold = FFMaterial(
            id: FFTemplateIdentity.uuid(0x0401),
            name: FFAlloyPreset.yellowGold18K.label,
            baseColor: FFAlloyPreset.yellowGold18K.baseColor,
            metallic: FFAlloyPreset.yellowGold18K.metallic,
            roughness: FFAlloyPreset.yellowGold18K.roughness,
            preset: .yellowGold18K
        )
        let antique = FFMaterial(
            id: FFTemplateIdentity.uuid(0x0402),
            name: "Antique Gold",
            baseColor: FFRGBA(red: 0.55, green: 0.42, blue: 0.16),
            metallic: 1.0,
            roughness: 0.45
        )

        var children: [FFNode] = []
        if let band = FFMeshFactory.torus(
            majorRadius: 9.4,
            minorRadius: 1.9,
            majorSegments: 96,
            minorSegments: 24
        ) {
            children.append(FFNode(
                id: FFTemplateIdentity.uuid(0x0410),
                name: "Shank",
                transform: uprightRing,
                geometry: .mesh(FFMeshPayload(band)),
                materialID: gold.id,
                kind: .solid,
                layerID: metal.id
            ))
        }
        if let face = FFTemplateMesh.box(width: 7.6, height: 1.4, depth: 6.4) {
            children.append(FFNode(
                id: FFTemplateIdentity.uuid(0x0411),
                name: "Face",
                transform: FFTransform(
                    translation: FFPoint3(x: 0, y: 12.0, z: 0),
                    rotation: FFPoint3(x: 0, y: 0, z: 0),
                    scale: FFPoint3(x: 1, y: 1, z: 1)
                ),
                geometry: .mesh(FFMeshPayload(face)),
                materialID: gold.id,
                kind: .solid,
                layerID: metal.id
            ))
        }
        if let crest = FFTemplateMesh.box(width: 5.6, height: 0.6, depth: 4.6) {
            children.append(FFNode(
                id: FFTemplateIdentity.uuid(0x0412),
                name: "Crest",
                transform: FFTransform(
                    translation: FFPoint3(x: 0, y: 13.0, z: 0),
                    rotation: FFPoint3(x: 0, y: 0, z: 0),
                    scale: FFPoint3(x: 1, y: 1, z: 1)
                ),
                geometry: .mesh(FFMeshPayload(crest)),
                materialID: gold.id,
                kind: .solid,
                layerID: metal.id,
                // The box's top face is triangles 6 and 7 (see the winding
                // table below), so the monogram field is the visible top only.
                faceGroups: [
                    FFFaceGroup(
                        id: FFTemplateIdentity.uuid(0x0413),
                        name: "Monogram Field",
                        materialID: antique.id,
                        triangles: [6, 7]
                    ),
                ]
            ))
        }

        return document(
            name: FFDocumentTemplate.signet.title,
            materials: [gold, antique],
            layers: [metal],
            currentLayerID: metal.id,
            rootNodes: [
                FFNode(
                    id: FFTemplateIdentity.uuid(0x0405),
                    name: "Signet Ring",
                    children: children
                ),
            ]
        )
    }

    // MARK: - Shared construction

    /// The standing orientation every ring uses: a torus built around the Y
    /// axis is turned a quarter turn about X, so its hole faces the camera and
    /// +Y runs from the shank's bottom to the setting.
    private static var uprightRing: FFTransform {
        FFTransform(
            translation: FFPoint3(x: 0, y: 0, z: 0),
            rotation: FFPoint3(x: .pi / 2, y: 0, z: 0),
            scale: FFPoint3(x: 1, y: 1, z: 1)
        )
    }

    /// One document with a fixed Default layer set. Passing the set explicitly
    /// keeps its id stable, which plain `capturing` would leave to `UUID()`.
    private static func document(
        name: String,
        materials: [FFMaterial],
        layers: [FFLayer],
        currentLayerID: UUID,
        rootNodes: [FFNode]
    ) -> FFDocument {
        let set = FFLayerSet.capturing(
            layers,
            id: FFTemplateIdentity.layerSet(for: layers),
            name: "Default"
        )
        return FFDocument(
            name: name,
            materials: materials,
            rootNodes: rootNodes,
            layers: layers,
            currentLayerID: currentLayerID,
            layerSets: [set],
            activeLayerSetID: set.id
        )
    }
}

/// Stable ids for template documents. Ids are derived from a small integer so
/// two builds of the same template produce byte-identical documents; the
/// version and variant nibbles are the fixed ones a real v4 UUID carries.
private enum FFTemplateIdentity {
    static func uuid(_ seed: Int) -> UUID {
        let block = String(seed & 0xFFFF, radix: 16, uppercase: true)
        let tail = String(seed & 0xFFFF_FFFF, radix: 16, uppercase: true)
        let text = "F3AE"
            + String(repeating: "0", count: max(0, 4 - block.count)) + block
            + "-0000-4000-8000-"
            + String(repeating: "0", count: max(0, 12 - tail.count)) + tail
        guard let value = UUID(uuidString: text) else {
            preconditionFailure("Template seed \(seed) is not a UUID")
        }
        return value
    }

    /// A layer-set id derived from the template's layer ids, so a template that
    /// gains or loses a layer cannot silently reuse another template's set id.
    static func layerSet(for layers: [FFLayer]) -> UUID {
        let seed = layers.reduce(0x4000) { partial, layer in
            partial ^ (layer.id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) } & 0xFFFF)
        }
        return uuid(seed)
    }
}

/// Template-only mesh primitives. The box is the signet's face; it lives here
/// rather than in `FFMeshFactory` because the kernel's solid primitives are a
/// later phase, and a template must not grow the shipped mesh API.
private enum FFTemplateMesh {
    /// An axis-aligned box centred at the origin with outward winding on all
    /// six faces. The triangle order is part of the template's data: the signet
    /// assigns its monogram field to the top face, which is indices 6 and 7.
    static func box(width: Double, height: Double, depth: Double) -> IndexedMesh? {
        let halfWidth = width / 2
        let halfHeight = height / 2
        let halfDepth = depth / 2
        guard halfWidth > 0, halfHeight > 0, halfDepth > 0 else { return nil }

        let positions = [
            Vec3(x: -halfWidth, y: -halfHeight, z: -halfDepth),
            Vec3(x: halfWidth, y: -halfHeight, z: -halfDepth),
            Vec3(x: halfWidth, y: halfHeight, z: -halfDepth),
            Vec3(x: -halfWidth, y: halfHeight, z: -halfDepth),
            Vec3(x: -halfWidth, y: -halfHeight, z: halfDepth),
            Vec3(x: halfWidth, y: -halfHeight, z: halfDepth),
            Vec3(x: halfWidth, y: halfHeight, z: halfDepth),
            Vec3(x: -halfWidth, y: halfHeight, z: halfDepth),
        ]
        let triangles = [
            MeshTriangle(0, 3, 2), MeshTriangle(0, 2, 1),   // back,  −Z
            MeshTriangle(4, 5, 6), MeshTriangle(4, 6, 7),   // front, +Z
            MeshTriangle(0, 1, 5), MeshTriangle(0, 5, 4),   // bottom, −Y
            MeshTriangle(3, 7, 6), MeshTriangle(3, 6, 2),   // top,   +Y
            MeshTriangle(0, 4, 7), MeshTriangle(0, 7, 3),   // left,  −X
            MeshTriangle(1, 2, 6), MeshTriangle(1, 6, 5),   // right, +X
        ]
        return IndexedMesh(positions: positions, triangles: triangles)
    }
}
