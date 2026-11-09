import SwiftUI
import UIKit

/// Phase 35's material inspector. It is a sheet rather than another in-flow
/// inspector panel: the fixed header button is always reachable, and the sheet
/// scrolls independently of the tree, transform and array dock. The panel owns
/// only which material row is selected and the colour picker's draft; every
/// edit routes to the editor session.
struct FFMaterialInspectorSheet: View {
    let info: FFMaterialInfo
    let onSetPreset: (UUID, FFAlloyPreset) -> Void
    let onAdjustMetallic: (UUID, Double) -> Void
    let onAdjustRoughness: (UUID, Double) -> Void
    let onSetColor: (UUID, FFRGBA) -> Void
    let onAssignToNode: (UUID, UUID) -> Void
    let onAssignToGroup: (UUID, UUID, UUID) -> Void
    let onRemoveGroup: (UUID, UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMaterialID: UUID?

    private static let metallicStep = 0.05
    private static let roughnessStep = 0.05

    init(
        info: FFMaterialInfo,
        onSetPreset: @escaping (UUID, FFAlloyPreset) -> Void,
        onAdjustMetallic: @escaping (UUID, Double) -> Void,
        onAdjustRoughness: @escaping (UUID, Double) -> Void,
        onSetColor: @escaping (UUID, FFRGBA) -> Void,
        onAssignToNode: @escaping (UUID, UUID) -> Void,
        onAssignToGroup: @escaping (UUID, UUID, UUID) -> Void,
        onRemoveGroup: @escaping (UUID, UUID) -> Void
    ) {
        self.info = info
        self.onSetPreset = onSetPreset
        self.onAdjustMetallic = onAdjustMetallic
        self.onAdjustRoughness = onAdjustRoughness
        self.onSetColor = onSetColor
        self.onAssignToNode = onAssignToNode
        self.onAssignToGroup = onAssignToGroup
        self.onRemoveGroup = onRemoveGroup
        _selectedMaterialID = State(
            initialValue: info.selectedNodeMaterialID ?? info.materials.first?.id
        )
    }

    private var selectedMaterial: FFMaterialInfo.MaterialRow? {
        if let selectedMaterialID,
           let match = info.materials.first(where: { $0.id == selectedMaterialID }) {
            return match
        }
        return info.materials.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(FFPalette.separator.color)

            ScrollView {
                VStack(alignment: .leading, spacing: FFSpace.sm) {
                    materialsPanel
                    if let material = selectedMaterial {
                        surfacePanel(material)
                    }
                    faceGroupsPanel
                }
                .padding(FFSpace.sm)
            }
        }
        .background(FFPalette.panel.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("material.sheet")
        .presentationDetents([.large])
    }

    private var header: some View {
        HStack(spacing: FFSpace.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Materials")
                    .font(FFType.section)
                    .foregroundStyle(FFPalette.textPrimary.color)
                Text("Alloy presets, surface values and face groups")
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
            .accessibilityIdentifier("material.done")
        }
        .padding(.horizontal, FFSpace.sm)
        .padding(.vertical, FFSpace.xs)
    }

    private var materialsPanel: some View {
        FFPanel(
            title: "Document materials",
            subtitle: "\(info.materials.count) total"
        ) {
            if info.materials.isEmpty {
                Text("This document has no materials yet.")
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textTertiary.color)
                    .accessibilityIdentifier("material.empty")
            } else {
                ForEach(Array(info.materials.enumerated()), id: \.element.id) { index, material in
                    materialRow(material, index: index)
                }
            }
        }
    }

    private func materialRow(
        _ material: FFMaterialInfo.MaterialRow,
        index: Int
    ) -> some View {
        let isSelected = selectedMaterial?.id == material.id
        return Button {
            selectedMaterialID = material.id
        } label: {
            HStack(spacing: FFSpace.xs) {
                swatch(material.baseColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(material.name)
                        .font(FFType.caption)
                        .foregroundStyle(FFPalette.textPrimary.color)
                        .lineLimit(1)
                    Text("\(material.nodeCount) \(material.nodeCount == 1 ? "object" : "objects") · \(material.faceCount) faces")
                        .font(FFType.monoSmall)
                        .foregroundStyle(FFPalette.textTertiary.color)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FFPalette.accent.color)
                }
            }
            .frame(maxWidth: .infinity, minHeight: FFHitTarget.minimum, alignment: .leading)
            .padding(.horizontal, FFSpace.xxs)
            .background(
                isSelected ? FFPalette.raised.color : Color.clear,
                in: RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(FFPressStyle())
        .accessibilityIdentifier("material.row.\(index)")
        .accessibilityLabel(material.name)
        .accessibilityValue(isSelected ? "selected" : "")
    }

    private func surfacePanel(_ material: FFMaterialInfo.MaterialRow) -> some View {
        FFPanel(
            title: material.name,
            subtitle: material.preset?.label ?? "Custom surface"
        ) {
            Text("\(material.nodeCount) \(material.nodeCount == 1 ? "object" : "objects") · \(material.faceCount) faces")
                .font(FFType.monoSmall)
                .foregroundStyle(FFPalette.textAccent.color)
                .accessibilityIdentifier("material.usage")

            Text("Alloy preset")
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textSecondary.color)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132), spacing: FFSpace.xxs)],
                alignment: .leading,
                spacing: FFSpace.xxs
            ) {
                ForEach(FFAlloyPreset.allCases) { preset in
                    FFChip(
                        title: preset.label,
                        isSelected: material.preset == preset,
                        accessibilityIdentifier: "material.preset.\(preset.rawValue)"
                    ) {
                        onSetPreset(material.id, preset)
                    }
                }
            }

            stepperRow(
                title: "Metallic",
                value: FFPrecision.fixed(material.metallic, decimals: 2),
                valueIdentifier: "material.metallic.value",
                decreaseIdentifier: "material.metallic.decrease",
                increaseIdentifier: "material.metallic.increase",
                canDecrease: material.metallic > 0,
                canIncrease: material.metallic < 1,
                onDecrease: { onAdjustMetallic(material.id, -Self.metallicStep) },
                onIncrease: { onAdjustMetallic(material.id, Self.metallicStep) }
            )

            stepperRow(
                title: "Roughness",
                value: FFPrecision.fixed(material.roughness, decimals: 2),
                valueIdentifier: "material.roughness.value",
                decreaseIdentifier: "material.roughness.decrease",
                increaseIdentifier: "material.roughness.increase",
                canDecrease: material.roughness > 0,
                canIncrease: material.roughness < 1,
                onDecrease: { onAdjustRoughness(material.id, -Self.roughnessStep) },
                onIncrease: { onAdjustRoughness(material.id, Self.roughnessStep) }
            )

            ColorPicker(
                selection: colorBinding(material),
                supportsOpacity: false
            ) {
                HStack(spacing: FFSpace.xs) {
                    swatch(material.baseColor)
                    Text("Colour")
                        .font(FFType.caption)
                        .foregroundStyle(FFPalette.textSecondary.color)
                }
            }
            .frame(minHeight: FFHitTarget.minimum)
            .accessibilityIdentifier("material.color")

            Text("Presets are shading approximations, not alloy certifications.")
                .font(FFType.monoSmall)
                .foregroundStyle(FFPalette.textTertiary.color)
                .accessibilityIdentifier("material.note")
        }
    }

    private var faceGroupsPanel: some View {
        FFPanel(
            title: "Face groups",
            subtitle: info.selectedNodeName ?? "No mesh selected"
        ) {
            if let nodeID = info.selectedNodeID {
                faceGroupsContent(nodeID: nodeID)
            } else {
                Text("Select one mesh object to see its face groups.")
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textTertiary.color)
                    .accessibilityIdentifier("material.groups.empty")
            }
        }
    }

    @ViewBuilder
    private func faceGroupsContent(nodeID: UUID) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.xs) {
            Text("\(info.selectedNodeName ?? "Object") · \(info.selectedNodeTriangleCount) faces")
                .font(FFType.monoSmall)
                .foregroundStyle(FFPalette.textAccent.color)
                .accessibilityIdentifier("material.node")

            if info.faceGroups.isEmpty {
                Text("No face groups on this object.")
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textTertiary.color)
                    .accessibilityIdentifier("material.groups.empty")
            } else {
                ForEach(Array(info.faceGroups.enumerated()), id: \.element.id) { index, group in
                    faceGroupRow(group, index: index, nodeID: nodeID)
                }
            }

            Text("\(info.unassignedTriangleCount) unassigned faces use the object's base material.")
                .font(FFType.monoSmall)
                .foregroundStyle(FFPalette.textTertiary.color)
                .accessibilityIdentifier("material.unassigned")

            Button {
                guard let materialID = selectedMaterial?.id else { return }
                onAssignToNode(nodeID, materialID)
            } label: {
                Text(
                    selectedMaterial.map { "Assign \($0.name) to unassigned faces" }
                        ?? "Assign unassigned faces"
                )
                .font(FFType.caption)
                .foregroundStyle(
                    canAssignUnassigned
                        ? FFPalette.textPrimary.color
                        : FFPalette.textTertiary.color
                )
                .frame(maxWidth: .infinity, minHeight: FFHitTarget.minimum)
                .background(
                    FFPalette.raised.color,
                    in: RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(FFPressStyle())
            .disabled(!canAssignUnassigned)
            .accessibilityIdentifier("material.assign.unassigned")

            Text("Tap a group to give it the selected material.")
                .font(FFType.monoSmall)
                .foregroundStyle(FFPalette.textTertiary.color)
                .accessibilityIdentifier("material.groups.note")
        }
    }

    private var canAssignUnassigned: Bool {
        info.canEditSelection
            && info.unassignedTriangleCount > 0
            && selectedMaterial != nil
    }

    private func faceGroupRow(
        _ group: FFMaterialInfo.FaceGroupRow,
        index: Int,
        nodeID: UUID
    ) -> some View {
        HStack(spacing: FFSpace.xxs) {
            Button {
                guard let materialID = selectedMaterial?.id else { return }
                onAssignToGroup(nodeID, group.id, materialID)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(FFType.caption)
                        .foregroundStyle(FFPalette.textPrimary.color)
                        .lineLimit(1)
                    Text("\(group.triangleCount) faces · \(group.materialName)")
                        .font(FFType.monoSmall)
                        .foregroundStyle(FFPalette.textTertiary.color)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: FFHitTarget.minimum, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(FFPressStyle())
            .disabled(!info.canEditSelection)
            .accessibilityIdentifier("material.group.\(index)")
            .accessibilityLabel(group.name)
            .accessibilityValue("\(group.triangleCount) faces, \(group.materialName)")

            Button {
                onRemoveGroup(nodeID, group.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FFPalette.textTertiary.color)
                    .frame(width: FFHitTarget.minimum, height: FFHitTarget.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FFPressStyle())
            .disabled(!info.canEditSelection)
            .accessibilityLabel("Remove \(group.name)")
            .accessibilityIdentifier("material.group.remove.\(index)")
        }
    }

    private func stepperRow(
        title: String,
        value: String,
        valueIdentifier: String,
        decreaseIdentifier: String,
        increaseIdentifier: String,
        canDecrease: Bool,
        canIncrease: Bool,
        onDecrease: @escaping () -> Void,
        onIncrease: @escaping () -> Void
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: FFSpace.xxs) {
                stepperLabel(title, value: value, valueIdentifier: valueIdentifier)
                Spacer(minLength: 0)
                stepperChips(
                    decreaseIdentifier: decreaseIdentifier,
                    increaseIdentifier: increaseIdentifier,
                    canDecrease: canDecrease,
                    canIncrease: canIncrease,
                    onDecrease: onDecrease,
                    onIncrease: onIncrease
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                stepperLabel(title, value: value, valueIdentifier: valueIdentifier)
                stepperChips(
                    decreaseIdentifier: decreaseIdentifier,
                    increaseIdentifier: increaseIdentifier,
                    canDecrease: canDecrease,
                    canIncrease: canIncrease,
                    onDecrease: onDecrease,
                    onIncrease: onIncrease
                )
            }
        }
    }

    private func stepperLabel(
        _ title: String,
        value: String,
        valueIdentifier: String
    ) -> some View {
        HStack(spacing: FFSpace.xxs) {
            Text(title)
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textSecondary.color)

            Text(value)
                .font(FFType.monoSmall)
                .foregroundStyle(FFPalette.textPrimary.color)
                .lineLimit(1)
                .accessibilityIdentifier(valueIdentifier)
        }
    }

    @ViewBuilder
    private func stepperChips(
        decreaseIdentifier: String,
        increaseIdentifier: String,
        canDecrease: Bool,
        canIncrease: Bool,
        onDecrease: @escaping () -> Void,
        onIncrease: @escaping () -> Void
    ) -> some View {
        FFChip(title: "−", accessibilityIdentifier: decreaseIdentifier) {
            onDecrease()
        }
        .disabled(!canDecrease)

        FFChip(title: "+", accessibilityIdentifier: increaseIdentifier) {
            onIncrease()
        }
        .disabled(!canIncrease)
    }

    private func swatch(_ color: FFRGBA) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(
                Color(
                    .sRGB,
                    red: FFMath.clamp(color.red, to: 0...1),
                    green: FFMath.clamp(color.green, to: 0...1),
                    blue: FFMath.clamp(color.blue, to: 0...1),
                    opacity: 1
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(FFPalette.separator.color, lineWidth: 1)
            )
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
    }

    private func colorBinding(_ material: FFMaterialInfo.MaterialRow) -> Binding<Color> {
        Binding(
            get: {
                Color(
                    .sRGB,
                    red: FFMath.clamp(material.baseColor.red, to: 0...1),
                    green: FFMath.clamp(material.baseColor.green, to: 0...1),
                    blue: FFMath.clamp(material.baseColor.blue, to: 0...1),
                    opacity: 1
                )
            },
            set: { newValue in
                let color = UIColor(newValue)
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                guard color.getRed(
                    &red,
                    green: &green,
                    blue: &blue,
                    alpha: &alpha
                ) else { return }
                onSetColor(
                    material.id,
                    FFRGBA(
                        red: Double(red),
                        green: Double(green),
                        blue: Double(blue),
                        alpha: 1
                    )
                )
            }
        )
    }
}

/// The inspector header's always-visible entry point. The sheet lives on this
/// button so it cannot be pushed below the inspector's scroll content, which is
/// the reachability failure Phase 34 spent a dozen gates learning.
struct FFMaterialInspectorLauncher: View {
    let info: FFMaterialInfo
    let onSetPreset: (UUID, FFAlloyPreset) -> Void
    let onAdjustMetallic: (UUID, Double) -> Void
    let onAdjustRoughness: (UUID, Double) -> Void
    let onSetColor: (UUID, FFRGBA) -> Void
    let onAssignToNode: (UUID, UUID) -> Void
    let onAssignToGroup: (UUID, UUID, UUID) -> Void
    let onRemoveGroup: (UUID, UUID) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(FFPalette.textTertiary.color)
                .frame(width: FFHitTarget.minimum, height: FFHitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(FFPressStyle())
        .accessibilityLabel("Materials")
        .accessibilityIdentifier("inspector.materials")
        .sheet(isPresented: $isPresented) {
            FFMaterialInspectorSheet(
                info: info,
                onSetPreset: onSetPreset,
                onAdjustMetallic: onAdjustMetallic,
                onAdjustRoughness: onAdjustRoughness,
                onSetColor: onSetColor,
                onAssignToNode: onAssignToNode,
                onAssignToGroup: onAssignToGroup,
                onRemoveGroup: onRemoveGroup
            )
        }
    }
}
