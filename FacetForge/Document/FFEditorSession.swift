import Combine
import Foundation

/// What the crash journal offers the next launch of a document. The shell
/// renders it; only the session decides whether it is offered, applied or
/// discarded.
struct FFJournalRecoveryOffer: Equatable, Sendable {
    var document: FFDocument
    var recordedAt: Date
    var snapshotCount: Int
    var documentName: String

    var detail: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "\(documentName) · last edit \(formatter.string(from: recordedAt)) · \(snapshotCount) kept"
    }
}

/// The owner of the editing document and of everything the viewport draws.
///
/// Phases 13–17 grew scene, selection and visibility state inside the shell.
/// The display-mode row makes the mode part of the saved document, so this is
/// the phase that gives that state a real owner: the session holds the
/// `FFDocumentSession`, derives the renderable scene from the document's node
/// tree, and owns selection, the per-viewport display modes and the document's
/// layers. Layer membership, visibility, lock, colour and the current layer are
/// document state with this one owner; the shell keeps only layout and input.
final class FFEditorSession: ObservableObject {
    /// The renderable scene derived from the document. Rebuilt on load and on
    /// any structural edit; the node IDs are the document's node IDs.
    @Published private(set) var scene: FFViewportScene
    /// Selection and visibility for this document. Visibility is deliberately
    /// not persisted yet; the Phase 17 record documents that boundary.
    @Published var selection: FFSelectionState
    /// The saved mode per viewport pane id. Published so a chip redraws as soon
    /// as the document change commits.
    @Published private(set) var displayModes: [String: FFDisplayMode]
    /// Drawing layers. They are document state; this session is their only
    /// owner and the shell only renders them. A node's layer decides whether
    /// it is drawn, whether it can be edited, and its wireframe colour.
    @Published private(set) var layers: [FFLayer]
    @Published private(set) var currentLayerID: UUID?
    /// The document's root nodes, published so the Phase 32 object tree
    /// redraws when a node is renamed, reordered or nested. The scene alone
    /// cannot drive the tree: a container has no renderable node of its own.
    @Published private(set) var rootNodes: [FFNode]
    /// Phase 31's named layer-state snapshots and the active one. Both are
    /// document state: a set switch is one undoable edit and reaches the save
    /// file and journal through the same commit path as any node edit.
    @Published private(set) var layerSets: [FFLayerSet] = []
    @Published private(set) var activeLayerSetID: UUID?
    /// Committed measurements, derived from the document. Phase 23 gives them
    /// the same owner as layers and display modes; the measurement tool keeps
    /// only its draft points.
    @Published private(set) var measurements: [FFMeasurement]
    /// Phase 39's live line chain. The draft is transient tool state; the
    /// committed chain is an ordinary curve node, so undo, the journal and
    /// autosave need no special case. The draft never reaches the document.
    @Published private(set) var lineChainDraft = FFLineChainDraft()
    /// The last line-tool hint or refusal, shown beside the typed length field
    /// so a rejected command explains itself instead of doing nothing.
    @Published private(set) var lineToolMessage: String?
    /// Curve nodes projected into world space for the viewport overlay. The
    /// session owns the projection; the view only draws it.
    @Published private(set) var curveNodes: [FFCurveRender] = []
    /// Phase 40's live arc draft. Like the line chain it is transient tool
    /// state: a finished arc is an ordinary curve node committed through
    /// `perform`, so undo, the journal and autosave need no arc branch.
    @Published private(set) var arcDraft = FFArcDraft()
    /// The last arc-tool hint or refusal, so a rejected construction explains
    /// itself instead of silently dropping the tap.
    @Published private(set) var arcToolMessage: String?
    /// Phase 36's production paperwork. It is document state with this same
    /// owner; the panel only edits drafts and never keeps a copy that could
    /// disagree with the file.
    @Published private(set) var metadata = FFMetadata()
    /// Stones derived from the node tree in display order. Published with the
    /// metadata because both are rendered by the same sheet.
    @Published private(set) var stoneSummary = FFStoneSummary(stones: [])
    /// The last document command, shown in the app bar so a smoke run can read
    /// back that save and reopen actually happened.
    @Published private(set) var documentStatus: String
    /// The reason a reopen used the last good save. `nil` on a normal open.
    @Published private(set) var recoveryMessage: String?
    /// What the reader did to an older file. `nil` when the file was already
    /// the current container version. The status line announces it; the report
    /// keeps every step it applied.
    @Published private(set) var migrationReport: FFPMigrationReport?
    /// Where the document was last saved or loaded from. `nil` for a new bench
    /// sample that has never touched disk.
    @Published private(set) var documentURL: URL?
    /// Unsaved edits found in the crash journal after a reopen. A non-nil offer
    /// is the shell's signal to show the recovery prompt; restoring or
    /// discarding is a session command.
    @Published private(set) var recoveryOffer: FFJournalRecoveryOffer?
    /// How many snapshots the journal currently keeps, at most five.
    @Published private(set) var journalSnapshotCount = 0
    /// The last successful autosave, and the last autosave failure. Diagnostics
    /// only; the document status remains the user-facing line.
    @Published private(set) var lastAutosaveAt: Date?
    @Published private(set) var autosaveMessage: String?
    /// Whether the current document has edits that are not in its bundle yet.
    private(set) var isDirty = false
    /// The recents list the browser renders. The session refreshes it; the
    /// browser never scans or mutates the folder itself.
    @Published private(set) var library: [FFDocumentSummary] = []

    private(set) var documentSession: FFDocumentSession
    private let store: FFDocumentStore
    /// What the bundle reader did not understand. Kept across edits so a save
    /// rewrites a future minor writer's fields alongside this version's.
    private var preservation: FFPBundlePreservation?

    /// Phase 27's autosave policy. The interval is injectable so the tests do
    /// not have to wait thirty seconds for a save. Journal writes are not
    /// delayed at all: a committed edit must survive a kill before the next
    /// run-loop turn, so each one is written synchronously.
    static let defaultAutosaveInterval: TimeInterval = 30
    private let autosaveInterval: TimeInterval
    private let now: () -> Date
    private var journal: FFEditJournal?
    private var autosaveTimer: Timer?
    /// True while a load is replacing the whole document. Those transitions are
    /// not edits and must not create recovery snapshots of the file being
    /// opened or of a document the user explicitly discarded.
    private var isLoading = false

    /// A new session. With no document argument the bench sample is loaded and
    /// its stone opens selected, which is the state Phase 17's CI asserts.
    init(
        document: FFDocument? = nil,
        documentURL: URL? = nil,
        store: FFDocumentStore = FFDocumentStore(),
        autosaveInterval: TimeInterval = FFEditorSession.defaultAutosaveInterval,
        now: @escaping () -> Date = { Date() }
    ) {
        let sample = FFDocument.benchSample
        let initial = document ?? sample.document
        self.store = store
        self.autosaveInterval = autosaveInterval
        self.now = now
        self.documentSession = FFDocumentSession(document: initial)
        self.scene = Self.scene(from: initial)
        self.displayModes = initial.displayModes
        self.layers = initial.layers
        self.currentLayerID = initial.currentLayerID
        self.rootNodes = initial.rootNodes
        self.layerSets = initial.layerSets
        self.activeLayerSetID = initial.activeLayerSetID
        self.measurements = initial.measurements.map(\.measurement)
        self.curveNodes = initial.curveRenders()
        self.metadata = initial.resolvedMetadata
        self.stoneSummary = initial.stoneSummary()
        self.documentStatus = initial.name
        self.recoveryMessage = nil
        self.migrationReport = nil
        self.documentURL = documentURL
        self.preservation = nil
        self.selection = document == nil
            ? FFSelectionState(selectedIDs: sample.selectedNodeIDs)
            : FFSelectionState()
    }

    var document: FFDocument { documentSession.document }

    func displayMode(for paneID: String) -> FFDisplayMode {
        displayModes[paneID] ?? .shaded
    }

    /// Cycles one viewport's mode. The change goes through the document
    /// session, so it lands in the same save file and the same undo history as
    /// a node edit.
    func cycleDisplayMode(for paneID: String) {
        setDisplayMode(displayMode(for: paneID).next, for: paneID)
    }

    @discardableResult
    func setDisplayMode(_ mode: FFDisplayMode, for paneID: String) -> Bool {
        guard displayMode(for: paneID) != mode else { return false }
        let changed = documentSession.perform(
            "Display mode \(mode.label)",
            coalescingKey: "display-mode-\(paneID)"
        ) { document in
            document.displayModes[paneID] = mode
        }
        guard changed else { return false }
        syncDocumentState()
        return true
    }

    // MARK: - Layers

    func layer(withID id: UUID?) -> FFLayer? {
        documentSession.document.layer(withID: id)
    }

    var currentLayer: FFLayer? { layer(withID: currentLayerID) }

    func nodeCount(inLayer id: UUID) -> Int {
        documentSession.document.nodeIDs(inLayer: id).count
    }

    /// The nodes whose layer is locked. The shell uses this to keep the gizmo
    /// off an uneditable node; the session itself refuses every edit command
    /// that would change one.
    var lockedNodeIDs: Set<UUID> {
        var ids: Set<UUID> = []
        for layer in layers where layer.isLocked {
            ids.formUnion(documentSession.document.nodeIDs(inLayer: layer.id))
        }
        return ids
    }

    func isLocked(nodeID: UUID) -> Bool {
        documentSession.document.layer(forNodeID: nodeID)?.isLocked ?? false
    }

    @discardableResult
    func addLayer(named name: String? = nil) -> UUID? {
        let index = layers.count
        let layer = FFLayer(
            name: name ?? "Layer \(index + 1)",
            color: FFLayer.palette[index % FFLayer.palette.count]
        )
        let changed = documentSession.perform("Add layer") { document in
            document.layers.append(layer)
            document.currentLayerID = layer.id
            // Every set gains the layer so switching to a set that has never
            // seen it still has a complete, deterministic state for it.
            for index in document.layerSets.indices {
                document.layerSets[index].setState(layer.state, forLayer: layer.id)
            }
        }
        guard changed else { return nil }
        syncLayers()
        return layer.id
    }

    @discardableResult
    func setCurrentLayer(_ id: UUID) -> Bool {
        guard documentSession.document.layer(withID: id) != nil,
              documentSession.document.currentLayerID != id
        else { return false }
        let changed = documentSession.perform(
            "Current layer",
            coalescingKey: "current-layer"
        ) { document in
            document.currentLayerID = id
        }
        guard changed else { return false }
        syncLayers()
        return true
    }

    @discardableResult
    func setLayerVisible(_ id: UUID, isVisible: Bool) -> Bool {
        guard let layer = documentSession.document.layer(withID: id),
              layer.isVisible != isVisible
        else { return false }
        let changed = documentSession.perform("Layer visibility") { document in
            guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
            var state = document.layers[index].state
            state.isVisible = isVisible
            document.layers[index].apply(state)
            document.record(state, forLayer: id)
        }
        guard changed else { return false }
        // Visibility is baked into the derived scene, so the rebuild is what
        // makes a hidden layer unpickable rather than merely undrawn.
        syncLayers()
        return true
    }

    @discardableResult
    func setLayerLocked(_ id: UUID, isLocked: Bool) -> Bool {
        guard let layer = documentSession.document.layer(withID: id),
              layer.isLocked != isLocked
        else { return false }
        let changed = documentSession.perform("Layer lock") { document in
            guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
            var state = document.layers[index].state
            state.isLocked = isLocked
            document.layers[index].apply(state)
            document.record(state, forLayer: id)
        }
        guard changed else { return false }
        syncLayers()
        return true
    }

    @discardableResult
    func cycleLayerColor(_ id: UUID) -> Bool {
        guard let layer = documentSession.document.layer(withID: id) else { return false }
        let changed = documentSession.perform("Layer colour \(layer.name)") { document in
            guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
            var state = document.layers[index].state
            state.color = document.layers[index].nextColor
            document.layers[index].apply(state)
            document.record(state, forLayer: id)
        }
        guard changed else { return false }
        syncLayers()
        return true
    }

    /// Phase 31's fourth layer state. The print pipeline lands later; this is
    /// the stored decision that pipeline will read, saved and undoable like the
    /// other three states.
    @discardableResult
    func setLayerPrintable(_ id: UUID, isPrintable: Bool) -> Bool {
        guard let layer = documentSession.document.layer(withID: id),
              layer.isPrintable != isPrintable
        else { return false }
        let changed = documentSession.perform("Layer print") { document in
            guard let index = document.layers.firstIndex(where: { $0.id == id }) else { return }
            var state = document.layers[index].state
            state.isPrintable = isPrintable
            document.layers[index].apply(state)
            document.record(state, forLayer: id)
        }
        guard changed else { return false }
        syncLayers()
        return true
    }

    // MARK: - Layer sets

    var activeLayerSet: FFLayerSet? {
        documentSession.document.activeLayerSet
    }

    /// Creates a set from the states currently on screen and activates it. The
    /// outgoing set already holds those states (every mutation records into it),
    /// so the snapshot is complete without a capture pass.
    @discardableResult
    func addLayerSet(named name: String? = nil) -> UUID? {
        let document = documentSession.document
        let set = FFLayerSet.capturing(
            document.layers,
            name: name ?? "Set \(document.layerSets.count + 1)"
        )
        let changed = documentSession.perform("Add layer set") { draft in
            draft.layerSets.append(set)
            draft.activeLayerSetID = set.id
        }
        guard changed else { return nil }
        syncLayers()
        documentStatus = "Layer set \(set.name)"
        return set.id
    }

    /// Applies one set's stored states to the live layers. The incoming set is
    /// read only: only the live layers change, so every other set keeps exactly
    /// the visibility it recorded while it was active.
    @discardableResult
    func activateLayerSet(_ id: UUID) -> Bool {
        let document = documentSession.document
        guard document.activeLayerSetID != id,
              let target = document.layerSets.first(where: { $0.id == id })
        else { return false }
        let changed = documentSession.perform("Layer set \(target.name)") { draft in
            for entry in target.entries {
                guard let index = draft.layers.firstIndex(where: { $0.id == entry.layerID }) else {
                    continue
                }
                draft.layers[index].apply(entry.state)
            }
            draft.activeLayerSetID = id
        }
        guard changed else { return false }
        syncLayers()
        documentStatus = "Layer set \(target.name)"
        return true
    }

    /// Imports the layer definitions of a document used as a template. A layer
    /// whose name already exists is left exactly as the user tuned it; only
    /// missing layers are added, and they join every set. One undo step covers
    /// the whole template, and an import that adds nothing records no edit.
    @discardableResult
    func importLayerTemplate(_ template: FFLayerTemplate) -> Int {
        var seen = Set(documentSession.document.layers.map { $0.name.lowercased() })
        let incoming = template.layers.filter { seen.insert($0.name.lowercased()).inserted }
        guard !incoming.isEmpty else { return 0 }

        var added = 0
        let changed = documentSession.perform("Import \(template.name) layers") { document in
            for layer in incoming {
                document.layers.append(layer)
                for index in document.layerSets.indices {
                    document.layerSets[index].setState(layer.state, forLayer: layer.id)
                }
                added += 1
            }
        }
        guard changed else { return 0 }
        syncLayers()
        documentStatus = "Imported \(added) layers from \(template.name)"
        return added
    }

    /// Moves the current selection to `layerID`. A locked layer rejects the
    /// edit, and so does a locked source layer: lock is a property of the
    /// objects on the layer, not only of the destination. Returns how many
    /// nodes actually moved.
    @discardableResult
    func assignSelection(to layerID: UUID) -> Int {
        let document = documentSession.document
        guard let target = document.layer(withID: layerID), !target.isLocked else { return 0 }
        let movable = selection.selectedIDs
            .filter { !isLocked(nodeID: $0) }
            .filter { document.node(withID: $0)?.layerID != layerID }
            .sorted { $0.uuidString < $1.uuidString }
        guard !movable.isEmpty else { return 0 }

        var moved = 0
        let changed = documentSession.perform("Assign to \(target.name)") { draft in
            for id in movable where draft.updateNode(withID: id, { $0.layerID = layerID }) {
                moved += 1
            }
        }
        guard changed else { return 0 }
        syncLayers()
        return moved
    }

    /// Selects every node on a visible layer. A hidden layer is unpickable by
    /// the row's acceptance, and selecting it by name must not be a back door.
    @discardableResult
    func selectLayer(_ id: UUID, extend: Bool = false) -> Bool {
        guard let layer = documentSession.document.layer(withID: id), layer.isVisible else {
            return false
        }
        selection.select(documentSession.document.nodeIDs(inLayer: id), extend: extend)
        return true
    }

    private func syncLayers() {
        syncDocumentState()
    }

    // MARK: - Object tree

    /// Selects a node from the object tree. Multi remains the touch extend
    /// contract, so a row tap in Multi mode toggles membership exactly like a
    /// viewport click.
    @discardableResult
    func selectNodeFromTree(_ id: UUID, extend: Bool = false) -> Bool {
        guard documentSession.document.node(withID: id) != nil else { return false }
        selection.click(id, extend: extend || selection.isMultiSelect)
        return true
    }

    /// Renames one node. A locked layer rejects the edit, and a blank or
    /// unchanged name is not a command at all.
    @discardableResult
    func renameNode(_ id: UUID, to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let node = documentSession.document.node(withID: id),
              node.name != name,
              !isLocked(nodeID: id)
        else { return false }
        let changed = documentSession.perform("Rename \(node.name)") { document in
            _ = document.updateNode(withID: id) { $0.name = name }
        }
        guard changed else { return false }
        syncDocumentState()
        documentStatus = "Renamed \(node.name) to \(name)"
        return true
    }

    /// Adds an empty group container. Phase 32 needs a destination the tree can
    /// drag a solid into; grouping an existing selection and ungrouping are the
    /// next phase's commands.
    @discardableResult
    func addObjectGroup(named name: String? = nil) -> UUID? {
        let group = FFNode(
            name: name ?? FFObjectTree.newGroupName(in: documentSession.document),
            layerID: currentLayerID
        )
        let changed = documentSession.perform("Add group \(group.name)") { document in
            document.rootNodes.append(group)
        }
        guard changed else { return nil }
        syncDocumentState()
        documentStatus = "Added \(group.name)"
        return group.id
    }

    /// Nests a node into a group through the one commit path, so the move is
    /// undoable and reaches the journal like any other edit.
    @discardableResult
    func moveNode(_ id: UUID, into parentID: UUID) -> Bool {
        guard !isLocked(nodeID: id) else { return false }
        let changed = documentSession.perform("Move into group") { document in
            _ = document.moveNode(id, into: parentID)
        }
        guard changed else { return false }
        syncDocumentState()
        return true
    }

    /// Reorders the selected node among its siblings. The panel's Up and Down
    /// routes pass -1 and +1; the document clamps and reports whether it moved.
    @discardableResult
    func moveNode(_ id: UUID, by offset: Int) -> Bool {
        guard !isLocked(nodeID: id) else { return false }
        let changed = documentSession.perform("Reorder object") { document in
            _ = document.moveNode(id, by: offset)
        }
        guard changed else { return false }
        syncDocumentState()
        return true
    }

    // MARK: - Grouping and pivots

    /// The selection can be wrapped in one group. The rule lives on the
    /// document so the panel's enabled state and the command cannot disagree.
    var canGroupSelection: Bool {
        documentSession.document.canGroup(Array(selection.selectedIDs))
    }

    func canUngroupSelection() -> Bool {
        guard selection.selectedIDs.count == 1, let id = selection.selectedIDs.first else {
            return false
        }
        return documentSession.document.canUngroup(id)
    }

    /// Wraps the selected siblings in one new container. Grouping is a single
    /// `perform` block, so undo, autosave and the journal treat it exactly like
    /// a rename or a nest; the group starts selected because it is the result.
    @discardableResult
    func groupSelection() -> UUID? {
        let ids = Array(selection.selectedIDs)
        guard !ids.isEmpty, canGroupSelection else {
            documentStatus = "Select sibling objects to group"
            return nil
        }
        var created: UUID?
        let changed = documentSession.perform("Group objects") { document in
            created = document.groupSelection(
                ids,
                named: FFObjectTree.newGroupName(in: document),
                layerID: currentLayerID
            )
        }
        guard changed, let created else {
            documentStatus = "Could not group the selection"
            return nil
        }
        selection.select([created])
        syncDocumentState()
        documentStatus = "Grouped \(ids.count) objects"
        return created
    }

    /// Dissolves the selected group and selects its former children. One undo
    /// step restores the group and every child's world transform.
    @discardableResult
    func ungroupSelection() -> Bool {
        guard selection.selectedIDs.count == 1, let id = selection.selectedIDs.first,
              let group = documentSession.document.node(withID: id), group.geometry == nil
        else {
            documentStatus = "Select a group to ungroup"
            return false
        }
        guard documentSession.document.canUngroup(id) else {
            documentStatus = "Cannot ungroup \(group.name)"
            return false
        }
        let childIDs = group.children.map(\.id)
        let changed = documentSession.perform("Ungroup \(group.name)") { document in
            _ = document.ungroup(id)
        }
        guard changed else {
            documentStatus = "Could not ungroup \(group.name)"
            return false
        }
        selection.select(childIDs)
        syncDocumentState()
        documentStatus = "Ungrouped \(group.name)"
        return true
    }

    /// Applies one axis preset to the selected node's pivot. The preset point is
    /// computed from the node's own subtree, and the edit is one step.
    @discardableResult
    func setPivot(_ id: UUID, preset: FFPivotPreset) -> Bool {
        guard let node = documentSession.document.node(withID: id) else { return false }
        let changed = documentSession.perform("Pivot \(node.name)") { document in
            _ = document.applyPivotPreset(id, preset: preset)
        }
        guard changed else { return false }
        syncDocumentState()
        documentStatus = "Pivot \(preset.label) · \(node.name)"
        return true
    }

    /// Replaces a node's local rotation from degree fields. A group turns about
    /// its pivot and every child follows rigidly through the composed chain.
    @discardableResult
    func setRotation(_ id: UUID, degreesX: Double, degreesY: Double, degreesZ: Double) -> Bool {
        guard let node = documentSession.document.node(withID: id),
              degreesX.isFinite, degreesY.isFinite, degreesZ.isFinite
        else { return false }
        let radians = FFPoint3(
            x: FFMath.radians(degreesX),
            y: FFMath.radians(degreesY),
            z: FFMath.radians(degreesZ)
        )
        let changed = documentSession.perform("Rotate \(node.name)") { document in
            _ = document.setRotation(id, radians: radians)
        }
        guard changed else { return false }
        syncDocumentState()
        documentStatus = "Rotated \(node.name)"
        return true
    }

    /// The transform panel's read-only projection, or nil when the selection is
    /// not a single node. Inheritance and the world value come from the
    /// document, never from a second sum in the view.
    func transformInfo() -> FFTransformInfo? {
        guard selection.selectedIDs.count == 1, let id = selection.selectedIDs.first else {
            return nil
        }
        return documentSession.document.transformInfo(for: id)
    }

    // MARK: - Duplication and arrays

    /// One selected object can be duplicated or wrapped in an array. The rule
    /// lives on the document so the panel's enabled state and the command
    /// cannot disagree, as with grouping.
    var canDuplicateSelection: Bool {
        guard selection.selectedIDs.count == 1, let id = selection.selectedIDs.first else {
            return false
        }
        return documentSession.document.canCopyNode(id)
    }

    var canArraySelection: Bool {
        canDuplicateSelection
    }

    /// Copies the selected subtree beside itself in one step and selects the
    /// copy, because the duplicate is the result the next command acts on.
    @discardableResult
    func duplicateSelection() -> UUID? {
        guard selection.selectedIDs.count == 1, let id = selection.selectedIDs.first,
              let source = documentSession.document.node(withID: id)
        else {
            documentStatus = "Select one object to duplicate"
            return nil
        }
        guard canDuplicateSelection else {
            documentStatus = "Cannot duplicate \(source.name)"
            return nil
        }
        var created: UUID?
        let changed = documentSession.perform("Duplicate \(source.name)") { document in
            created = document.duplicateNode(id)
        }
        guard changed, let created else {
            documentStatus = "Could not duplicate \(source.name)"
            return nil
        }
        selection.select([created])
        syncDocumentState()
        documentStatus = "Duplicated \(source.name)"
        return created
    }

    @discardableResult
    func makeLinearArray(
        count: Int = 3,
        offset: Double = FFArrayParameters.offsetStep * 10,
        direction: FFAxis = .x
    ) -> UUID? {
        makeArray(
            parameters: .linear(count: count, offset: offset, direction: direction),
            status: "Linear array"
        )
    }

    @discardableResult
    func makeRadialArray(
        count: Int = 12,
        axis: FFAxis = .y,
        totalAngle: Double = FFArrayParameters.fullCircle
    ) -> UUID? {
        makeArray(
            parameters: .radial(count: count, axis: axis, totalAngle: totalAngle),
            status: "Radial array"
        )
    }

    /// Builds the array group in one `perform` block and selects it. The group
    /// is what the parameter panel then edits, so a fresh array is immediately
    /// adjustable rather than a one-shot result.
    private func makeArray(parameters: FFArrayParameters, status: String) -> UUID? {
        guard selection.selectedIDs.count == 1, let id = selection.selectedIDs.first,
              let source = documentSession.document.node(withID: id)
        else {
            documentStatus = "Select one object to array"
            return nil
        }
        guard canArraySelection else {
            documentStatus = "Cannot array \(source.name)"
            return nil
        }
        var created: UUID?
        let changed = documentSession.perform("\(status) \(source.name)") { document in
            created = document.makeArray(id, parameters: parameters)
        }
        guard changed, let created else {
            documentStatus = "Could not array \(source.name)"
            return nil
        }
        selection.select([created])
        syncDocumentState()
        documentStatus = "\(parameters.kind.label) array · \(parameters.count) items · \(source.name)"
        return created
    }

    /// The array panel's read-only projection, or nil when the selection is not
    /// an array group.
    func arrayInfo() -> FFArrayInfo? {
        guard selection.selectedIDs.count == 1, let id = selection.selectedIDs.first else {
            return nil
        }
        return documentSession.document.arrayInfo(for: id)
    }

    /// One parameter edit, one undo step. The document refuses an unchanged or
    /// out-of-range value, so a button held at a limit commits nothing.
    @discardableResult
    func updateArray(
        _ id: UUID,
        _ edit: (inout FFArrayParameters) -> Void
    ) -> Bool {
        guard let node = documentSession.document.node(withID: id),
              var parameters = node.array,
              !isLocked(nodeID: id)
        else { return false }
        edit(&parameters)
        guard parameters.isValid else {
            documentStatus = "Array values are out of range"
            return false
        }
        let changed = documentSession.perform("Edit \(node.name) array") { document in
            _ = document.setArrayParameters(id, parameters)
        }
        guard changed else { return false }
        syncDocumentState()
        documentStatus = "\(parameters.kind.label) array · \(parameters.count) items"
        return true
    }

    @discardableResult
    func adjustArrayCount(_ id: UUID, by delta: Int) -> Bool {
        updateArray(id) {
            $0.count = min(
                max($0.count + delta, FFArrayParameters.minimumCount),
                FFArrayParameters.maximumCount
            )
        }
    }

    @discardableResult
    func adjustArrayOffset(_ id: UUID, by delta: Double) -> Bool {
        updateArray(id) { $0.offset = max(0, $0.offset + delta) }
    }

    @discardableResult
    func adjustArrayAngle(_ id: UUID, by delta: Double) -> Bool {
        updateArray(id) {
            $0.totalAngle = min(
                max($0.totalAngle + delta, 1),
                FFArrayParameters.fullCircle
            )
        }
    }

    @discardableResult
    func setArrayDirection(_ id: UUID, direction: FFAxis) -> Bool {
        updateArray(id) { $0.direction = direction }
    }

    @discardableResult
    func setArrayAxis(_ id: UUID, axis: FFAxis) -> Bool {
        updateArray(id) { $0.axis = axis }
    }

    // MARK: - Materials

    /// The material sheet's read-only projection. The selected node supplies
    /// its face groups; lock is resolved here so the panel never reads layers.
    func materialInfo() -> FFMaterialInfo {
        let selectedID: UUID? = selection.selectedIDs.count == 1
            ? selection.selectedIDs.first
            : nil
        return documentSession.document.materialInfo(
            for: selectedID,
            isLocked: selectedID.map { isLocked(nodeID: $0) } ?? false
        )
    }

    /// Applies an alloy preset to one document material. Every face that names
    /// the material — a node's base material or any face group — changes with
    /// it, and the whole change is one undo step.
    @discardableResult
    func setMaterialPreset(_ id: UUID, preset: FFAlloyPreset) -> Bool {
        guard let material = documentSession.document.material(withID: id) else {
            return false
        }
        let changed = documentSession.perform("Alloy \(preset.label) · \(material.name)") { document in
            _ = document.setMaterialPreset(id, preset: preset)
        }
        guard changed else { return false }
        syncDocumentState()
        documentStatus = "\(material.name) · \(preset.label)"
        return true
    }

    @discardableResult
    func adjustMaterialMetallic(_ id: UUID, by delta: Double) -> Bool {
        guard let material = documentSession.document.material(withID: id) else {
            return false
        }
        let next = FFMath.clamp(material.metallic + delta, to: 0...1)
        guard next != material.metallic else { return false }
        let changed = documentSession.perform("Metallic \(material.name)") { document in
            _ = document.setMaterialParameters(id, metallic: next)
        }
        guard changed else { return false }
        syncDocumentState()
        documentStatus = "\(material.name) · metallic \(FFPrecision.fixed(next, decimals: 2))"
        return true
    }

    @discardableResult
    func adjustMaterialRoughness(_ id: UUID, by delta: Double) -> Bool {
        guard let material = documentSession.document.material(withID: id) else {
            return false
        }
        let next = FFMath.clamp(material.roughness + delta, to: 0...1)
        guard next != material.roughness else { return false }
        let changed = documentSession.perform("Roughness \(material.name)") { document in
            _ = document.setMaterialParameters(id, roughness: next)
        }
        guard changed else { return false }
        syncDocumentState()
        documentStatus = "\(material.name) · roughness \(FFPrecision.fixed(next, decimals: 2))"
        return true
    }

    /// A colour-picker drag emits a stream of values; the coalescing key keeps
    /// the whole drag as one undo step while still writing the journal on every
    /// committed colour.
    @discardableResult
    func setMaterialColor(_ id: UUID, color: FFRGBA) -> Bool {
        guard let material = documentSession.document.material(withID: id) else {
            return false
        }
        let changed = documentSession.perform(
            "Colour \(material.name)",
            coalescingKey: "material-colour-\(id.uuidString)"
        ) { document in
            _ = document.setMaterialParameters(id, baseColor: color)
        }
        guard changed else { return false }
        syncDocumentState()
        documentStatus = "\(material.name) · colour"
        return true
    }

    /// Assigns a material to all of a mesh node's faces that no face group
    /// owns. On a node without groups that is the whole object.
    @discardableResult
    func assignMaterialToNode(_ nodeID: UUID, materialID: UUID) -> Bool {
        guard let node = documentSession.document.node(withID: nodeID),
              node.meshTriangleCount > 0,
              !isLocked(nodeID: nodeID),
              documentSession.document.material(withID: materialID) != nil
        else { return false }
        let changed = documentSession.perform("Assign material to \(node.name)") { document in
            _ = document.setNodeMaterial(nodeID: nodeID, materialID: materialID)
        }
        guard changed else { return false }
        syncDocumentState()
        documentStatus = "\(node.name) · base material"
        return true
    }

    @discardableResult
    func assignMaterialToFaceGroup(
        nodeID: UUID,
        groupID: UUID,
        materialID: UUID
    ) -> Bool {
        guard let node = documentSession.document.node(withID: nodeID),
              let group = node.faceGroups?.first(where: { $0.id == groupID }),
              !isLocked(nodeID: nodeID),
              documentSession.document.material(withID: materialID) != nil
        else { return false }
        let changed = documentSession.perform("Assign \(group.name)") { document in
            _ = document.setFaceGroupMaterial(
                nodeID: nodeID,
                groupID: groupID,
                materialID: materialID
            )
        }
        guard changed else { return false }
        syncDocumentState()
        documentStatus = "\(group.name) · material"
        return true
    }

    @discardableResult
    func removeFaceGroup(nodeID: UUID, groupID: UUID) -> Bool {
        guard let node = documentSession.document.node(withID: nodeID),
              node.faceGroups?.contains(where: { $0.id == groupID }) == true,
              !isLocked(nodeID: nodeID)
        else { return false }
        let changed = documentSession.perform("Remove face group") { document in
            _ = document.removeFaceGroup(nodeID: nodeID, groupID: groupID)
        }
        guard changed else { return false }
        syncDocumentState()
        documentStatus = "\(node.name) · face group removed"
        return true
    }

    /// The one commit path for a new face group. The panel has no creation
    /// command yet; the document bridge and tests use this to establish the
    /// subsets that imported and modelled geometry will carry.
    @discardableResult
    func assignFaceGroup(
        nodeID: UUID,
        name: String,
        materialID: UUID,
        triangles: [Int]
    ) -> UUID? {
        guard let node = documentSession.document.node(withID: nodeID),
              !isLocked(nodeID: nodeID),
              documentSession.document.material(withID: materialID) != nil
        else { return nil }
        var created: UUID?
        let changed = documentSession.perform("Assign faces on \(node.name)") { document in
            created = document.assignFaceGroup(
                nodeID: nodeID,
                name: name,
                materialID: materialID,
                triangles: triangles
            )
        }
        guard changed, let created else { return nil }
        syncDocumentState()
        documentStatus = "\(node.name) · \(triangles.count) faces"
        return created
    }

    /// One metadata text edit. Text arrives per keystroke, so the field's own
    /// coalescing key keeps a whole typing session as one undo step; a value
    /// that did not change records nothing.
    @discardableResult
    func setMetadataField(_ field: FFMetadataField, value: String) -> Bool {
        guard documentSession.document.resolvedMetadata.value(for: field) != value else {
            return false
        }
        let changed = documentSession.perform(
            field.label,
            coalescingKey: "metadata-\(field.rawValue)"
        ) { document in
            _ = document.setMetadataField(field, value: value)
        }
        guard changed else { return false }
        syncDocumentState()
        documentStatus = "\(field.label) updated"
        return true
    }

    /// A manufacturing flag is one deliberate decision, so it is its own undo
    /// step rather than part of a typing coalesce.
    @discardableResult
    func toggleManufacturingFlag(_ flag: FFManufacturingFlag) -> Bool {
        let enabled = !documentSession.document.resolvedMetadata.isFlagEnabled(flag)
        let changed = documentSession.perform("Manufacturing · \(flag.label)") { document in
            _ = document.setManufacturingFlag(flag, enabled: enabled)
        }
        guard changed else { return false }
        syncDocumentState()
        documentStatus = "\(flag.label) \(enabled ? "on" : "off")"
        return true
    }

    /// Rebuilds every published value that is derived from the document. The
    /// document session remains the only owner; this is the projection the
    /// shell renders.
    private func syncDocumentState() {
        let document = documentSession.document
        scene = Self.scene(from: document)
        displayModes = document.displayModes
        layers = document.layers
        currentLayerID = document.currentLayerID
        rootNodes = document.rootNodes
        layerSets = document.layerSets
        activeLayerSetID = document.activeLayerSetID
        measurements = document.measurements.map(\.measurement)
        curveNodes = document.curveRenders()
        metadata = document.resolvedMetadata
        stoneSummary = document.stoneSummary()
        if !isLoading {
            noteEdit()
        }
    }

    // MARK: - Document commands

    /// Replaces the current document with a new, empty one. This is a document
    /// command, not an undoable edit: undo must not resurrect a file the user
    /// discarded before the new document existed.
    func newDocument() {
        isLoading = true
        let document = FFDocument(name: "Untitled")
        documentSession = FFDocumentSession(document: document)
        syncDocumentState()
        isLoading = false
        resetJournal(clearOnDisk: true)
        selection = FFSelectionState()
        documentURL = nil
        preservation = nil
        recoveryMessage = nil
        migrationReport = nil
        cancelLineChain()
        cancelArc()
        isDirty = false
        autosaveMessage = nil
        documentStatus = "New document"
    }

    /// Loads the shipping bench sample as a fresh, unsaved document and selects
    /// its stone, the state the smoke suite then orbits and edits.
    func loadFixture() {
        isLoading = true
        let sample = FFDocument.benchSample
        documentSession = FFDocumentSession(document: sample.document)
        syncDocumentState()
        isLoading = false
        resetJournal(clearOnDisk: true)
        selection = FFSelectionState(selectedIDs: sample.selectedNodeIDs)
        documentURL = nil
        preservation = nil
        recoveryMessage = nil
        migrationReport = nil
        cancelLineChain()
        cancelArc()
        isDirty = false
        autosaveMessage = nil
        documentStatus = "Fixture loaded"
    }

    /// Starts a document from one of the Phase 37 templates.
    ///
    /// The template is written to a real `.ffp` bundle and then opened through
    /// the normal reader, so nothing downstream needs a template branch: the
    /// new document has a file, a thumbnail, a bundle checksum list and an
    /// empty undo history from the moment it appears. An existing name is never
    /// overwritten; a second copy is numbered like a duplicate.
    @discardableResult
    func createDocument(from template: FFDocumentTemplate) throws -> URL {
        let directory = libraryDirectory
        let fileManager = FileManager.default
        var target = directory
            .appendingPathComponent(template.fileBaseName)
            .appendingPathExtension("ffp")
        var index = 2
        while fileManager.fileExists(atPath: target.path) {
            target = directory
                .appendingPathComponent("\(template.fileBaseName) \(index)")
                .appendingPathExtension("ffp")
            index += 1
        }

        let document = template.makeDocument()
        try store.save(
            document,
            to: target,
            thumbnail: FFPThumbnail.png(for: document)
        )
        try reopen(from: target)
        refreshLibrary()
        documentStatus = "New \(template.title)"
        return target
    }

    /// Commits one gizmo interaction. The gizmo reports its world matrix when
    /// the drag ends; this converts it to the node's local transform, writes it
    /// through the document session and rebuilds the scene. `dragKey` is unique
    /// per gesture, so a drag that reports more than one frame still produces
    /// exactly one coalesced history entry.
    @discardableResult
    func commitGizmoTransform(
        nodeID: UUID,
        worldTransform: Mat4,
        dragKey: String
    ) -> Bool {
        guard let node = documentSession.document.node(withID: nodeID),
              !isLocked(nodeID: nodeID)
        else { return false }
        let local = localTransform(for: nodeID, world: worldTransform)
        let changed = documentSession.perform(
            "Transform \(node.name)",
            coalescingKey: dragKey
        ) { document in
            document.updateNode(withID: nodeID) { $0.transform = local }
        }
        guard changed else { return false }
        syncDocumentState()
        documentStatus = "Moved \(node.name)"
        return true
    }

    /// Commits one completed measurement as a document annotation. The unique
    /// key makes a repeated completion of the same measurement coalesce instead
    /// of adding a second history entry; two different measurements never share
    /// a step.
    @discardableResult
    func addMeasurement(_ measurement: FFMeasurement) -> Bool {
        guard measurement.isComplete, measurement.value != nil else { return false }
        guard !documentSession.document.measurements.contains(where: { $0.id == measurement.id }) else {
            return false
        }
        let changed = documentSession.perform(
            "Measurement \(measurement.kind.label)",
            coalescingKey: "measurement-\(measurement.id.uuidString)"
        ) { document in
            document.measurements.append(FFMeasurementAnnotation(measurement))
        }
        guard changed else { return false }
        syncDocumentState()
        documentStatus = "Measurement \(measurement.kind.label)"
        return true
    }

    @discardableResult
    func clearMeasurements() -> Bool {
        guard !documentSession.document.measurements.isEmpty else { return false }
        let changed = documentSession.perform("Clear measurements") { document in
            document.measurements.removeAll()
        }
        guard changed else { return false }
        syncDocumentState()
        documentStatus = "Measurements cleared"
        return true
    }

    // MARK: - Line chain tool

    /// The live segment readout: length and angle from the last vertex to the
    /// pending point. `nil` until a direction exists.
    var lineChainReadout: FFLineSegmentMeasure? { lineChainDraft.pendingMeasure }

    /// Starts a chain at a sketch-plane point. Starting again replaces an
    /// unfinished chain rather than silently joining two unrelated ones.
    func beginLineChain(at point: Vec2) {
        lineChainDraft.begin(at: point)
        lineToolMessage = nil
    }

    /// Moves the rubber-band point. This changes only tool state, never the
    /// document, so hovering or dragging cannot create an undo step.
    func previewLineChain(at point: Vec2) {
        guard lineChainDraft.isActive, !lineChainDraft.isClosed else { return }
        lineChainDraft.preview(to: point)
    }

    /// A viewport tap, already resolved to the sketch plane. `nil` means the
    /// tap met neither geometry nor the plane; that is a refusal with a
    /// sentence, not a silently dropped touch.
    @discardableResult
    func tapLineChain(at point: Vec2?) -> Bool {
        guard let point else {
            lineToolMessage = "That tap meets neither geometry nor the sketch plane"
            return false
        }
        return addLineChainPoint(at: point)
    }

    /// Commits one tapped point. A tap on the first vertex closes the chain
    /// instead of adding a duplicate; returns whether it closed.
    @discardableResult
    func addLineChainPoint(at point: Vec2) -> Bool {
        guard lineChainDraft.isActive else {
            beginLineChain(at: point)
            return false
        }
        lineChainDraft.preview(to: point)
        do {
            let closed = try lineChainDraft.commitPending()
            lineToolMessage = closed ? "Closed chain · press Finish" : nil
            return closed
        } catch {
            lineToolMessage = Self.lineMessage(for: error)
            return false
        }
    }

    /// Typed length entry: the pending direction decides the bearing, the typed
    /// number decides the distance, so a dimension never depends on pointer
    /// accuracy. The value arrives in the document's display unit and is
    /// stored in millimetres.
    @discardableResult
    func typeLineChainLength(_ text: String, unit: FFLengthUnit) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite else {
            lineToolMessage = FFLineChainError.invalidLength(trimmed).errorDescription
            return false
        }
        do {
            _ = try lineChainDraft.commitTypedLength(unit.millimetres(from: value))
            lineToolMessage = nil
            return true
        } catch {
            lineToolMessage = Self.lineMessage(for: error)
            return false
        }
    }

    /// Closes the chain geometrically, from the last vertex back to the first.
    @discardableResult
    func closeLineChain() -> Bool {
        do {
            try lineChainDraft.close()
            lineToolMessage = "Closed chain · press Finish"
            return true
        } catch {
            lineToolMessage = Self.lineMessage(for: error)
            return false
        }
    }

    /// Commits the draft as one curve node. One `perform` means one undo step
    /// and the same journal and autosave path as every other edit.
    @discardableResult
    func finishLineChain() -> Bool {
        guard lineChainDraft.isActive else {
            lineToolMessage = "Start a chain by tapping the sketch plane"
            return false
        }
        do {
            let payload = try lineChainDraft.payload()
            let name = nextCurveName()
            let segmentCount = payload.segments.count
            let changed = documentSession.perform("Line chain") { document in
                document.rootNodes.append(FFNode(
                    name: name,
                    geometry: .curve(payload),
                    kind: .curve,
                    layerID: document.currentLayerID
                ))
            }
            guard changed else { return false }
            lineChainDraft.cancel()
            lineToolMessage = nil
            syncDocumentState()
            documentStatus = payload.isClosed
                ? "Line chain · \(segmentCount) segments · closed"
                : "Line chain · \(segmentCount) segments"
            return true
        } catch {
            lineToolMessage = Self.lineMessage(for: error)
            return false
        }
    }

    func cancelLineChain() {
        lineChainDraft.cancel()
        lineToolMessage = nil
    }

    private static func lineMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func nextCurveName(base: String = "Line chain") -> String {
        let names = documentSession.document.curveNodeNames()
        guard names.contains(base) else { return base }
        var index = 2
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    // MARK: - Arc tool

    /// The arc draft's preview in world space. Empty until all three points
    /// arrive, so a view never draws a half-built arc as if it were final.
    var arcPreview: [Vec3] { arcDraft.preview }

    /// Starts an arc in one of Phase 40's three constructions. Starting again
    /// replaces an unfinished draft rather than mixing two constructions.
    func beginArc(mode: FFArcMode) {
        arcDraft.begin(mode: mode)
        arcToolMessage = nil
    }

    /// A viewport tap, already resolved to the sketch plane. The third
    /// successful point completes the construction; the caller still decides
    /// when to commit it.
    @discardableResult
    func tapArc(at point: Vec2?) -> Bool {
        guard let point else {
            arcToolMessage = "That tap meets neither geometry nor the sketch plane"
            return false
        }
        do {
            let complete = try arcDraft.add(point)
            arcToolMessage = complete ? "Arc ready · press Finish" : nil
            return complete
        } catch {
            arcToolMessage = Self.arcMessage(for: error)
            return false
        }
    }

    /// Commits the finished arc as one curve node. One `perform` means one undo
    /// step and the same journal and autosave path as every other edit.
    @discardableResult
    func finishArc() -> Bool {
        guard let arc = arcDraft.arc else {
            arcToolMessage = FFArcError.notEnoughPoints.errorDescription
            return false
        }
        do {
            let payload = try arcDraft.payload()
            let name = nextCurveName(base: "Arc")
            let changed = documentSession.perform("Arc") { document in
                document.rootNodes.append(FFNode(
                    name: name,
                    geometry: .curve(payload),
                    kind: .curve,
                    layerID: document.currentLayerID
                ))
            }
            guard changed else { return false }
            arcDraft.cancel()
            arcToolMessage = nil
            syncDocumentState()
            documentStatus = "Arc · \(FFPrecision.lengthString(millimetres: arc.radius, unit: .millimetres)) radius · \(FFPrecision.angleString(degrees: abs(arc.sweepDegrees)))"
            return true
        } catch {
            arcToolMessage = Self.arcMessage(for: error)
            return false
        }
    }

    func cancelArc() {
        arcDraft.cancel()
        arcToolMessage = nil
    }

    private static func arcMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: - Primitive curves

    /// The selected node's primitive, or nil when the selection is not one
    /// parametric primitive. The panel reads this projection; the document
    /// remains the owner of the parameters.
    func primitiveInfo() -> FFPrimitiveInfo? {
        guard selection.selectedIDs.count == 1, let id = selection.selectedIDs.first else {
            return nil
        }
        return documentSession.document.primitiveInfo(for: id)
    }

    /// Creates a primitive at the sketch origin as one undoable edit and
    /// selects it, so the next command edits what was just made.
    @discardableResult
    func addPrimitive(kind: FFCurvePrimitiveKind) -> UUID? {
        let primitive = FFCurvePrimitive(kind: kind)
        var created: UUID?
        let changed = documentSession.perform("Add \(kind.label)") { document in
            created = document.addPrimitive(
                primitive,
                name: kind.label,
                layerID: document.currentLayerID
            )
        }
        guard changed, let created else {
            documentStatus = "Could not add \(kind.label)"
            return nil
        }
        selection.select([created])
        syncDocumentState()
        documentStatus = "\(kind.label) · \(primitive.summary(unit: documentSession.document.displayUnit))"
        return created
    }

    /// One parameter edit of the selected primitive, one undo step. The
    /// document refuses an unchanged or out-of-range value, so a held button
    /// commits nothing; a valid edit regenerates the payload in place and never
    /// touches the node's transform or centre.
    @discardableResult
    func setPrimitiveField(_ field: FFPrimitiveField, to value: Double) -> Bool {
        guard let info = primitiveInfo() else {
            documentStatus = "Select a primitive curve to edit it"
            return false
        }
        var edited = info.primitive
        guard edited.set(field, to: value) else {
            documentStatus = Self.primitiveMessage(for: field, kind: info.primitive.kind, value: value, primitive: info.primitive)
            return false
        }
        let changed = documentSession.perform("Edit \(info.primitive.kind.label)") { document in
            _ = document.setPrimitive(info.nodeID) { primitive in
                primitive.set(field, to: value)
            }
        }
        guard changed else {
            documentStatus = "\(field.label) is out of range"
            return false
        }
        syncDocumentState()
        documentStatus = "\(info.primitive.kind.label) · \(edited.summary(unit: documentSession.document.displayUnit))"
        return true
    }

    /// The sentence for a refused edit. It names the field and the rule rather
    /// than repeating a generic range error, because the refusal is the only
    /// feedback a thumb gets.
    private static func primitiveMessage(
        for field: FFPrimitiveField,
        kind: FFCurvePrimitiveKind,
        value: Double,
        primitive: FFCurvePrimitive
    ) -> String {
        guard value.isFinite else {
            return FFPrimitiveError.notFinite.errorDescription ?? "Invalid value"
        }
        switch (kind, field) {
        case (.roundedRectangle, .cornerRadius):
            return FFPrimitiveError.cornerTooLarge(
                maximum: min(primitive.width, primitive.height) / 2
            ).errorDescription ?? "Corner radius is out of range"
        case (.polygon, .sides):
            return FFPrimitiveError.tooFewSides.errorDescription ?? "Sides are out of range"
        case (_, .radius), (_, .diameter), (_, .width), (_, .height):
            return FFPrimitiveError.nonPositiveSize.errorDescription ?? "Size is out of range"
        default:
            return FFPrimitiveError.fieldNotAvailable.errorDescription ?? "Parameter is not available"
        }
    }

    // MARK: - Interchange

    /// Imports a parsed OBJ as one undoable document edit. Materials and nodes
    /// are appended to the current layer; the session, not the view, owns the
    /// commit and the journal, so an import is undone and autosaved like any
    /// other edit.
    @discardableResult
    func importOBJ(_ asset: FFOBJAsset, label: String = "OBJ") -> Int {
        let built = FFOBJDocumentBuilder.build(asset, layerID: currentLayerID)
        guard !built.nodes.isEmpty else { return 0 }
        let changed = documentSession.perform("Import \(label)") { document in
            document.materials.append(contentsOf: built.materials)
            document.rootNodes.append(contentsOf: built.nodes)
        }
        guard changed else { return 0 }
        syncDocumentState()
        documentStatus = "Imported \(label) · \(built.nodes.count) objects"
        return built.nodes.count
    }

    @discardableResult
    func undo() -> Bool {
        guard documentSession.undo() else { return false }
        syncDocumentState()
        documentStatus = "Undo"
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard documentSession.redo() else { return false }
        syncDocumentState()
        documentStatus = "Redo"
        return true
    }

    /// The node's parent world matrix, or identity for a root. A gizmo matrix
    /// is in world space; the document stores local transforms, so a nested
    /// node must have its parent's transform removed before the commit. The
    /// node's pivot is kept: the conversion solves T for the pivot-aware form
    /// so a drag on a pivot-bearing node does not bake the pivot offset into
    /// its translation.
    private func localTransform(for nodeID: UUID, world: Mat4) -> FFTransform {
        let document = documentSession.document
        let pivot = document.node(withID: nodeID)?.effectivePivot.vector
            ?? Vec3(x: 0, y: 0, z: 0)
        guard let parent = document.parentWorldMatrix(of: nodeID),
              let inverse = parent.inverse()
        else { return FFTransform(matrix: world, pivot: pivot) }
        return FFTransform(matrix: inverse * world, pivot: pivot)
    }

    /// Saves to `url`, or to the last known URL. A document that has never been
    /// saved goes to the app's Documents directory.
    func save(to url: URL? = nil) throws {
        try saveDocument(to: url, isAutosave: false)
    }

    private func saveDocument(to url: URL?, isAutosave: Bool) throws {
        let destination = url ?? documentURL ?? Self.defaultDocumentURL
        try store.save(
            documentSession.document,
            to: destination,
            preservation: preservation,
            thumbnail: FFPThumbnail.png(for: documentSession.document)
        )
        documentURL = destination
        isDirty = false
        if isAutosave {
            lastAutosaveAt = now()
        }
        autosaveMessage = isAutosave ? "Autosaved \(destination.lastPathComponent)" : nil
        prepareJournalForSavedDocument(at: destination)
        documentStatus = isAutosave
            ? "Autosaved \(destination.lastPathComponent)"
            : "Saved \(destination.lastPathComponent)"
    }

    /// Runs one autosave. A save is only written when an edit is pending; an
    /// idle document does not rewrite its bundle every thirty seconds.
    @discardableResult
    func autosaveIfNeeded() -> Bool {
        guard isDirty else {
            autosaveMessage = nil
            return false
        }
        do {
            try saveDocument(to: nil, isAutosave: true)
            return true
        } catch {
            autosaveMessage = "Autosave failed: \(error.localizedDescription)"
            documentStatus = "Autosave failed"
            return false
        }
    }

    /// The scene-phase hook. Backgrounding is a save point, not a promise that
    /// the process will get another run-loop turn.
    func autosaveForBackground() {
        _ = autosaveIfNeeded()
    }

    func startAutosave() {
        stopAutosave()
        guard autosaveInterval > 0 else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: autosaveInterval, repeats: true) { [weak self] _ in
            self?.autosaveIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        autosaveTimer = timer
    }

    func stopAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
    }

    func reopen() throws {
        guard let documentURL else { return }
        try reopen(from: documentURL)
    }

    /// Opens a document handed over by Files. The security-scoped access is
    /// held only for the read; the session keeps working from the in-place URL,
    /// which the document declaration in Info.plist permits.
    func openExternalDocument(at url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        try reopen(from: url)
        refreshLibrary()
    }

    /// Loads a document from disk and replaces the scene, modes and selection.
    /// The undo history is reset: undo must never reach across a reopened file.
    func reopen(from url: URL) throws {
        let loaded = try store.loadContent(from: url)
        isLoading = true
        documentSession = FFDocumentSession(document: loaded.document)
        syncDocumentState()
        isLoading = false
        documentURL = url
        preservation = loaded.preservation
        recoveryMessage = loaded.recovery?.message
        migrationReport = loaded.migration
        cancelLineChain()
        cancelArc()
        selection = FFSelectionState.initial(for: scene)
        isDirty = false
        lastAutosaveAt = nil
        autosaveMessage = nil
        attachJournalAfterOpen(at: url)
        if recoveryOffer == nil {
            if let migration = loaded.migration {
                documentStatus = "\(migration.headline) · \(url.lastPathComponent)"
            } else {
                documentStatus = loaded.recovery == nil
                    ? "Reopened \(url.lastPathComponent)"
                    : "Recovered last good save · \(url.lastPathComponent)"
            }
        }
    }

    // MARK: - Document library

    /// Rescans the folder that holds the open document. A new, unsaved
    /// document browses the app's Documents directory.
    func refreshLibrary() {
        library = FFDocumentLibrary(directory: libraryDirectory).documents()
    }

    var libraryDirectory: URL {
        documentURL?.deletingLastPathComponent() ?? Self.documentsDirectory
    }

    /// Renames a document on disk. Renaming the open document retargets the
    /// session, including its journal, without clearing unsaved edits.
    @discardableResult
    func renameDocument(at url: URL, to name: String) throws -> URL {
        let renamed = try FFDocumentLibrary(directory: libraryDirectory).rename(url, to: name)
        if let current = documentURL, FFDocumentLibrary.isSameDocument(current, url) {
            documentURL = renamed
            journal = FFEditJournal(directory: FFEditJournal.defaultDirectory(for: renamed))
            journalSnapshotCount = journal?.entryCount ?? 0
            documentStatus = "Renamed \(renamed.lastPathComponent)"
        }
        refreshLibrary()
        return renamed
    }

    /// Copies a document. The copy is a new file with no recovery state.
    @discardableResult
    func duplicateDocument(at url: URL) throws -> URL {
        let copy = try FFDocumentLibrary(directory: libraryDirectory).duplicate(url)
        refreshLibrary()
        return copy
    }

    /// Removes a document. The open document is protected here rather than in
    /// the view, so a stale cell cannot delete the file the session is editing.
    func deleteDocument(at url: URL) throws {
        if let current = documentURL, FFDocumentLibrary.isSameDocument(current, url) {
            throw FFLibraryError.cannotModifyOpenDocument
        }
        try FFDocumentLibrary(directory: libraryDirectory).delete(url)
        refreshLibrary()
    }

    // MARK: - Crash recovery

    /// Applies the newest journal snapshot as the live document. The restored
    /// state is journaled again immediately, so a kill during the resolution of
    /// a recovery prompt cannot lose the recovered edits.
    @discardableResult
    func restoreRecovery() -> Bool {
        guard let offer = recoveryOffer else { return false }
        isLoading = true
        documentSession = FFDocumentSession(document: offer.document)
        syncDocumentState()
        isLoading = false
        selection = FFSelectionState.initial(for: scene)
        recoveryOffer = nil
        isDirty = true
        documentStatus = "Restored \(offer.snapshotCount) unsaved "
            + (offer.snapshotCount == 1 ? "edit" : "edits")
        recordJournalSnapshot(at: now())
        return true
    }

    @discardableResult
    func discardRecovery() -> Bool {
        guard recoveryOffer != nil else { return false }
        journal?.clear()
        journalSnapshotCount = 0
        recoveryOffer = nil
        documentStatus = "Discarded unsaved edits"
        return true
    }

    private func noteEdit() {
        isDirty = true
        recordJournalSnapshot(at: now())
    }

    /// Writes the current document as the next journal snapshot. Synchronous on
    /// purpose: an edit that is only queued for later can be lost by a kill
    /// before the queue runs, which is exactly what this phase forbids.
    private func recordJournalSnapshot(at date: Date) {
        guard let journal else { return }
        do {
            try journal.record(documentSession.document, at: date)
            journalSnapshotCount = journal.entryCount
        } catch {
            autosaveMessage = "Journal write failed: \(error.localizedDescription)"
        }
    }

    private func prepareJournalForSavedDocument(at url: URL) {
        let journal = FFEditJournal(directory: FFEditJournal.defaultDirectory(for: url))
        journal.clear()
        self.journal = journal
        journalSnapshotCount = 0
        recoveryOffer = nil
    }

    private func attachJournalAfterOpen(at url: URL) {
        let journal = FFEditJournal(directory: FFEditJournal.defaultDirectory(for: url))
        self.journal = journal
        journalSnapshotCount = journal.entryCount
        if let snapshot = journal.latest() {
            recoveryOffer = FFJournalRecoveryOffer(
                document: snapshot.document,
                recordedAt: snapshot.recordedAt,
                snapshotCount: journalSnapshotCount,
                documentName: snapshot.document.name
            )
            documentStatus = "Unsaved edits found · \(url.lastPathComponent)"
        } else {
            recoveryOffer = nil
        }
    }

    private func resetJournal(clearOnDisk: Bool) {
        if clearOnDisk {
            journal?.clear()
        }
        journal = nil
        journalSnapshotCount = 0
        recoveryOffer = nil
    }

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    static var defaultDocumentURL: URL {
        documentsDirectory.appendingPathComponent("Untitled.ffp")
    }

    /// Flattens the document's node tree into the flat scene the renderer
    /// consumes. Parent transforms compose into world transforms, and a node
    /// without mesh geometry contributes no drawable but still passes its
    /// transform to its children.
    static func scene(from document: FFDocument) -> FFViewportScene {
        var nodes: [FFRenderNode] = []

        func visit(_ node: FFNode, parent: Mat4) {
            let world = parent * node.localMatrix
            if case .mesh(let payload)? = node.geometry,
               let mesh = payload.mesh,
               let renderMesh = FFRenderMesh(mesh: mesh) {
                let material = node.materialID
                    .flatMap { document.material(withID: $0) }
                    .map(FFRenderMaterial.init(from:)) ?? .gold
                let layer = document.layer(forNodeID: node.id)
                let parts: [FFRenderPart] = document.faceAssignments(for: node.id).compactMap { assignment in
                    var indices: [UInt32] = []
                    indices.reserveCapacity(assignment.triangles.count * 3)
                    for triangleIndex in assignment.triangles {
                        guard triangleIndex >= 0, triangleIndex < mesh.triangles.count else {
                            continue
                        }
                        let triangle = mesh.triangles[triangleIndex]
                        indices.append(UInt32(triangle.a))
                        indices.append(UInt32(triangle.b))
                        indices.append(UInt32(triangle.c))
                    }
                    guard !indices.isEmpty else { return nil }
                    let surface = assignment.materialID
                        .flatMap { document.material(withID: $0) }
                        .map(FFRenderMaterial.init(from:)) ?? material
                    return FFRenderPart(
                        id: assignment.groupIDs.first ?? node.id,
                        mesh: FFRenderMesh(
                            positions: renderMesh.positions,
                            normals: renderMesh.normals,
                            indices: indices
                        ),
                        material: surface
                    )
                }
                nodes.append(FFRenderNode(
                    id: node.id,
                    name: node.name,
                    mesh: renderMesh,
                    transform: world,
                    material: material,
                    kind: node.kind ?? .solid,
                    isVisible: node.isVisible && (layer?.isVisible ?? true),
                    layerColor: layer?.color ?? FFRGBA.gold,
                    parts: parts
                ))
            }
            for child in node.children {
                visit(child, parent: world)
            }
        }

        for root in document.rootNodes {
            visit(root, parent: .identity)
        }
        return FFViewportScene(nodes: nodes)
    }
}

extension FFRenderMaterial {
    /// The document stores a richer material; the renderer only needs the
    /// surface colour and the two scalar terms.
    init(from material: FFMaterial) {
        self.init(
            baseColor: material.baseColor,
            metallic: material.metallic,
            roughness: material.roughness
        )
    }
}
