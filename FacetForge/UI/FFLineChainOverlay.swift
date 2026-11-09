import SwiftUI

/// The sketch layer of the viewport: committed line chains and the chain being
/// drawn. Curves are not triangles, so they are drawn as a screen-space canvas
/// over the render surface instead of entering the mesh renderer; every point
/// is projected through the live camera, so the drawing sits on the geometry it
/// was snapped to. Nothing here is hittable.
struct FFLineChainOverlay: View {
    /// Committed curve nodes, already projected into world space by the
    /// session. The overlay only transforms them to pixels.
    let curves: [FFCurveRender]
    let draft: FFLineChainDraft
    let camera: FFCamera
    let viewport: CGSize
    let unit: FFLengthUnit

    private var viewportVector: Vec2 {
        Vec2(x: Double(viewport.width), y: Double(viewport.height))
    }

    var body: some View {
        Canvas { context, _ in
            for curve in curves {
                draw(curve, in: &context)
            }
            drawDraft(in: &context)
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .allowsHitTesting(false)
        // Decorative only. Publishing this full-viewport canvas as an
        // accessibility element made the Metal view beneath it report
        // `isHittable == false`, which the Phase 27 and 28 UI tests check after
        // a modal closes. Curves are named by the object tree instead.
        .accessibilityHidden(true)
    }

    private func screenPoints(_ points: [Vec3]) -> [Vec2] {
        points.compactMap { camera.screenPoint(for: $0, viewport: viewportVector) }
    }

    private func draw(_ curve: FFCurveRender, in context: inout GraphicsContext) {
        let screens = screenPoints(curve.worldPoints)
        guard screens.count >= 2 else { return }
        var path = Path()
        path.addLines(screens.map { CGPoint(x: $0.x, y: $0.y) })
        if curve.isClosed {
            path.closeSubpath()
        }
        context.stroke(
            path,
            with: .color(FFPalette.textAccent.color),
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
        )
    }

    /// The draft is drawn solid where it is committed and dashed to the
    /// pending point, so the segment a typed length will change is visible. A
    /// ring appears on the first vertex when the pending point would close the
    /// chain.
    private func drawDraft(in context: inout GraphicsContext) {
        guard draft.isActive else { return }
        var committed: [Vec2] = draft.points
        if let pending = draft.pending, !draft.isClosed {
            committed.append(pending)
        }
        let screens = screenPoints(committed.map { Vec3(x: $0.x, y: $0.y, z: 0) })
        guard !screens.isEmpty else { return }

        if screens.count >= 2 {
            let settled = draft.isClosed ? screens.count : screens.count - 1
            var path = Path()
            path.addLines(Array(screens.prefix(settled)).map { CGPoint(x: $0.x, y: $0.y) })
            if draft.isClosed {
                path.closeSubpath()
            }
            context.stroke(
                path,
                with: .color(FFPalette.accent.color),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
            if !draft.isClosed, let pending = screens.last {
                var preview = Path()
                preview.move(to: CGPoint(x: screens[settled - 1].x, y: screens[settled - 1].y))
                preview.addLine(to: CGPoint(x: pending.x, y: pending.y))
                context.stroke(
                    preview,
                    with: .color(FFPalette.accent.color),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
            }
        }

        for screen in screens {
            context.stroke(
                Path(ellipseIn: CGRect(x: screen.x - 4, y: screen.y - 4, width: 8, height: 8)),
                with: .color(FFPalette.accent.color),
                lineWidth: 1.5
            )
        }

        if draft.wouldClose, let first = screens.first {
            context.stroke(
                Path(ellipseIn: CGRect(x: first.x - 8, y: first.y - 8, width: 16, height: 16)),
                with: .color(FFPalette.accent.color),
                lineWidth: 2
            )
        }

        if let pending = screens.last, let measure = draft.pendingMeasure {
            let label = Text("\(measure.lengthString(unit: unit)) · \(measure.angleString)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(FFPalette.textPrimary.color)
            context.draw(
                label,
                at: CGPoint(x: pending.x, y: pending.y - 18),
                anchor: .center
            )
        }
    }
}

/// The line tool's card: the live length/angle, the typed length entry, and the
/// three ways a chain ends. It edits drafts only; every commit goes through the
/// session, so the document, undo and the journal keep one owner.
struct FFLineChainPanel: View {
    let draft: FFLineChainDraft
    let readout: FFLineSegmentMeasure?
    let unit: FFLengthUnit
    let message: String?
    let onTypeLength: (String) -> Void
    let onClose: () -> Void
    let onFinish: () -> Void
    let onCancel: () -> Void

    @State private var lengthText = ""

    private var status: String {
        if draft.isClosed {
            return "Closed · \(draft.segmentCount) segments · press Finish"
        }
        if let readout {
            return "\(readout.lengthString(unit: unit)) · \(readout.angleString)"
        }
        if draft.isActive {
            return "Tap the next point, or type a length"
        }
        return "Tap the sketch plane to start"
    }

    var body: some View {
        FFPanel(title: "Line chain", subtitle: "World XY plane", trailing: unit.label) {
            Text(status)
                .font(FFType.mono)
                .foregroundStyle(FFPalette.textPrimary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("shell.line.readout")
                .accessibilityLabel(status)

            HStack(spacing: FFSpace.xxs) {
                TextField("Length", text: $lengthText)
                    .font(FFType.mono)
                    .foregroundStyle(FFPalette.textPrimary.color)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
                    .onSubmit { submit() }
                    .padding(.horizontal, FFSpace.xs)
                    .padding(.vertical, 10)
                    .frame(minHeight: FFHitTarget.minimum)
                    .background(
                        FFPalette.canvas.color,
                        in: RoundedRectangle(cornerRadius: FFRadius.xs, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: FFRadius.xs, style: .continuous)
                            .stroke(FFPalette.separator.color, lineWidth: 1)
                    }
                    .accessibilityIdentifier("shell.line.length")
                    .accessibilityLabel("Segment length")
                    .accessibilityHint("Types the exact length of the next segment")
                FFChip(
                    title: "Set",
                    accessibilityIdentifier: "shell.line.setLength"
                ) {
                    submit()
                }
            }

            if let message {
                Text(message)
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.warning.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("shell.line.message")
                    .accessibilityLabel(message)
            }

            HStack(spacing: FFSpace.xxs) {
                FFChip(
                    title: "Cancel",
                    accessibilityIdentifier: "shell.line.cancel"
                ) {
                    lengthText = ""
                    onCancel()
                }
                FFChip(
                    title: "Close",
                    accessibilityIdentifier: "shell.line.close"
                ) {
                    onClose()
                }
                .disabled(!draft.canClose)
                FFChip(
                    title: "Finish",
                    accessibilityIdentifier: "shell.line.finish"
                ) {
                    lengthText = ""
                    onFinish()
                }
                .disabled(!(draft.isActive && (draft.points.count >= 2 || draft.isClosed)))
            }
        }
        .frame(width: 340)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.line.card")
    }

    private func submit() {
        onTypeLength(lengthText)
        lengthText = ""
    }
}
