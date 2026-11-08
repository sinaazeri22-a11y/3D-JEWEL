import SwiftUI

/// Phase 33's transform surface. It renders one node's inherited world position
/// beside its local one, edits the pivot through the five presets, and commits a
/// local rotation from degree fields. Every command routes to the editor session;
/// the panel owns only the field drafts and the parse error it shows.
struct FFTransformPanel: View {
    let info: FFTransformInfo?
    let lengthUnit: FFLengthUnit
    let onSetPivot: (UUID, FFPivotPreset) -> Void
    let onSetRotation: (UUID, Double, Double, Double) -> Bool

    @State private var rotationX = ""
    @State private var rotationY = ""
    @State private var rotationZ = ""
    @State private var rotationError: String?

    var body: some View {
        FFPanel(
            title: "Transform",
            subtitle: info.map { "\($0.name) · \($0.kind.label)" } ?? "No single selection"
        ) {
            if let info {
                inheritance(info)
                pivotControls(info)
                rotationControls(info)
            } else {
                Text("Select one object to inspect its transform.")
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textTertiary.color)
                    .accessibilityIdentifier("transform.empty")
            }
        }
        .onAppear { syncFields() }
        .onChange(of: info?.nodeID) { _, _ in syncFields() }
        .onChange(of: info?.rotationDegrees) { _, _ in syncFields() }
        .onChange(of: info?.pivot) { _, _ in syncFields() }
    }

    // MARK: - Inheritance

    @ViewBuilder
    private func inheritance(_ info: FFTransformInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(info.parentName.map { "Inherits \($0)" } ?? "World root · no parent")
                .font(FFType.caption)
                .foregroundStyle(
                    info.parentName == nil
                        ? FFPalette.textTertiary.color
                        : FFPalette.textAccent.color
                )
                .accessibilityIdentifier("transform.inherits")

            Text("Local \(pointString(info.localTranslation))")
                .font(FFType.monoSmall)
                .foregroundStyle(FFPalette.textSecondary.color)
                .accessibilityIdentifier("transform.local")

            Text("World \(pointString(info.worldTranslation))")
                .font(FFType.monoSmall)
                .foregroundStyle(FFPalette.textSecondary.color)
                .accessibilityIdentifier("transform.world")
        }
    }

    // MARK: - Pivot

    @ViewBuilder
    private func pivotControls(_ info: FFTransformInfo) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.xxs) {
            Text("Pivot \(pointString(info.pivot))")
                .font(FFType.monoSmall)
                .foregroundStyle(FFPalette.textAccent.color)
                .accessibilityIdentifier("transform.pivot")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: FFSpace.xxs) { presetChips(info) }
                VStack(alignment: .leading, spacing: FFSpace.xxs) { presetChips(info) }
            }
        }
    }

    @ViewBuilder
    private func presetChips(_ info: FFTransformInfo) -> some View {
        ForEach(FFPivotPreset.allCases) { preset in
            FFChip(
                title: preset.label,
                systemImage: preset.systemImage,
                accessibilityIdentifier: "transform.pivot.\(preset.rawValue)"
            ) {
                onSetPivot(info.nodeID, preset)
            }
            .disabled(info.isLocked)
        }
    }

    // MARK: - Rotation

    @ViewBuilder
    private func rotationControls(_ info: FFTransformInfo) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.xxs) {
            Text("Rotation · degrees")
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textSecondary.color)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: FFSpace.xxs) { rotationFields(info) }
                VStack(alignment: .leading, spacing: FFSpace.xxs) { rotationFields(info) }
            }

            FFChip(
                title: "Apply",
                systemImage: "arrow.triangle.2.circlepath",
                accessibilityIdentifier: "transform.rotation.apply"
            ) {
                applyRotation(info)
            }
            .disabled(info.isLocked)

            if let rotationError {
                Text(rotationError)
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textWarning.color)
                    .accessibilityIdentifier("transform.rotation.error")
            }
        }
    }

    @ViewBuilder
    private func rotationFields(_ info: FFTransformInfo) -> some View {
        rotationField("X", text: $rotationX, identifier: "transform.rotation.x", info: info)
        rotationField("Y", text: $rotationY, identifier: "transform.rotation.y", info: info)
        rotationField("Z", text: $rotationZ, identifier: "transform.rotation.z", info: info)
    }

    private func rotationField(
        _ label: String,
        text: Binding<String>,
        identifier: String,
        info: FFTransformInfo
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textTertiary.color)

            TextField("0", text: text)
                .font(FFType.mono)
                .foregroundStyle(FFPalette.textPrimary.color)
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .submitLabel(.done)
                .onSubmit { applyRotation(info) }
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
                .accessibilityLabel("Rotation \(label) in degrees")
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Commands and formatting

    private func applyRotation(_ info: FFTransformInfo) {
        guard let x = parse(rotationX), let y = parse(rotationY), let z = parse(rotationZ) else {
            rotationError = "Enter a number of degrees for X, Y and Z."
            return
        }
        guard onSetRotation(info.nodeID, x, y, z) else {
            rotationError = info.isLocked
                ? "This object's layer is locked."
                : "The rotation did not change."
            return
        }
        rotationError = nil
    }

    private func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        return Double(trimmed)
    }

    private func syncFields() {
        guard let info else {
            rotationX = ""
            rotationY = ""
            rotationZ = ""
            rotationError = nil
            return
        }
        let decimals = FFPrecision.angleDecimals
        rotationX = FFPrecision.fixed(info.rotationDegrees.x, decimals: decimals)
        rotationY = FFPrecision.fixed(info.rotationDegrees.y, decimals: decimals)
        rotationZ = FFPrecision.fixed(info.rotationDegrees.z, decimals: decimals)
        rotationError = nil
    }

    /// One unit label for the whole point, so three coordinates do not repeat
    /// "mm" three times. The values go through the Phase 30 length policy.
    private func pointString(_ point: FFPoint3) -> String {
        func coordinate(_ millimetres: Double) -> String {
            FFPrecision.lengthNumber(millimetres: millimetres, unit: lengthUnit)
        }
        return "X \(coordinate(point.x)) · Y \(coordinate(point.y)) · Z \(coordinate(point.z)) "
            + lengthUnit.label
    }
}
