import Foundation

/// The four layer states Phase 31 names. Keeping them in one value is what lets
/// a layer set snapshot and restore a layer atomically; a new state must be
/// added here so every save, set switch and test sees it.
struct FFLayerState: Codable, Equatable, Sendable {
    var color: FFRGBA
    var isVisible: Bool
    var isLocked: Bool
    var isPrintable: Bool

    init(
        color: FFRGBA,
        isVisible: Bool = true,
        isLocked: Bool = false,
        isPrintable: Bool = true
    ) {
        self.color = color
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.isPrintable = isPrintable
    }
}

/// One layer's state inside a set, keyed explicitly rather than by a dictionary
/// of UUIDs so the JSON encoding has a stable order and a state hash is
/// reproducible across processes.
struct FFLayerSetEntry: Codable, Equatable, Sendable {
    var layerID: UUID
    var state: FFLayerState
}

/// A named snapshot of the layer states. Switching applies the incoming set to
/// the live layers; the outgoing set is kept current by every state mutation,
/// so switching never rewrites another set's stored visibility.
struct FFLayerSet: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    /// Sorted by layer id so encoding, equality and the document state hash are
    /// deterministic.
    private(set) var entries: [FFLayerSetEntry]

    init(id: UUID = UUID(), name: String, entries: [FFLayerSetEntry] = []) {
        self.id = id
        self.name = name
        self.entries = Self.normalized(entries)
    }

    var layerIDs: [UUID] { entries.map(\.layerID) }

    func state(forLayer layerID: UUID) -> FFLayerState? {
        entries.first { $0.layerID == layerID }?.state
    }

    mutating func setState(_ state: FFLayerState, forLayer layerID: UUID) {
        if let index = entries.firstIndex(where: { $0.layerID == layerID }) {
            entries[index].state = state
        } else {
            entries.append(FFLayerSetEntry(layerID: layerID, state: state))
            entries = Self.normalized(entries)
        }
    }

    mutating func removeLayer(_ layerID: UUID) {
        entries.removeAll { $0.layerID == layerID }
    }

    /// A set that captures every live layer. New sets start from what is on
    /// screen, so activating one is a no-op until the user changes something.
    static func capturing(_ layers: [FFLayer], id: UUID = UUID(), name: String) -> FFLayerSet {
        FFLayerSet(
            id: id,
            name: name,
            entries: layers.map { FFLayerSetEntry(layerID: $0.id, state: $0.state) }
        )
    }

    private static func normalized(_ entries: [FFLayerSetEntry]) -> [FFLayerSetEntry] {
        var seen = Set<UUID>()
        return entries
            .filter { seen.insert($0.layerID).inserted }
            .sorted { $0.layerID.uuidString < $1.layerID.uuidString }
    }
}

/// The layer section of a document used as a template. Importing adds the
/// template's layers that the current document does not already have, by name,
/// and never overwrites a layer the user already tuned.
struct FFLayerTemplate: Equatable, Sendable {
    let name: String
    let layers: [FFLayer]

    static let workshop = FFLayerTemplate(
        name: "Workshop",
        layers: [
            FFLayer(
                name: "Findings",
                color: FFRGBA(red: 0.72, green: 0.76, blue: 0.82)
            ),
            FFLayer(
                name: "Annotations",
                color: FFRGBA(red: 0.96, green: 0.62, blue: 0.20),
                isPrintable: false
            ),
            FFLayer(
                name: "Presentation",
                color: FFRGBA(red: 0.98, green: 0.98, blue: 0.96),
                isLocked: true
            )
        ]
    )
}

/// A drawing layer. Layers are document state: membership, all four states and
/// the layer sets travel with the save file, and the editor session is their
/// only owner. A node belongs to at most one layer; a node without an
/// assignment draws on the document's first layer.
struct FFLayer: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var color: FFRGBA
    var isVisible: Bool
    var isLocked: Bool
    /// Whether drawings on this layer are included when the document is
    /// printed. Phase 31 stores and edits the state; the print pipeline itself
    /// is a later phase, so no renderer reads it yet.
    var isPrintable: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case color
        case isVisible
        case isLocked
        case isPrintable
    }

    init(
        id: UUID = UUID(),
        name: String,
        color: FFRGBA,
        isVisible: Bool = true,
        isLocked: Bool = false,
        isPrintable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.isPrintable = isPrintable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.color = try container.decode(FFRGBA.self, forKey: .color)
        self.isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        self.isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        // Files written before Phase 31 have no print state; a drawing that was
        // printable yesterday must not silently drop out of the print today.
        self.isPrintable = try container.decodeIfPresent(Bool.self, forKey: .isPrintable) ?? true
    }

    var state: FFLayerState {
        FFLayerState(
            color: color,
            isVisible: isVisible,
            isLocked: isLocked,
            isPrintable: isPrintable
        )
    }

    mutating func apply(_ state: FFLayerState) {
        self.color = state.color
        self.isVisible = state.isVisible
        self.isLocked = state.isLocked
        self.isPrintable = state.isPrintable
    }

    /// The layer a document created before layers decodes into. The id is fixed
    /// so a legacy file gains the same layer every time it is opened.
    static let defaultLayerID = UUID(uuidString: "A11A7E20-0000-4000-8000-000000000020")!

    static var defaultLayer: FFLayer {
        FFLayer(
            id: defaultLayerID,
            name: "Default",
            color: FFRGBA(red: 0.86, green: 0.73, blue: 0.46)
        )
    }

    /// The palette the swatch button cycles. Six steps are enough to tell two
    /// layers apart in wireframe without asking for a colour picker.
    static let palette: [FFRGBA] = [
        FFRGBA(red: 0.86, green: 0.73, blue: 0.46),
        FFRGBA(red: 0.94, green: 0.30, blue: 0.26),
        FFRGBA(red: 0.24, green: 0.80, blue: 0.38),
        FFRGBA(red: 0.34, green: 0.62, blue: 0.96),
        FFRGBA(red: 0.52, green: 0.84, blue: 0.96),
        FFRGBA(red: 0.82, green: 0.44, blue: 0.92)
    ]

    /// The next palette entry after the current colour, so a swatch tap is one
    /// deterministic step rather than a picker sheet.
    var nextColor: FFRGBA {
        let palette = Self.palette
        let index = palette.firstIndex { $0 == color } ?? -1
        return palette[(index + 1) % palette.count]
    }
}

extension FFDocument {
    func layer(withID target: UUID?) -> FFLayer? {
        guard let target else { return nil }
        return layers.first { $0.id == target }
    }

    /// The layer a node draws on. A node with no assignment belongs to the
    /// document's first layer, which is what a legacy file gains on decode.
    func layer(forNodeID nodeID: UUID) -> FFLayer? {
        if let node = node(withID: nodeID), let layer = layer(withID: node.layerID) {
            return layer
        }
        return layers.first
    }

    func nodeIDs(inLayer layerID: UUID) -> [UUID] {
        var ids: [UUID] = []
        // A node without an assignment belongs to the first layer, which is
        // also what `layer(forNodeID:)` answers. Membership and assignment
        // must agree or a legacy node would be drawn on one layer and counted
        // on another.
        let fallback = layers.first?.id
        func visit(_ node: FFNode) {
            if (node.layerID ?? fallback) == layerID { ids.append(node.id) }
            node.children.forEach(visit)
        }
        rootNodes.forEach(visit)
        return ids
    }

    var activeLayerSet: FFLayerSet? {
        guard let activeLayerSetID else { return layerSets.first }
        return layerSets.first { $0.id == activeLayerSetID } ?? layerSets.first
    }

    /// The layer section of this document, as a template another document can
    /// import. Nodes, materials and measurements are deliberately not carried:
    /// a template import is a layer definition copy, not a document merge.
    var layerTemplate: FFLayerTemplate {
        FFLayerTemplate(name: name, layers: layers)
    }

    /// Mirrors a live layer state into the active set. Called inside the same
    /// `perform` block as the layer mutation, so the snapshot and the drawing
    /// can never disagree and a set never needs a later capture pass.
    mutating func record(_ state: FFLayerState, forLayer layerID: UUID) {
        guard let index = layerSets.firstIndex(where: { $0.id == activeLayerSetID }) else { return }
        layerSets[index].setState(state, forLayer: layerID)
    }
}
