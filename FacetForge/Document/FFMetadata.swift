import Foundation

/// Phase 36's manufacturing flags. They are document decisions rather than
/// pipeline states, so every flag is ordinary editable data with no locked tier.
enum FFManufacturingFlag: String, CaseIterable, Codable, Identifiable, Sendable {
    case casting
    case stoneSetting = "stone-setting"
    case handEngraving = "hand-engraving"
    case rhodiumPlating = "rhodium-plating"
    case laserWelding = "laser-welding"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .casting: return "Casting"
        case .stoneSetting: return "Stone setting"
        case .handEngraving: return "Hand engraving"
        case .rhodiumPlating: return "Rhodium plating"
        case .laserWelding: return "Laser welding"
        }
    }
}

/// The text fields the metadata inspector edits. The enum keeps the session's
/// coalescing key, status line and the panel's identifiers from drifting apart.
enum FFMetadataField: String, CaseIterable, Identifiable, Sendable {
    case partNumber
    case sku
    case itemDescription
    case workshopNotes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .partNumber: return "Part number"
        case .sku: return "SKU"
        case .itemDescription: return "Description"
        case .workshopNotes: return "Workshop notes"
        }
    }

    var accessibilityIdentifier: String { "metadata.field.\(rawValue)" }
}

/// The production paperwork attached to a document. It is additive in schema 1:
/// a file written before Phase 36 decodes to no metadata at all, and an empty
/// value is pruned back to `nil` so clearing every field restores the exact
/// pre-Phase-36 encoding.
struct FFMetadata: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case partNumber
        case sku
        case itemDescription = "description"
        case workshopNotes
        case manufacturingFlags
    }

    var partNumber: String
    var sku: String
    var itemDescription: String
    var workshopNotes: String
    /// Stored in `FFManufacturingFlag.allCases` order so the same set of flags
    /// always encodes identically, whatever order the user toggled them in.
    var manufacturingFlags: [FFManufacturingFlag]

    init(
        partNumber: String = "",
        sku: String = "",
        itemDescription: String = "",
        workshopNotes: String = "",
        manufacturingFlags: [FFManufacturingFlag] = []
    ) {
        self.partNumber = partNumber
        self.sku = sku
        self.itemDescription = itemDescription
        self.workshopNotes = workshopNotes
        self.manufacturingFlags = manufacturingFlags
    }

    /// True when nothing would be lost by pruning the field back to `nil`.
    /// Whitespace-only text counts as empty so a user who typed and deleted
    /// every character does not leave a phantom metadata object behind.
    var isEmpty: Bool {
        !hasVisibleText(partNumber)
            && !hasVisibleText(sku)
            && !hasVisibleText(itemDescription)
            && !hasVisibleText(workshopNotes)
            && manufacturingFlags.isEmpty
    }

    func value(for field: FFMetadataField) -> String {
        switch field {
        case .partNumber: return partNumber
        case .sku: return sku
        case .itemDescription: return itemDescription
        case .workshopNotes: return workshopNotes
        }
    }

    mutating func setValue(_ value: String, for field: FFMetadataField) {
        switch field {
        case .partNumber: partNumber = value
        case .sku: sku = value
        case .itemDescription: itemDescription = value
        case .workshopNotes: workshopNotes = value
        }
    }

    func isFlagEnabled(_ flag: FFManufacturingFlag) -> Bool {
        manufacturingFlags.contains(flag)
    }

    /// Writes the flag set in canonical order, so toggling on, off and on again
    /// is a no-op and two documents with the same flags have one encoding.
    mutating func setFlag(_ flag: FFManufacturingFlag, enabled: Bool) -> Bool {
        var enabledFlags = Set(manufacturingFlags)
        let changed = enabled ? enabledFlags.insert(flag).inserted : enabledFlags.remove(flag) != nil
        guard changed else { return false }
        manufacturingFlags = FFManufacturingFlag.allCases.filter { enabledFlags.contains($0) }
        return true
    }

    private func hasVisibleText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The document's stones, derived in the same pre-order the object tree uses.
/// Nothing here is stored: the summary is a projection of the node tree, so it
/// cannot disagree with the stone list after a delete, an import or an undo.
struct FFStoneSummary: Equatable, Sendable {
    struct Stone: Identifiable, Equatable, Sendable {
        let id: UUID
        let name: String
        let materialName: String?
    }

    var stones: [Stone]

    var count: Int { stones.count }

    var label: String {
        count == 1 ? "1 stone" : "\(count) stones"
    }
}

extension FFDocument {
    /// The metadata the inspector shows. A document that never had metadata
    /// reads as empty fields rather than as an optional the panel must unwrap.
    var resolvedMetadata: FFMetadata { metadata ?? FFMetadata() }

    /// One text field edit. Returns false when the value is unchanged, so a
    /// no-op keystroke never records an undo step.
    @discardableResult
    mutating func setMetadataField(_ field: FFMetadataField, value: String) -> Bool {
        var next = resolvedMetadata
        guard next.value(for: field) != value else { return false }
        next.setValue(value, for: field)
        setMetadata(next)
        return true
    }

    @discardableResult
    mutating func setManufacturingFlag(_ flag: FFManufacturingFlag, enabled: Bool) -> Bool {
        var next = resolvedMetadata
        guard next.setFlag(flag, enabled: enabled) else { return false }
        setMetadata(next)
        return true
    }

    /// Stones in document order, with their material names. The tree's rows and
    /// this projection both walk roots depth-first, so their stone ids match
    /// element for element.
    func stoneSummary() -> FFStoneSummary {
        var stones: [FFStoneSummary.Stone] = []

        func walk(_ nodes: [FFNode]) {
            for node in nodes {
                if FFObjectKind.classify(node) == .stone {
                    stones.append(FFStoneSummary.Stone(
                        id: node.id,
                        name: node.name,
                        materialName: node.materialID.flatMap { material(withID: $0)?.name }
                    ))
                }
                walk(node.children)
            }
        }

        walk(rootNodes)
        return FFStoneSummary(stones: stones)
    }

    /// Stores the metadata, or removes the key entirely once every field is
    /// empty and no flag is set, which is what keeps an untouched document's
    /// canonical hash identical to its pre-Phase-36 value.
    private mutating func setMetadata(_ next: FFMetadata) {
        metadata = next.isEmpty ? nil : next
    }
}
