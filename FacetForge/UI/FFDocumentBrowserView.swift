import SwiftUI

/// Phase 28's in-app document browser.
///
/// This view never scans, renames, copies or deletes files. It renders
/// `session.library`, routes the pressed action to a session command, and keeps
/// only presentation state (query, selection, sheet). The rename sheet is a
/// system sheet above the browser, so its controls take every touch while it is
/// open; the browser's own action row is behind it and cannot be hit.
struct FFDocumentBrowserView: View {
    @ObservedObject var session: FFEditorSession
    let onClose: () -> Void

    @State private var query = ""
    @State private var selectedID: URL?
    @State private var renamingDocument: FFDocumentSummary?
    @State private var pendingDelete: FFDocumentSummary?
    @State private var message: String?

    private var filtered: [FFDocumentSummary] {
        session.library.filter { FFDocumentLibrary.matches($0, query: query) }
    }

    private var selected: FFDocumentSummary? {
        guard let selectedID else { return nil }
        return session.library.first { $0.id == selectedID }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 260), spacing: FFSpace.sm),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(FFPalette.separator.color)
            searchField
            content
            Divider().overlay(FFPalette.separator.color)
            footer
        }
        .background(FFPalette.canvas.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.browser")
        .onAppear { session.refreshLibrary() }
        .sheet(item: $renamingDocument) { document in
            FFRenameDocumentSheet(
                initialName: document.displayName,
                onCancel: { renamingDocument = nil },
                onSave: { name in
                    do {
                        let renamed = try session.renameDocument(at: document.url, to: name)
                        selectedID = renamed
                        message = "Renamed to \(renamed.lastPathComponent)"
                        renamingDocument = nil
                        return nil
                    } catch {
                        return (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                    }
                }
            )
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.displayName ?? "document")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { document in
            Button("Delete document", role: .destructive) {
                delete(document)
            }
            Button("Cancel", role: .cancel) {}
        } message: { document in
            Text("\(document.fileName).ffp and its recovery snapshots will be removed. This cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: FFSpace.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Documents")
                    .font(FFType.title)
                    .foregroundStyle(FFPalette.textPrimary.color)
                    .accessibilityIdentifier("shell.browser.title")
                Text("\(session.library.count) document\(session.library.count == 1 ? "" : "s") · newest first")
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textTertiary.color)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(FFPalette.textSecondary.color)
                    .frame(width: FFHitTarget.minimum, height: FFHitTarget.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FFPressStyle())
            .accessibilityIdentifier("shell.browser.close")
            .accessibilityLabel("Close documents")
        }
        .padding(.horizontal, FFSpace.md)
        .padding(.vertical, FFSpace.sm)
        .background(FFPalette.panel.color)
    }

    private var searchField: some View {
        HStack(spacing: FFSpace.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(FFPalette.textTertiary.color)
                .accessibilityHidden(true)

            TextField("Search by name", text: $query)
                .font(FFType.body)
                .foregroundStyle(FFPalette.textPrimary.color)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("shell.browser.search")
                .accessibilityLabel("Search documents")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(FFPalette.textTertiary.color)
                        .frame(width: FFHitTarget.minimum, height: FFHitTarget.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FFPressStyle())
                .accessibilityIdentifier("shell.browser.search.clear")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, FFSpace.sm)
        .padding(.trailing, query.isEmpty ? FFSpace.sm : 0)
        .frame(minHeight: FFHitTarget.minimum + 4)
        .background(
            FFPalette.field.color,
            in: RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous)
                .stroke(FFPalette.separator.color, lineWidth: 1)
        }
        .padding(.horizontal, FFSpace.md)
        .padding(.vertical, FFSpace.sm)
    }

    // MARK: - Grid

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            VStack(spacing: FFSpace.sm) {
                Image(systemName: query.isEmpty ? "folder" : "magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(FFPalette.textTertiary.color)
                    .accessibilityHidden(true)
                Text(query.isEmpty ? "No documents yet" : "No documents match “\(query)”")
                    .font(FFType.section)
                    .foregroundStyle(FFPalette.textSecondary.color)
                    .multilineTextAlignment(.center)
                Text(query.isEmpty
                     ? "Save a document from the workspace and it will appear here."
                     : "Clear the search to see every saved document.")
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textTertiary.color)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(FFSpace.lg)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("shell.browser.empty")
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: FFSpace.sm) {
                    ForEach(filtered) { document in
                        cell(document)
                    }
                }
                .padding(FFSpace.md)
            }
            .accessibilityIdentifier("shell.browser.grid")
        }
    }

    private func cell(_ document: FFDocumentSummary) -> some View {
        let isSelected = document.id == selectedID
        return Button {
            selectedID = document.id
            message = nil
        } label: {
            VStack(alignment: .leading, spacing: FFSpace.xs) {
                thumbnail(document)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .background(FFPalette.field.color)
                    .clipShape(RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous))

                Text(document.displayName)
                    .font(FFType.label)
                    .foregroundStyle(FFPalette.textPrimary.color)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: FFSpace.xxs) {
                    Text(document.fileName + ".ffp")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(document.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(FFType.monoSmall)
                .foregroundStyle(FFPalette.textTertiary.color)
            }
            .padding(FFSpace.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                FFPalette.raised.color,
                in: RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous)
                    .stroke(
                        isSelected ? FFPalette.accent.color : FFPalette.separator.color,
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous))
        }
        .buttonStyle(FFPressStyle())
        .accessibilityIdentifier("shell.browser.cell")
        .accessibilityLabel("\(document.displayName), \(document.fileName).ffp")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func thumbnail(_ document: FFDocumentSummary) -> some View {
        if let data = document.thumbnail, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding(FFSpace.xxs)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "diamond")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(FFPalette.textTertiary.color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Actions

    private var footer: some View {
        VStack(alignment: .leading, spacing: FFSpace.xs) {
            if let message {
                Text(message)
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textSecondary.color)
                    .lineLimit(1)
                    .accessibilityIdentifier("shell.browser.message")
            }

            HStack(spacing: FFSpace.xs) {
                actionButton(
                    "Open",
                    systemImage: "arrow.up.forward.square",
                    identifier: "shell.browser.open",
                    isEnabled: selected != nil
                ) {
                    openSelected()
                }
                actionButton(
                    "Rename",
                    systemImage: "pencil",
                    identifier: "shell.browser.rename",
                    isEnabled: selected != nil
                ) {
                    renamingDocument = selected
                }
                actionButton(
                    "Duplicate",
                    systemImage: "plus.square.on.square",
                    identifier: "shell.browser.duplicate",
                    isEnabled: selected != nil
                ) {
                    duplicateSelected()
                }
                Spacer(minLength: 0)
                Button {
                    pendingDelete = selected
                } label: {
                    Text("Delete")
                        .font(FFType.label)
                        .foregroundStyle(
                            selected == nil
                                ? FFPalette.textTertiary.color
                                : FFPalette.textWarning.color
                        )
                        .frame(minWidth: FFHitTarget.minimum, minHeight: FFHitTarget.minimum)
                        .padding(.horizontal, FFSpace.sm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FFPressStyle())
                .disabled(selected == nil)
                .accessibilityIdentifier("shell.browser.delete")
                .accessibilityLabel("Delete")
            }
        }
        .padding(.horizontal, FFSpace.md)
        .padding(.vertical, FFSpace.sm)
        .background(FFPalette.panel.color)
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        identifier: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        FFButton(
            title: title,
            systemImage: systemImage,
            kind: .secondary,
            isEnabled: isEnabled,
            action: action
        )
        .accessibilityIdentifier(identifier)
    }

    private func openSelected() {
        guard let document = selected else { return }
        do {
            try session.reopen(from: document.url)
            onClose()
        } catch {
            message = "Could not open: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func duplicateSelected() {
        guard let document = selected else { return }
        do {
            let copy = try session.duplicateDocument(at: document.url)
            selectedID = copy
            message = "Duplicated to \(copy.lastPathComponent)"
        } catch {
            message = "Could not duplicate: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func delete(_ document: FFDocumentSummary) {
        do {
            try session.deleteDocument(at: document.url)
            if selectedID == document.id { selectedID = nil }
            message = "Deleted \(document.fileName).ffp"
        } catch {
            message = "Could not delete: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
        pendingDelete = nil
    }
}

/// The rename sheet. It is a real system sheet above the browser, which is the
/// deliberate draw and hit order: search, cells and the action row underneath
/// cannot receive a touch while this is present.
private struct FFRenameDocumentSheet: View {
    let initialName: String
    let onCancel: () -> Void
    /// Returns a message to show and keep the sheet open, or nil on success.
    let onSave: (String) -> String?

    @State private var name: String
    @State private var errorText: String?
    @FocusState private var isFocused: Bool

    init(
        initialName: String,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> String?
    ) {
        self.initialName = initialName
        self.onCancel = onCancel
        self.onSave = onSave
        // The field starts empty because the name it replaces is shown above:
        // typing is the whole new name, never an edit in the middle of one.
        _name = State(initialValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.md) {
            Text("Rename document")
                .font(FFType.section)
                .foregroundStyle(FFPalette.textPrimary.color)
                .accessibilityIdentifier("shell.browser.rename.title")

            Text("Current file: \(initialName).ffp")
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textTertiary.color)

            TextField("New name", text: $name)
                .font(FFType.body)
                .foregroundStyle(FFPalette.textPrimary.color)
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit(save)
                .padding(.horizontal, FFSpace.sm)
                .frame(minHeight: FFHitTarget.minimum + 4)
                .background(
                    FFPalette.field.color,
                    in: RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: FFRadius.md, style: .continuous)
                        .stroke(FFPalette.separator.color, lineWidth: 1)
                }
                .accessibilityIdentifier("shell.browser.rename.field")
                .accessibilityLabel("Document name")

            if let errorText {
                Text(errorText)
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textWarning.color)
                    .accessibilityIdentifier("shell.browser.rename.error")
            }

            HStack(spacing: FFSpace.xs) {
                Spacer(minLength: 0)

                FFButton(title: "Cancel", kind: .ghost, action: onCancel)
                    .accessibilityIdentifier("shell.browser.rename.cancel")

                FFButton(
                    title: "Save",
                    kind: .primary,
                    isEnabled: FFDocumentLibrary.sanitizedName(name) != nil,
                    action: save
                )
                .accessibilityIdentifier("shell.browser.rename.save")
            }
        }
        .padding(FFSpace.lg)
        .frame(maxWidth: 480)
        .background(FFPalette.raised.color)
        .presentationDragIndicator(.visible)
        .onAppear { isFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.browser.rename.sheet")
    }

    private func save() {
        errorText = onSave(name)
    }
}
