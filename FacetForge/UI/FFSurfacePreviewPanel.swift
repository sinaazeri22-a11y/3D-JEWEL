import SwiftUI

/// The live preview's card: the mode, the parameter, what the last rebuild
/// produced and, when it refused, why. It edits session preview state only;
/// there is no commit command here because Phase 54's row is a preview, not a
/// solid.
struct FFSurfacePreviewPanel: View {
    let preview: FFSurfacePreview?
    let message: String?
    let unit: FFLengthUnit
    let onMode: (FFSweepMode) -> Void

    private var status: String {
        guard let preview else {
            return message ?? "Select one curve, then choose a mode"
        }
        return preview.valueLabel(unit: unit)
    }

    var body: some View {
        FFPanel(title: "Profile to surface", subtitle: "Preview only", trailing: unit.label) {
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
                    : "Open profile · drag the handle"
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
