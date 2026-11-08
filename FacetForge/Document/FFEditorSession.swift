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
    /// The last document command, shown in the app bar so a smoke run can read
    /// back that save and reopen actually happened.
    @Published private(set) var documentStatus: String
    /// The reason a reopen used the last good save. `nil` on a normal open.
    @Published private(set) var recoveryMessage: String?
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
        self.documentStatus = initial.name
        self.recoveryMessage = nil
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
        isDirty = false
        autosaveMessage = nil
        documentStatus = "Fixture loaded"
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
    /// node must have its parent's transform removed before the commit.
    private func localTransform(for nodeID: UUID, world: Mat4) -> FFTransform {
        guard let parent = parentWorldTransform(of: nodeID),
              let inverse = parent.inverse()
        else { return FFTransform(matrix: world) }
        return FFTransform(matrix: inverse * world)
    }

    private func parentWorldTransform(of nodeID: UUID) -> Mat4? {
        func search(_ node: FFNode, parent: Mat4) -> Mat4? {
            if node.id == nodeID { return parent }
            let world = parent * node.transform.matrix
            for child in node.children {
                if let found = search(child, parent: world) { return found }
            }
            return nil
        }
        for root in documentSession.document.rootNodes {
            if let found = search(root, parent: .identity) { return found }
        }
        return nil
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
        selection = FFSelectionState.initial(for: scene)
        isDirty = false
        lastAutosaveAt = nil
        autosaveMessage = nil
        attachJournalAfterOpen(at: url)
        if recoveryOffer == nil {
            documentStatus = loaded.recovery == nil
                ? "Reopened \(url.lastPathComponent)"
                : "Recovered last good save · \(url.lastPathComponent)"
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
            let world = parent * node.transform.matrix
            if case .mesh(let payload)? = node.geometry,
               let mesh = payload.mesh,
               let renderMesh = FFRenderMesh(mesh: mesh) {
                let material = node.materialID
                    .flatMap { document.material(withID: $0) }
                    .map(FFRenderMaterial.init(from:)) ?? .gold
                let layer = document.layer(forNodeID: node.id)
                nodes.append(FFRenderNode(
                    id: node.id,
                    name: node.name,
                    mesh: renderMesh,
                    transform: world,
                    material: material,
                    kind: node.kind ?? .solid,
                    isVisible: node.isVisible && (layer?.isVisible ?? true),
                    layerColor: layer?.color ?? FFRGBA.gold
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
