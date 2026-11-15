import Foundation
import SwiftUI

/// The live preview's card: the mode, the parameters a commit will bake, what
/// the last rebuild produced and, when it refused, why.
///
/// Every control here edits session preview state, which is free and undoable
/// nothing. Only `Create solid` is a document edit; it is one undo step owned by
/// the session, and each mode has its own commit so the button a jeweller taps
/// names the body it will make.
struct FFSurfacePreviewPanel: View {
    let preview: FFSurfacePreview?
    let message: String?
    let unit: FFLengthUnit
    let onMode: (FFSweepMode) -> Void
    let onDraft: (Double) -> Void
    let onDirection: (FFExtrudeDirection) -> Void
    let onSymmetric: (Bool) -> Void
    let onCaps: (FFExtrudeCaps) -> Void
    let onCommit: () -> Void
    let onRevolveAngle: (Double) -> Void
    let onRevolveDirection: (FFRevolveDirection) -> Void
    let onRevolveCaps: (FFRevolveCaps) -> Void
    let onRevolveCommit: () -> Void

    @State private var draftText = ""
    @State private var angleText = ""
    /// The cards sit on the viewport, which ignores the keyboard's safe area, so
    /// each field dismisses itself on submit: the chips and the commit below it
    /// must never end up under the keyboard.
    @FocusState private var isDraftFocused: Bool
    @FocusState private var isAngleFocused: Bool

    private var extrusion: FFExtrusionParameters? { preview?.extrusion }
    private var revolve: FFRevolveParameters? { preview?.revolve }

    private var status: String {
        guard let preview else {
            return message ?? "Select one curve, then choose a mode"
        }
        return preview.valueLabel(unit: unit)
    }

    private var subtitle: String {
        switch preview?.mode {
        case .revolve: "Revolve a solid"
        case .extrude: "Extrude a solid"
        case nil: "Profile to surface"
        }
    }

    /// Nil until a preview exists, so the card never advertises a parameter it
    /// has no body to change.
    private var showsExtrusionControls: Bool {
        preview?.mode != .revolve
    }

    private var showsRevolveControls: Bool {
        preview?.mode == .revolve
    }

    private var profileCaption: String {
        let closed = preview?.isClosedProfile == true
        if showsRevolveControls {
            return closed ? "Closed profile · sweeps to a solid" : "Open profile · sweeps to a surface"
        }
        return closed ? "Closed profile · drag the handle" : "Open profile · extrudes as a ribbon"
    }

    private var profileAccessibilityLabel: String {
        preview?.isClosedProfile == true ? "Closed profile" : "Open profile"
    }

    var body: some View {
        FFPanel(title: "Profile to surface", subtitle: subtitle, trailing: unit.label) {
            Text(status)
                .font(FFType.mono)
                .foregroundStyle(FFPalette.textPrimary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("shell.surface.readout")
                .accessibilityLabel(status)

            HStack(spacing: FFSpace.xxs) {
                ForEach(FFSweepMode.allCases) { mode in
                    FFChip(
                        title: mode.label,
                        isSelected: preview?.mode == mode,
                        accessibilityIdentifier: "shell.surface.mode.\(mode.rawValue)"
                    ) {
                        onMode(mode)
                    }
                }
            }

            if showsExtrusionControls {
                draftField

                if extrusion?.isSymmetric != true {
                    HStack(spacing: FFSpace.xxs) {
                        ForEach(FFExtrudeDirection.allCases) { direction in
                            FFChip(
                                title: direction.label,
                                isSelected: extrusion?.direction == direction,
                                accessibilityIdentifier: "shell.extrude.direction.\(direction.rawValue)"
                            ) {
                                onDirection(direction)
                            }
                        }
                        FFChip(
                            title: "Symmetric",
                            isSelected: extrusion?.isSymmetric == true,
                            accessibilityIdentifier: "shell.extrude.symmetric"
                        ) {
                            onSymmetric(true)
                        }
                    }
                } else {
                    HStack(spacing: FFSpace.xxs) {
                        FFChip(
                            title: "Symmetric",
                            isSelected: true,
                            accessibilityIdentifier: "shell.extrude.symmetric"
                        ) {
                            onSymmetric(false)
                        }
                        if let extrusion, extrusion.isDrafted {
                            Text("both ends drafted")
                                .font(FFType.caption)
                                .foregroundStyle(FFPalette.textTertiary.color)
                        }
                    }
                }

                if preview?.isClosedProfile == true {
                    HStack(spacing: FFSpace.xxs) {
                        ForEach(FFExtrudeCaps.allCases) { caps in
                            FFChip(
                                title: caps.label,
                                isSelected: extrusion?.caps == caps,
                                accessibilityIdentifier: "shell.extrude.caps.\(caps.rawValue)"
                            ) {
                                onCaps(caps)
                            }
                        }
                    }
                }

                FFButton(
                    title: "Create solid",
                    systemImage: "cube",
                    kind: .primary,
                    isEnabled: preview != nil
                ) {
                    onCommit()
                }
                .accessibilityIdentifier("shell.extrude.commit")
            }

            if showsRevolveControls {
                angleField

                HStack(spacing: FFSpace.xxs) {
                    ForEach(FFRevolveDirection.allCases) { direction in
                        FFChip(
                            title: direction.label,
                            isSelected: revolve?.direction == direction,
                            accessibilityIdentifier: "shell.revolve.direction.\(direction.rawValue)"
                        ) {
                            onRevolveDirection(direction)
                        }
                    }
                }

                if preview?.isClosedProfile == true, revolve?.isFullTurn != true {
                    HStack(spacing: FFSpace.xxs) {
                        ForEach(FFRevolveCaps.allCases) { caps in
                            FFChip(
                                title: caps.label,
                                isSelected: revolve?.caps == caps,
                                accessibilityIdentifier: "shell.revolve.caps.\(caps.rawValue)"
                            ) {
                                onRevolveCaps(caps)
                            }
                        }
                    }
                } else if revolve?.isFullTurn == true {
                    Text("Full turn · no ends to cap")
                        .font(FFType.caption)
                        .foregroundStyle(FFPalette.textTertiary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("shell.revolve.fullTurn")
                        .accessibilityLabel("Full turn, no ends to cap")
                }

                FFButton(
                    title: "Create solid",
                    systemImage: "circle.dashed",
                    kind: .primary,
                    isEnabled: preview != nil
                ) {
                    onRevolveCommit()
                }
                .accessibilityIdentifier("shell.revolve.commit")
            }

            if let message {
                Text(message)
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.warning.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("shell.surface.message")
                    .accessibilityLabel(message)
            }

            Text(profileCaption)
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textTertiary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("shell.surface.profile")
                .accessibilityLabel(profileAccessibilityLabel)
        }
        .frame(width: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.surface.card")
        // An undrafted body leaves the field empty and shows its placeholder,
        // so the first digit a jeweller types is the whole angle rather than a
        // second decimal on a zero.
        .onAppear {
            draftText = Self.text(for: extrusion?.draftDegrees ?? 0)
            angleText = Self.text(
                forAngle: revolve?.angleDegrees ?? FFRevolveParameters.defaultAngleDegrees
            )
        }
        .onChange(of: extrusion?.draftDegrees) { _, value in
            // The session clamps a draft, so the field follows the effective
            // value rather than keeping a number the body is not using.
            guard Self.parsed(draftText) != value else { return }
            draftText = Self.text(for: value ?? 0)
        }
        .onChange(of: preview?.angleDegrees) { _, value in
            // A drag changes the angle under the field. The field follows it,
            // but never while it is being typed into: the session clamps, and
            // rewriting "1" to "5.0" mid-keystroke would fight the typist.
            guard !isAngleFocused, let value else { return }
            guard Self.parsed(angleText) != value else { return }
            angleText = Self.text(forAngle: value)
        }
        .onChange(of: isAngleFocused) { _, focused in
            guard !focused else { return }
            guard let value = Self.parsed(angleText) else {
                // The field was emptied; the session kept its last angle, so
                // show the value the body is actually using.
                angleText = Self.text(
                    forAngle: preview?.angleDegrees
                        ?? FFRevolveParameters.defaultAngleDegrees
                )
                return
            }
            angleText = Self.text(forAngle: Self.clampedAngle(value))
        }
    }

    /// The draft field. Typing applies immediately, because the whole point of
    /// the card is that the ghost answers to the number the jeweller sees.
    private var draftField: some View {
        VStack(alignment: .leading, spacing: FFSpace.xxs) {
            Text("Draft")
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textSecondary.color)

            HStack(spacing: FFSpace.xs) {
                TextField("0.0", text: $draftText)
                    .font(FFType.mono)
                    .foregroundStyle(FFPalette.textPrimary.color)
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
                    .padding(.vertical, 13)
                    .frame(minHeight: FFHitTarget.minimum)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Draft angle in degrees")
                    .accessibilityIdentifier("shell.extrude.draft")
                    .focused($isDraftFocused)
                    .onSubmit { isDraftFocused = false }
                    .onChange(of: draftText) { _, text in
                        guard let value = Self.parsed(text) else { return }
                        onDraft(value)
                    }

                Text("°")
                    .font(FFType.monoSmall)
                    .foregroundStyle(FFPalette.textTertiary.color)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, FFSpace.sm)
            .frame(minHeight: FFHitTarget.minimum)
            .background(
                FFPalette.field.color,
                in: RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
                    .stroke(FFPalette.separator.color, lineWidth: 1)
            }
        }
    }

    /// The revolution's angle. It shows the effective value, applies as it is
    /// typed and normalises when the field gives up focus, so a clamped entry
    /// can never be left on screen as a number the body is not using.
    private var angleField: some View {
        VStack(alignment: .leading, spacing: FFSpace.xxs) {
            Text("Angle")
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textSecondary.color)

            HStack(spacing: FFSpace.xs) {
                TextField("90.0", text: $angleText)
                    .font(FFType.mono)
                    .foregroundStyle(FFPalette.textPrimary.color)
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
                    .padding(.vertical, 13)
                    .frame(minHeight: FFHitTarget.minimum)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Revolution angle in degrees")
                    .accessibilityIdentifier("shell.revolve.angle")
                    .focused($isAngleFocused)
                    .onSubmit {
                        // Normalise from the typed text, not from the view's
                        // captured preview: a stale capture would write a
                        // different angle and the apply handler would make it
                        // the body's angle.
                        isAngleFocused = false
                        if let value = Self.parsed(angleText) {
                            angleText = Self.text(forAngle: Self.clampedAngle(value))
                        }
                    }
                    .onChange(of: angleText) { _, text in
                        guard let value = Self.parsed(text) else { return }
                        onRevolveAngle(value)
                    }

                Text("°")
                    .font(FFType.monoSmall)
                    .foregroundStyle(FFPalette.textTertiary.color)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, FFSpace.sm)
            .frame(minHeight: FFHitTarget.minimum)
            .background(
                FFPalette.field.color,
                in: RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
                    .stroke(FFPalette.separator.color, lineWidth: 1)
            }
        }
    }

    private static func text(for degrees: Double) -> String {
        abs(degrees) <= 1e-9 ? "" : String(format: "%.1f", degrees)
    }

    private static func text(forAngle degrees: Double) -> String {
        String(format: "%.1f", degrees)
    }

    private static func parsed(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private static func clampedAngle(_ degrees: Double) -> Double {
        FFMath.clamp(
            degrees,
            to: FFRevolveParameters.minimumAngleDegrees...FFRevolveParameters.maximumAngleDegrees
        )
    }
}

/// The drag control. It sits on the preview's own centroid, so the grip and the
/// ghost move together in the viewport instead of a slider living somewhere
/// else on screen. Vertical travel changes an extrusion's height; a revolution
/// reads horizontal travel as degrees.
struct FFSurfaceDragHandle: View {
    let preview: FFSurfacePreview
    let camera: FFCamera
    let viewport: CGSize
    let unit: FFLengthUnit
    let onDragMillimetres: (Double) -> Void
    let onDragDegrees: (Double) -> Void

    @State private var lastTranslation = CGSize.zero

    private var screenPoint: Vec2? {
        camera.screenPoint(
            for: preview.handleWorld,
            viewport: Vec2(x: Double(viewport.width), y: Double(viewport.height))
        )
    }

    var body: some View {
        if let point = screenPoint {
            ZStack {
                Circle()
                    .fill(FFPalette.accent.color.opacity(0.92))
                    .frame(width: 44, height: 44)
                Image(systemName: preview.mode == .extrude ? "arrow.up.and.down" : "arrow.left.and.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(FFPalette.onAccent.color)
            }
            .frame(width: FFHitTarget.minimum, height: FFHitTarget.minimum)
            .contentShape(Circle())
            .position(x: CGFloat(point.x), y: CGFloat(point.y))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let vertical = value.translation.height - lastTranslation.height
                        let horizontal = value.translation.width - lastTranslation.width
                        lastTranslation = value.translation
                        guard viewport.width > 1, viewport.height > 1 else { return }
                        if preview.mode == .extrude {
                            // Dragging up grows the surface, which is the
                            // direction the ghost moves, so the delta is taken
                            // in world units rather than as a fixed step.
                            guard let unitsPerPoint = camera.worldUnitsPerPoint(
                                viewport: Vec2(x: Double(viewport.width), y: Double(viewport.height))
                            ) else { return }
                            onDragMillimetres(-Double(vertical) * unitsPerPoint)
                        } else {
                            onDragDegrees(Double(horizontal) * 1.2)
                        }
                    }
                    .onEnded { _ in
                        lastTranslation = .zero
                    }
            )
            .accessibilityElement()
            .accessibilityIdentifier("shell.surface.handle")
            .accessibilityLabel("Preview size")
            .accessibilityValue(preview.valueLabel(unit: unit))
            .accessibilityHint("Drag to change the sweep parameter")
        }
    }
}
