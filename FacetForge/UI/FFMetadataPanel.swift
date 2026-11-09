import SwiftUI

/// Phase 36's metadata inspector. It is a sheet opened from the inspector's
/// fixed header, following Phase 35's reachability rule: the launcher never
/// moves with scroll content, the sheet's section order is fixed, and the
/// panel owns only text drafts while every edit routes to the editor session.
struct FFMetadataInspectorSheet: View {
    let metadata: FFMetadata
    let stones: FFStoneSummary
    let onSetField: (FFMetadataField, String) -> Void
    let onToggleFlag: (FFManufacturingFlag) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var partNumber: String
    @State private var sku: String
    @State private var itemDescription: String
    @State private var workshopNotes: String

    init(
        metadata: FFMetadata,
        stones: FFStoneSummary,
        onSetField: @escaping (FFMetadataField, String) -> Void,
        onToggleFlag: @escaping (FFManufacturingFlag) -> Void
    ) {
        self.metadata = metadata
        self.stones = stones
        self.onSetField = onSetField
        self.onToggleFlag = onToggleFlag
        _partNumber = State(initialValue: metadata.partNumber)
        _sku = State(initialValue: metadata.sku)
        _itemDescription = State(initialValue: metadata.itemDescription)
        _workshopNotes = State(initialValue: metadata.workshopNotes)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(FFPalette.separator.color)

            ScrollView {
                VStack(alignment: .leading, spacing: FFSpace.sm) {
                    identificationPanel
                    notesPanel
                    manufacturingPanel
                    stonesPanel
                }
                .padding(FFSpace.sm)
            }
        }
        .background(FFPalette.panel.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("metadata.sheet")
        .presentationDetents([.large])
    }

    private var header: some View {
        HStack(spacing: FFSpace.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Document info")
                    .font(FFType.section)
                    .foregroundStyle(FFPalette.textPrimary.color)
                Text("Part number, notes, manufacturing and stones")
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textTertiary.color)
            }

            Spacer(minLength: 0)

            Button("Done") {
                dismiss()
            }
            .font(FFType.label)
            .foregroundStyle(FFPalette.onAccent.color)
            .frame(minWidth: FFHitTarget.minimum, minHeight: FFHitTarget.minimum)
            .padding(.horizontal, FFSpace.sm)
            .background(FFPalette.accent.color, in: Capsule())
            .buttonStyle(FFPressStyle())
            .accessibilityIdentifier("metadata.done")
        }
        .padding(.horizontal, FFSpace.sm)
        .padding(.vertical, FFSpace.xs)
    }

    // MARK: - Identification

    private var identificationPanel: some View {
        FFPanel(
            title: "Identification",
            subtitle: "Part number and SKU"
        ) {
            field(
                .partNumber,
                text: $partNumber,
                prompt: "FF-0000",
                onChange: { partNumber = $0 }
            )
            field(
                .sku,
                text: $sku,
                prompt: "SKU",
                onChange: { sku = $0 }
            )
        }
    }

    // MARK: - Notes

    private var notesPanel: some View {
        FFPanel(
            title: "Notes",
            subtitle: "Description and workshop record"
        ) {
            field(
                .itemDescription,
                text: $itemDescription,
                prompt: "Description",
                lines: 2...4,
                onChange: { itemDescription = $0 }
            )
            field(
                .workshopNotes,
                text: $workshopNotes,
                prompt: "Workshop notes",
                lines: 3...6,
                onChange: { workshopNotes = $0 }
            )
        }
    }

    // MARK: - Manufacturing

    private var manufacturingPanel: some View {
        FFPanel(
            title: "Manufacturing",
            subtitle: metadata.manufacturingFlags.isEmpty
                ? "No flags set"
                : "\(metadata.manufacturingFlags.count) set"
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: FFSpace.xxs) { flagChips }
                VStack(alignment: .leading, spacing: FFSpace.xxs) { flagChips }
            }
        }
    }

    @ViewBuilder
    private var flagChips: some View {
        ForEach(FFManufacturingFlag.allCases) { flag in
            FFChip(
                title: flag.label,
                isSelected: metadata.isFlagEnabled(flag),
                accessibilityIdentifier: "metadata.flag.\(flag.rawValue)"
            ) {
                onToggleFlag(flag)
            }
        }
    }

    // MARK: - Stones

    private var stonesPanel: some View {
        FFPanel(
            title: "Stones",
            subtitle: "Derived from the object tree"
        ) {
            Text(stones.label)
                .font(FFType.label)
                .foregroundStyle(FFPalette.textPrimary.color)
                .accessibilityIdentifier("metadata.stoneSummary")

            if stones.stones.isEmpty {
                Text("This document has no stones.")
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textTertiary.color)
                    .accessibilityIdentifier("metadata.stones.empty")
            } else {
                ForEach(Array(stones.stones.enumerated()), id: \.element.id) { index, stone in
                    HStack(spacing: FFSpace.xs) {
                        Image(systemName: "diamond")
                            .font(.system(size: 13))
                            .foregroundStyle(FFPalette.textTertiary.color)
                            .accessibilityHidden(true)
                        Text(stone.name)
                            .font(FFType.body)
                            .foregroundStyle(FFPalette.textPrimary.color)
                        Spacer(minLength: 0)
                        Text(stone.materialName ?? "No material")
                            .font(FFType.caption)
                            .foregroundStyle(FFPalette.textSecondary.color)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(stone.name) · \(stone.materialName ?? "No material")"
                    )
                    .accessibilityIdentifier("metadata.stone.\(index)")
                }
            }
        }
    }

    // MARK: - Fields

    @ViewBuilder
    private func field(
        _ field: FFMetadataField,
        text: Binding<String>,
        prompt: String,
        lines: ClosedRange<Int>? = nil,
        onChange: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.label)
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textTertiary.color)

            TextField(prompt, text: text, axis: .vertical)
                .lineLimit(lines ?? 1...1)
                .font(FFType.body)
                .foregroundStyle(FFPalette.textPrimary.color)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .padding(.horizontal, FFSpace.xs)
                .padding(.vertical, 13)
                .frame(minHeight: FFHitTarget.minimum)
                .contentShape(Rectangle())
                .background(
                    FFPalette.field.color,
                    in: RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
                        .stroke(FFPalette.separator.color, lineWidth: 1)
                }
                .accessibilityIdentifier(field.accessibilityIdentifier)
                .onChange(of: text.wrappedValue) { _, newValue in
                    onChange(newValue)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The inspector header's always-visible entry point. Keeping the sheet on this
/// button is what makes every metadata field reachable without scrolling the
/// inspector, which is the failure Phase 34 spent a dozen gates learning.
struct FFMetadataInspectorLauncher: View {
    let metadata: FFMetadata
    let stones: FFStoneSummary
    let onSetField: (FFMetadataField, String) -> Void
    let onToggleFlag: (FFManufacturingFlag) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "doc.text")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(FFPalette.textTertiary.color)
                .frame(width: FFHitTarget.minimum, height: FFHitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(FFPressStyle())
        .accessibilityLabel("Document info")
        .accessibilityIdentifier("inspector.metadata")
        .sheet(isPresented: $isPresented) {
            FFMetadataInspectorSheet(
                metadata: metadata,
                stones: stones,
                onSetField: onSetField,
                onToggleFlag: onToggleFlag
            )
        }
    }
}
