import SwiftUI

/// Phase 32's object tree. The panel renders `session.rootNodes` and routes
/// every intent back through the editor session; it owns only the transient
/// search text and the rename sheet's draft. A row drag nests into a group,
/// and Up/Down reorder the selected node among its siblings.
struct FFObjectTreePanel: View {
    /// One coordinate space for the row frames and the drag locations.
    static let dragSpace = "object-tree"

    let nodes: [FFNode]
    let selection: FFSelectionState
    let isLocked: (UUID) -> Bool
    let onSelect: (UUID) -> Void
    let onRename: (UUID, String) -> Bool
    let onAddGroup: () -> Void
    let onNest: (UUID, UUID) -> Bool
    let onMove: (UUID, Int) -> Void

    @State private var query = ""
    @State private var renamingRow: FFObjectTreeRow?
    @FocusState private var isSearchFocused: Bool
    /// The row being dragged and the group it is currently over. The drag is a
    /// panel gesture rather than the system drag-and-drop session: a scroll view
    /// and system drag arbitration can drop the lift, and the tree's rows live
    /// in the inspector's scroll view.
    @State private var draggingRowID: UUID?
    @State private var dropTargetID: UUID?
    @State private var rowFrames: [UUID: CGRect] = [:]

    private var rows: [FFObjectTreeRow] {
        FFObjectTree.rows(in: nodes, query: query, isLocked: isLocked)
    }

    private var selectedRow: FFObjectTreeRow? {
        guard selection.selectedIDs.count == 1, let id = selection.selectedIDs.first else {
            return nil
        }
        return FFObjectTree.rows(in: nodes, query: "", isLocked: isLocked)
            .first { $0.id == id }
    }

    var body: some View {
        FFPanel(
            title: "Objects",
            subtitle: "\(FFObjectTree.rows(in: nodes, query: "").count) objects · document order",
            trailing: selection.selectedIDs.isEmpty ? nil : "\(selection.selectedIDs.count) selected"
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: FFSpace.xxs) {
                    commandChips
                }

                VStack(alignment: .leading, spacing: FFSpace.xxs) {
                    commandChips
                }
            }

            searchField

            if rows.isEmpty {
                Text("No objects match \"\(query)\"")
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textTertiary.color)
                    .accessibilityIdentifier("tree.empty")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        treeRow(row)
                    }
                }

            }

            Text("Drag a row onto a group to nest it. Up and Down reorder the selected row.")
                .font(FFType.monoSmall)
                .foregroundStyle(FFPalette.textTertiary.color)
        }
        .coordinateSpace(name: FFObjectTreePanel.dragSpace)
        .onPreferenceChange(FFTreeRowFrameKey.self) { rowFrames = $0 }
        .sheet(item: $renamingRow) { row in
            FFRenameNodeSheet(
                initialName: row.name,
                onCancel: { renamingRow = nil },
                onSave: { name in
                    guard onRename(row.id, name) else {
                        return "That name could not be applied. It may be blank or the layer may be locked."
                    }
                    renamingRow = nil
                    return nil
                }
            )
        }
    }

    @ViewBuilder
    private var commandChips: some View {
        FFChip(
            title: "Group",
            systemImage: "folder.badge.plus",
            accessibilityIdentifier: "tree.addGroup"
        ) {
            onAddGroup()
        }

        FFChip(
            title: "Rename",
            systemImage: "pencil",
            accessibilityIdentifier: "tree.rename"
        ) {
            renamingRow = selectedRow
        }
        .disabled(selectedRow == nil || selectedRow?.isLocked == true)

        FFChip(
            title: "Up",
            systemImage: "arrow.up",
            accessibilityIdentifier: "tree.moveUp"
        ) {
            if let selectedRow { onMove(selectedRow.id, -1) }
        }
        .disabled(selectedRow == nil)

        FFChip(
            title: "Down",
            systemImage: "arrow.down",
            accessibilityIdentifier: "tree.moveDown"
        ) {
            if let selectedRow { onMove(selectedRow.id, 1) }
        }
        .disabled(selectedRow == nil)
    }

    private var searchField: some View {
        HStack(spacing: FFSpace.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(FFPalette.textTertiary.color)
                .accessibilityHidden(true)

            TextField("Search by name or type", text: $query)
                .font(FFType.body)
                .foregroundStyle(FFPalette.textPrimary.color)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.vertical, 13)
                .frame(minHeight: FFHitTarget.minimum)
                .contentShape(Rectangle())
                .focused($isSearchFocused)
                .accessibilityIdentifier("tree.search")
                .accessibilityLabel("Search objects")

            if !query.isEmpty {
                Button {
                    query = ""
                    isSearchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(FFPalette.textTertiary.color)
                        .frame(width: FFHitTarget.minimum, height: FFHitTarget.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FFPressStyle())
                .accessibilityIdentifier("tree.search.clear")
                .accessibilityLabel("Clear object search")
            }
        }
        .padding(.leading, FFSpace.sm)
        .padding(.trailing, query.isEmpty ? FFSpace.sm : 0)
        .frame(minHeight: FFHitTarget.minimum + 4)
        .background(
            FFPalette.field.color,
            in: RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
                .stroke(FFPalette.separator.color, lineWidth: 1)
        }
    }

    private func treeRow(_ row: FFObjectTreeRow) -> some View {
        let isSelected = selection.selectedIDs.contains(row.id)
        let value = rowValue(row, isSelected: isSelected)

        // A Button's press gesture wins over a drag gesture, so the row is a
        // plain tappable view: a tap selects it, while a long press followed by
        // a move runs the panel's own drag session. The system drag-and-drop
        // session was removed because the inspector's scroll view and the tap
        // gesture could drop the lift, leaving the nest command unreachable.
        return HStack(spacing: FFSpace.xs) {
            Image(systemName: row.kind.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    isSelected ? FFPalette.textAccent.color : FFPalette.textSecondary.color
                )
                .frame(width: 20)
                .accessibilityHidden(true)

            Text(row.name)
                .font(FFType.caption)
                .foregroundStyle(
                    row.isLocked ? FFPalette.textTertiary.color : FFPalette.textPrimary.color
                )
                .lineLimit(1)

            Spacer(minLength: FFSpace.xxs)

            if row.isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FFPalette.textTertiary.color)
                    .accessibilityHidden(true)
            }

            if row.childCount > 0 {
                Text("\(row.childCount)")
                    .font(FFType.monoSmall)
                    .foregroundStyle(FFPalette.textTertiary.color)
            }

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FFPalette.textAccent.color)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, FFSpace.xxs + CGFloat(row.depth) * 14)
        .padding(.trailing, FFSpace.xxs)
        .frame(maxWidth: .infinity, minHeight: FFHitTarget.minimum, alignment: .leading)
        .background(
            isSelected ? FFPalette.raised.color : Color.clear,
            in: RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
        )
        .contentShape(Rectangle())
        .opacity(draggingRowID == row.id ? 0.55 : 1)
        .onTapGesture { onSelect(row.id) }
        .overlay {
            if dropTargetID == row.id {
                RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
                    .stroke(FFPalette.accent.color, lineWidth: 2)
                    .accessibilityHidden(true)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: FFTreeRowFrameKey.self,
                    value: [row.id: proxy.frame(in: .named(FFObjectTreePanel.dragSpace))]
                )
            }
        )
        .highPriorityGesture(dragGesture(for: row))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.name)
        .accessibilityValue(value)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("tree.row.\(row.name)")
    }

    /// A long press lifts the row, movement over another row aims the drop, and
    /// the release either nests into a group or does nothing.
    private func dragGesture(for row: FFObjectTreeRow) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(
                before: DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .named(FFObjectTreePanel.dragSpace)
                )
            )
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                draggingRowID = row.id
                let target = dropTarget(at: drag.location, excluding: row.id)
                if target != dropTargetID { dropTargetID = target }
            }
            .onEnded { value in
                defer {
                    draggingRowID = nil
                    dropTargetID = nil
                }
                guard case .second(true, let drag?) = value,
                      let target = dropTarget(at: drag.location, excluding: row.id)
                else { return }
                _ = onNest(row.id, target)
            }
    }

    /// The deepest group row whose frame contains the point. A stone or a
    /// solid is never a destination, so a drop can only add a child to a group.
    /// The highlight is the drag's only visual, which keeps one source of truth
    /// for what a release will do.
    private func dropTarget(at point: CGPoint, excluding source: UUID) -> UUID? {
        rows
            .filter { $0.isGroup && $0.id != source }
            .filter { rowFrames[$0.id]?.contains(point) == true }
            .max { $0.depth < $1.depth }?
            .id
    }

    private func rowValue(_ row: FFObjectTreeRow, isSelected: Bool) -> String {
        // The level is announced because the row is a flattened tree line: an
        // indent is a visual cue only, and VoiceOver needs the structure.
        var parts = [row.kind.label, "level \(row.depth + 1)"]
        if row.childCount > 0 {
            parts.append(row.childCount == 1 ? "1 child" : "\(row.childCount) children")
        }
        if row.isLocked { parts.append("locked") }
        if isSelected { parts.append("selected") }
        return parts.joined(separator: " · ")
    }
}

/// Collects each row's frame in the panel's coordinate space so a drag can be
/// resolved to the row under the finger without any row owning a drop target.
private struct FFTreeRowFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// The tree's rename sheet. It follows the document browser's rule: the current
/// name is shown above, and the field starts empty so a submitted name is the
/// whole replacement rather than an edit in the middle of the old one.
private struct FFRenameNodeSheet: View {
    let initialName: String
    let onCancel: () -> Void
    /// Returns a message to keep the sheet open, or nil on success.
    let onSave: (String) -> String?

    @State private var name = ""
    @State private var errorText: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.md) {
            Text("Rename object")
                .font(FFType.section)
                .foregroundStyle(FFPalette.textPrimary.color)
                .accessibilityIdentifier("tree.rename.title")

            Text("Current name: \(initialName)")
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textTertiary.color)

            TextField("New name", text: $name)
                .font(FFType.body)
                .foregroundStyle(FFPalette.textPrimary.color)
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit(save)
                .padding(.horizontal, FFSpace.sm)
                .padding(.vertical, 13)
                .frame(minHeight: FFHitTarget.minimum)
                .background(
                    FFPalette.field.color,
                    in: RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous)
                        .stroke(FFPalette.separator.color, lineWidth: 1)
                }
                .accessibilityIdentifier("tree.rename.field")
                .accessibilityLabel("Object name")

            if let errorText {
                Text(errorText)
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textWarning.color)
                    .accessibilityIdentifier("tree.rename.error")
            }

            HStack(spacing: FFSpace.xs) {
                Spacer(minLength: 0)

                FFButton(title: "Cancel", kind: .ghost, action: onCancel)
                    .accessibilityIdentifier("tree.rename.cancel")

                FFButton(
                    title: "Rename",
                    kind: .primary,
                    isEnabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: save
                )
                .accessibilityIdentifier("tree.rename.save")
            }
        }
        .padding(FFSpace.lg)
        .frame(maxWidth: 480)
        .background(FFPalette.raised.color)
        .presentationDragIndicator(.visible)
        .onAppear { isFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tree.rename.sheet")
    }

    private func save() {
        if let message = onSave(name) {
            errorText = message
        }
    }
}
