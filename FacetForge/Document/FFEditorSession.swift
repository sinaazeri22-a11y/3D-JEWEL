import Combine
import Foundation

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

    private(set) var documentSession: FFDocumentSession
    private let store: FFDocumentStore
    /// What the bundle reader did not understand. Kept across edits so a save
    /// rewrites a future minor writer's fields alongside this version's.
    private var preservation: FFPBundlePreservation?

    /// A new session. With no document argument the bench sample is loaded and
    /// its stone opens selected, which is the state Phase 17's CI asserts.
    init(
        document: FFDocument? = nil,
        documentURL: URL? = nil,
        store: FFDocumentStore = FFDocumentStore()
    ) {
        let sample = FFDocument.benchSample
        let initial = document ?? sample.document
        self.store = store
        self.documentSession = FFDocumentSession(document: initial)
        self.scene = Self.scene(from: initial)
        self.displayModes = initial.displayModes
        self.layers = initial.layers
        self.currentLayerID = initial.currentLayerID
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
        displayModes = documentSession.document.displayModes
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
            document.layers[index].isVisible = isVisible
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
            document.layers[index].isLocked = isLocked
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
            document.layers[index].color = document.layers[index].nextColor
        }
        guard changed else { return false }
        syncLayers()
        return true
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

    /// Rebuilds every published value that is derived from the document. The
    /// document session remains the only owner; this is the projection the
    /// shell renders.
    private func syncDocumentState() {
        let document = documentSession.document
        scene = Self.scene(from: document)
        displayModes = document.displayModes
        layers = document.layers
        currentLayerID = document.currentLayerID
        measurements = document.measurements.map(\.measurement)
    }

    // MARK: - Document commands

    /// Replaces the current document with a new, empty one. This is a document
    /// command, not an undoable edit: undo must not resurrect a file the user
    /// discarded before the new document existed.
    func newDocument() {
        let document = FFDocument(name: "Untitled")
        documentSession = FFDocumentSession(document: document)
        syncDocumentState()
        selection = FFSelectionState()
        documentURL = nil
        preservation = nil
        recoveryMessage = nil
        documentStatus = "New document"
    }

    /// Loads the shipping bench sample as a fresh, unsaved document and selects
    /// its stone, the state the smoke suite then orbits and edits.
    func loadFixture() {
        let sample = FFDocument.benchSample
        documentSession = FFDocumentSession(document: sample.document)
        syncDocumentState()
        selection = FFSelectionState(selectedIDs: sample.selectedNodeIDs)
        documentURL = nil
        preservation = nil
        recoveryMessage = nil
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
        let destination = url ?? documentURL ?? Self.defaultDocumentURL
        try store.save(
            documentSession.document,
            to: destination,
            preservation: preservation,
            thumbnail: FFPThumbnail.png(for: documentSession.document)
        )
        documentURL = destination
        documentStatus = "Saved \(destination.lastPathComponent)"
    }

    func reopen() throws {
        guard let documentURL else { return }
        try reopen(from: documentURL)
    }

    /// Loads a document from disk and replaces the scene, modes and selection.
    /// The undo history is reset: undo must never reach across a reopened file.
    func reopen(from url: URL) throws {
        let loaded = try store.loadContent(from: url)
        documentSession = FFDocumentSession(document: loaded.document)
        syncDocumentState()
        documentURL = url
        preservation = loaded.preservation
        recoveryMessage = loaded.recovery?.message
        selection = FFSelectionState.initial(for: scene)
        documentStatus = loaded.recovery == nil
            ? "Reopened \(url.lastPathComponent)"
            : "Recovered last good save · \(url.lastPathComponent)"
    }

    static var defaultDocumentURL: URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent("Untitled.ffp")
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
