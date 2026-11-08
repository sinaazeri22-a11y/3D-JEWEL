import SwiftUI

/// Phase 34's duplication and array surface. It offers the three creation
/// commands and, when the selection is an array group, the parameters that
/// remain editable after creation. Every intent routes to the editor session;
/// the panel holds no document state and formats only what `FFArrayInfo`
/// already computed.
struct FFArrayPanel: View {
    let canDuplicate: Bool
    let canArray: Bool
    let info: FFArrayInfo?
    let lengthUnit: FFLengthUnit
    let onDuplicate: () -> Void
    let onLinear: () -> Void
    let onRadial: () -> Void
    let onAdjustCount: (UUID, Int) -> Void
    let onAdjustOffset: (UUID, Double) -> Void
    let onSetDirection: (UUID, FFAxis) -> Void
    let onSetAxis: (UUID, FFAxis) -> Void
    let onAdjustAngle: (UUID, Double) -> Void

    var body: some View {
        FFPanel(
            title: "Duplicate & array",
            subtitle: info.map { "\($0.name) · \($0.parameters.kind.label)" }
                ?? "One object at a time",
            trailing: info?.isLocked == true ? "locked" : nil
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: FFSpace.xxs) { creationChips }
                VStack(alignment: .leading, spacing: FFSpace.xxs) { creationChips }
            }

            if let info {
                parameterControls(info)
            } else {
                Text("Select one object to duplicate or array.")
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textTertiary.color)
                    .accessibilityIdentifier("array.empty")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("array.panel")
    }

    /// Duplicate and the two array kinds share the row. Count and offset are
    /// clamped by the session, so a chip at a limit simply commits nothing;
    /// keeping the chips enabled there avoids a control that changes shape
    /// under the finger.
    @ViewBuilder
    private var creationChips: some View {
        FFChip(
            title: "Duplicate",
            systemImage: "plus.square.on.square",
            accessibilityIdentifier: "array.duplicate"
        ) {
            onDuplicate()
        }
        .disabled(!canDuplicate)

        FFChip(
            title: "Linear",
            systemImage: "arrow.right.to.line",
            accessibilityIdentifier: "array.linear"
        ) {
            onLinear()
        }
        .disabled(!canArray)

        FFChip(
            title: "Radial",
            systemImage: "circle.dashed",
            accessibilityIdentifier: "array.radial"
        ) {
            onRadial()
        }
        .disabled(!canArray)
    }

    @ViewBuilder
    private func parameterControls(_ info: FFArrayInfo) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.xs) {
            Text(summary(info))
                .font(FFType.monoSmall)
                .foregroundStyle(FFPalette.textAccent.color)
                .accessibilityIdentifier("array.summary")

            stepperRow(
                title: "Count",
                value: "\(info.parameters.count)",
                valueIdentifier: "array.count.value",
                decreaseIdentifier: "array.count.decrease",
                increaseIdentifier: "array.count.increase",
                isEnabled: !info.isLocked,
                onDecrease: { onAdjustCount(info.nodeID, -1) },
                onIncrease: { onAdjustCount(info.nodeID, 1) }
            )

            switch info.parameters.kind {
            case .linear:
                stepperRow(
                    title: "Offset",
                    value: FFPrecision.lengthString(
                        millimetres: info.parameters.offset,
                        unit: lengthUnit
                    ),
                    valueIdentifier: "array.offset.value",
                    decreaseIdentifier: "array.offset.decrease",
                    increaseIdentifier: "array.offset.increase",
                    isEnabled: !info.isLocked,
                    onDecrease: {
                        onAdjustOffset(info.nodeID, -FFArrayParameters.offsetStep)
                    },
                    onIncrease: {
                        onAdjustOffset(info.nodeID, FFArrayParameters.offsetStep)
                    }
                )

                axisChips(
                    title: "Direction",
                    prefix: "array.direction",
                    selected: info.parameters.direction,
                    isEnabled: !info.isLocked
                ) { axis in
                    onSetDirection(info.nodeID, axis)
                }

            case .radial:
                stepperRow(
                    title: "Total angle",
                    value: FFPrecision.angleString(degrees: info.parameters.totalAngle),
                    valueIdentifier: "array.angle.value",
                    decreaseIdentifier: "array.angle.decrease",
                    increaseIdentifier: "array.angle.increase",
                    isEnabled: !info.isLocked,
                    onDecrease: {
                        onAdjustAngle(info.nodeID, -FFArrayParameters.angleStep)
                    },
                    onIncrease: {
                        onAdjustAngle(info.nodeID, FFArrayParameters.angleStep)
                    }
                )

                axisChips(
                    title: "Axis",
                    prefix: "array.axis",
                    selected: info.parameters.axis,
                    isEnabled: !info.isLocked
                ) { axis in
                    onSetAxis(info.nodeID, axis)
                }
            }

            Text(
                info.isLocked
                    ? "This array's layer is locked."
                    : "Editing rebuilds the copies; each change is one undo step."
            )
            .font(FFType.monoSmall)
            .foregroundStyle(FFPalette.textTertiary.color)
            .accessibilityIdentifier(info.isLocked ? "array.locked" : "array.note")
        }
    }

    // MARK: - Rows

    private func stepperRow(
        title: String,
        value: String,
        valueIdentifier: String,
        decreaseIdentifier: String,
        increaseIdentifier: String,
        isEnabled: Bool,
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
                    isEnabled: isEnabled,
                    onDecrease: onDecrease,
                    onIncrease: onIncrease
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                stepperLabel(title, value: value, valueIdentifier: valueIdentifier)
                stepperChips(
                    decreaseIdentifier: decreaseIdentifier,
                    increaseIdentifier: increaseIdentifier,
                    isEnabled: isEnabled,
                    onDecrease: onDecrease,
                    onIncrease: onIncrease
                )
            }
        }
    }

    private func stepperLabel(_ title: String, value: String, valueIdentifier: String) -> some View {
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
        isEnabled: Bool,
        onDecrease: @escaping () -> Void,
        onIncrease: @escaping () -> Void
    ) -> some View {
        FFChip(
            title: "−",
            accessibilityIdentifier: decreaseIdentifier
        ) {
            onDecrease()
        }
        .disabled(!isEnabled)

        FFChip(
            title: "+",
            accessibilityIdentifier: increaseIdentifier
        ) {
            onIncrease()
        }
        .disabled(!isEnabled)
    }

    private func axisChips(
        title: String,
        prefix: String,
        selected: FFAxis,
        isEnabled: Bool,
        onSelect: @escaping (FFAxis) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textSecondary.color)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: FFSpace.xxs) {
                    axisChipButtons(prefix: prefix, selected: selected, isEnabled: isEnabled, onSelect: onSelect)
                }
                VStack(alignment: .leading, spacing: FFSpace.xxs) {
                    axisChipButtons(prefix: prefix, selected: selected, isEnabled: isEnabled, onSelect: onSelect)
                }
            }
        }
    }

    @ViewBuilder
    private func axisChipButtons(
        prefix: String,
        selected: FFAxis,
        isEnabled: Bool,
        onSelect: @escaping (FFAxis) -> Void
    ) -> some View {
        ForEach(FFAxis.allCases) { axis in
            FFChip(
                title: axis.label,
                isSelected: axis == selected,
                accessibilityIdentifier: "\(prefix).\(axis.rawValue)"
            ) {
                onSelect(axis)
            }
            .disabled(!isEnabled)
        }
    }

    // MARK: - Formatting

    /// One line names the kind, member count and the value that defines the
    /// spacing, so the panel never shows a number the array does not use (the
    /// offset is absent from a radial array and the sweep from a linear one).
    private func summary(_ info: FFArrayInfo) -> String {
        let parameters = info.parameters
        switch parameters.kind {
        case .linear:
            let spacing = FFPrecision.lengthString(
                millimetres: parameters.offset,
                unit: lengthUnit
            )
            return "\(parameters.count) items · \(spacing) apart along \(parameters.direction.label)"
        case .radial:
            let sweep = FFPrecision.angleString(degrees: parameters.totalAngle)
            let step = FFPrecision.angleString(degrees: parameters.angularStepDegrees)
            return "\(parameters.count) items · \(step) apart · \(sweep) about \(parameters.axis.label)"
        }
    }
}
