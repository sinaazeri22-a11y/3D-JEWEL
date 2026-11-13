import CoreGraphics
import Foundation
import SwiftUI

/// A named selection the jeweller can recall. A set stores node IDs, not
/// indices, so loading a document or hiding a node cannot retarget it.
struct FFSelectionSet: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var nodeIDs: [UUID]

    init(id: UUID = UUID(), name: String, nodeIDs: [UUID]) {
        self.id = id
        self.name = name
        self.nodeIDs = nodeIDs
    }
}

/// Selection and visibility for one document. The state is a value so the
/// viewport, the inspector and the tests all read the same answer, and so
/// applying it to a scene is a pure function rather than scattered flags.
struct FFSelectionState: Equatable, Sendable {
    private(set) var selectedIDs: Set<UUID>
    private(set) var hiddenIDs: Set<UUID> = []
    /// When non-nil, only these nodes are drawn. `showAll()` clears it.
    private(set) var isolatedIDs: Set<UUID>?
    var filter: FFPickFilter = .all
    /// The touch equivalent of holding Shift: the next click or marquee adds
    /// to the selection instead of replacing it.
    var isMultiSelect = false
    /// While true the viewport draws a box instead of orbiting the camera.
    var isMarquee = false
    private(set) var sets: [FFSelectionSet] = []

    init(selectedIDs: Set<UUID> = []) {
        self.selectedIDs = selectedIDs
    }

    /// The bench sample opens with its stone selected, which is the state the
    /// gumball and the inspector read on the first frame.
    static func initial(for scene: FFViewportScene) -> FFSelectionState {
        FFSelectionState(selectedIDs: Set(scene.selectedNodeIDs))
    }

    var selectedCount: Int { selectedIDs.count }

    func summary(in scene: FFViewportScene) -> String {
        if selectedIDs.isEmpty { return "No selection" }
        if selectedIDs.count == 1,
           let id = selectedIDs.first,
           let node = scene.node(id: id) {
            return node.name
        }
        return "\(selectedIDs.count) selected"
    }

    func visibilitySummary(in scene: FFViewportScene) -> String {
        // A node can already be hidden by its document or its layer before
        // this selection state is applied; the readout names every node the
        // viewport is not drawing.
        let hidden = scene.nodes.filter { !$0.isVisible || !isVisible($0) }.count
        if let isolatedIDs {
            return "\(hidden) hidden · isolated \(isolatedIDs.count)"
        }
        return "\(hidden) hidden"
    }

    func isVisible(_ node: FFRenderNode) -> Bool {
        if hiddenIDs.contains(node.id) { return false }
        if let isolatedIDs { return isolatedIDs.contains(node.id) }
        return true
    }

    func allows(_ node: FFRenderNode) -> Bool {
        filter.allows(node.kind)
    }

    /// Applies selection and visibility to a scene without mutating the base
    /// scene the document owns.
    func applying(to scene: FFViewportScene) -> FFViewportScene {
        FFViewportScene(nodes: scene.nodes.map { node in
            var copy = node
            copy.isSelected = selectedIDs.contains(node.id)
            // `node.isVisible` carries document and layer visibility. Replacing
            // it outright would resurrect a node a hidden layer had already
            // removed from the drawing.
            copy.isVisible = node.isVisible && isVisible(node)
            return copy
        }, preview: scene.preview)
    }

    /// `extend` is Shift-click, or the Multi chip on touch. A filtered-out pick
    /// arrives as `nil` and clears the selection, exactly like clicking empty
    /// space.
    mutating func click(_ id: UUID?, extend: Bool = false) {
        guard let id else {
            if !extend { selectedIDs.removeAll() }
            return
        }
        if extend {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
        } else {
            selectedIDs = [id]
        }
    }

    mutating func select(_ ids: [UUID], extend: Bool = false) {
        if extend {
            selectedIDs.formUnion(ids)
        } else {
            selectedIDs = Set(ids)
        }
    }

    mutating func clearSelection() {
        selectedIDs.removeAll()
    }

    mutating func isolateSelection() {
        guard !selectedIDs.isEmpty else { return }
        isolatedIDs = selectedIDs
    }

    /// Hiding the selection removes it from the isolated set too, so Show all
    /// is the one action that brings everything back.
    mutating func hideSelection() {
        guard !selectedIDs.isEmpty else { return }
        hiddenIDs.formUnion(selectedIDs)
        if let isolated = isolatedIDs {
            let remaining = isolated.subtracting(selectedIDs)
            isolatedIDs = remaining.isEmpty ? nil : remaining
        }
        selectedIDs.removeAll()
    }

    mutating func showAll() {
        hiddenIDs.removeAll()
        isolatedIDs = nil
    }

    mutating func saveSelectionSet() {
        guard !selectedIDs.isEmpty else { return }
        sets.append(FFSelectionSet(
            name: "Set \(sets.count + 1)",
            nodeIDs: selectedIDs.sorted { $0.uuidString < $1.uuidString }
        ))
    }

    mutating func apply(_ set: FFSelectionSet) {
        selectedIDs = Set(set.nodeIDs)
    }
}

/// Box selection is a window selection: every projected vertex of a node must
/// fall inside the rectangle. That keeps a stone standing in the ring's hole
/// from dragging the whole shank into the selection, which bounding-box
/// intersection would do on every jewellery scene.
enum FFMarqueeSelection {
    static let vertexLimit = 20_000

    static func nodeIDs(
        in rect: CGRect,
        scene: FFViewportScene,
        camera: FFCamera,
        viewport: Vec2,
        filter: FFPickFilter = .all
    ) -> [UUID] {
        let box = rect.standardized
        guard box.width >= 1, box.height >= 1,
              viewport.x > FFMath.eps, viewport.y > FFMath.eps
        else { return [] }

        var ids: [UUID] = []
        for node in scene.nodes {
            guard node.isVisible,
                  filter.allows(node.kind),
                  !node.mesh.positions.isEmpty
            else { continue }

            let step = Swift.max(1, node.mesh.positions.count / vertexLimit)
            var checked = 0
            var inside = true
            for index in Swift.stride(from: 0, to: node.mesh.positions.count, by: step) {
                let local = node.mesh.positions[index]
                let world = node.transform * Vec4(
                    x: local.x,
                    y: local.y,
                    z: local.z,
                    w: 1
                )
                guard abs(world.w) > FFMath.eps,
                      let screen = camera.screenPoint(
                          for: Vec3(
                              x: world.x / world.w,
                              y: world.y / world.w,
                              z: world.z / world.w
                          ),
                          viewport: viewport
                      )
                else {
                    inside = false
                    break
                }
                guard box.contains(CGPoint(x: screen.x, y: screen.y)) else {
                    inside = false
                    break
                }
                checked += 1
            }
            if inside, checked > 0 {
                ids.append(node.id)
            }
        }
        return ids
    }
}

/// The touch marquee. It sits above the Metal host and the gumball while box
/// mode is on, so the same one-finger drag can never orbit the camera and draw
/// a box at once.
struct FFMarqueeOverlay: View {
    let onCommit: (CGRect) -> Void

    @State private var start: CGPoint?
    @State private var current: CGPoint?

    private var rect: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())

            if let rect {
                Rectangle()
                    .fill(FFPalette.accent.color.opacity(0.14))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                Rectangle()
                    .stroke(FFPalette.accent.color, lineWidth: 1.5)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if start == nil { start = value.startLocation }
                    current = value.location
                }
                .onEnded { value in
                    let box = CGRect(
                        x: min(value.startLocation.x, value.location.x),
                        y: min(value.startLocation.y, value.location.y),
                        width: abs(value.location.x - value.startLocation.x),
                        height: abs(value.location.y - value.startLocation.y)
                    )
                    start = nil
                    current = nil
                    guard box.width >= 4, box.height >= 4 else { return }
                    onCommit(box)
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("selection.marqueeOverlay")
        .accessibilityLabel("Marquee selection")
    }
}
