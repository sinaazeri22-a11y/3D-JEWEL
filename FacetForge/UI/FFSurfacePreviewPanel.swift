import Foundation
import SwiftUI

/// The live preview's card: the mode, the parameters a commit will bake, what
/// the last rebuild produced and, when it refused, why.
///
/// Every control here edits session preview state, which is free and undoable
/// nothing. Only `Create solid` is a document edit; it is one undo step owned by
/// the session. Revolve keeps the Phase 54 shape because Phase 57's row is an
/// extrusion, and a revolve commits nothing until its own phase.
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

    @State private var draftText = ""

    private var extrusion: FFExtrusionParameters? { preview?.extrusion }

    private var status: String {
        guard let preview else {
            return message ?? "Select one curve, then choose a mode"
        }
        return preview.valueLabel(unit: unit)
    }

    private var subtitle: String {
        preview?.mode == .revolve ? "Preview only" : "Extrude a solid"
    }

    /// Nil until a preview exists, so the card never advertises a parameter it
    /// has no body to change.
    private var showsExtrusionControls: Bool {
        preview?.mode != .revolve
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

            if let message {
                Text(message)
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.warning.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("shell.surface.message")
                    .accessibilityLabel(message)
            }

            Text(
                preview?.isClosedProfile == true
                    ? "Closed profile · drag the handle"
                    : "Open profile · extrudes as a ribbon"
            )
            .font(FFType.caption)
            .foregroundStyle(FFPalette.textTertiary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("shell.surface.profile")
            .accessibilityLabel(
                preview?.isClosedProfile == true ? "Closed profile" : "Open profile"
            )
        }
        .frame(width: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.surface.card")
        // An undrafted body leaves the field empty and shows its placeholder,
        // so the first digit a jeweller types is the whole angle rather than a
        // second decimal on a zero.
        .onAppear { draftText = Self.text(for: extrusion?.draftDegrees ?? 0) }
        .onChange(of: extrusion?.draftDegrees) { _, value in
            // The session clamps a draft, so the field follows the effective
            // value rather than keeping a number the body is not using.
            guard Self.parsed(draftText) != value else { return }
            draftText = Self.text(for: value ?? 0)
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

    private static func text(for degrees: Double) -> String {
        abs(degrees) <= 1e-9 ? "" : String(format: "%.1f", degrees)
    }

    private static func parsed(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
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
