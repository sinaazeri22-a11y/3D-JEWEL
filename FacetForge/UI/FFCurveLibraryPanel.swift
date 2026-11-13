import SwiftUI

/// The curve library card: name the selected curve, tag it, save it, and insert
/// a saved curve back into the document.
///
/// The card owns its two text fields only. Every save and insert is a session
/// command, so the library file and the document have one writer, and a drag
/// out of this card carries an entry's id rather than its geometry: the drop
/// handle inserts through the same command the Insert chip uses.
struct FFCurveLibraryPanel: View {
    let entries: [FFCurveLibraryEntry]
    let message: String?
    let onSave: (String, String) -> Void
    let onInsert: (UUID) -> Void

    @State private var name = ""
    @State private var tags = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        FFPanel(
            title: "Curve library",
            subtitle: "Saved in this app's container",
            trailing: "\(entries.count)"
        ) {
            HStack(spacing: FFSpace.xxs) {
                TextField("Curve name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(FFType.caption)
                    .accessibilityIdentifier("shell.curves.name")
                    .accessibilityLabel("Curve name")

                FFChip(
                    title: "Save",
                    systemImage: "square.and.arrow.down",
                    accessibilityIdentifier: "shell.curves.save"
                ) {
                    onSave(trimmedName, tags)
                    name = ""
                    tags = ""
                }
            }

            TextField("Tags, comma separated", text: $tags)
                .textFieldStyle(.roundedBorder)
                .font(FFType.caption)
                .accessibilityIdentifier("shell.curves.tags")
                .accessibilityLabel("Tags")

            if let message {
                Text(message)
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.warning.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("shell.curves.message")
                    .accessibilityLabel(message)
            }

            if entries.isEmpty {
                Text("No saved curves yet")
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textTertiary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("shell.curves.empty")
                    .accessibilityLabel("No saved curves yet")
            } else {
                ForEach(Array(entries.prefix(8).enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: FFSpace.xs) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(FFType.caption)
                                .foregroundStyle(FFPalette.textPrimary.color)
                            Text(summary(for: entry))
                                .font(FFType.monoSmall)
                                .foregroundStyle(FFPalette.textTertiary.color)
                        }
                        Spacer(minLength: FFSpace.xxs)
                        FFChip(
                            title: "Insert",
                            systemImage: "plus",
                            accessibilityIdentifier: "shell.curves.insert.\(index)"
                        ) {
                            onInsert(entry.id)
                        }
                    }
                    .contentShape(Rectangle())
                    .draggable(entry.id.uuidString)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("shell.curves.entry.\(index)")
                }
            }

            Text("Drag a row into the viewport to place it")
                .font(FFType.monoSmall)
                .foregroundStyle(FFPalette.textTertiary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
        }
        .frame(width: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.curves.card")
    }

    private func summary(for entry: FFCurveLibraryEntry) -> String {
        let spans = "\(entry.payload.segments.count) span\(entry.payload.segments.count == 1 ? "" : "s")"
        let tagLine = entry.tags.isEmpty ? "untagged" : entry.tags.joined(separator: " · ")
        return "\(spans) · \(tagLine)"
    }
}
