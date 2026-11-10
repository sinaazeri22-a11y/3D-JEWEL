import SwiftUI

/// The live pencil stroke. Like the Phase 39 curve overlay it is a
/// screen-space canvas above the render surface: the stroke is not a mesh, and
/// every point is projected through the live camera. It is decorative and
/// never hit-testable, because the sketch gesture layer beneath it owns input.
struct FFFreehandOverlay: View {
    let samples: [Vec3]
    let camera: FFCamera
    let viewport: CGSize

    var body: some View {
        Canvas { context, _ in
            guard samples.count >= 2 else { return }
            let screens = samples.compactMap {
                camera.screenPoint(
                    for: $0,
                    viewport: Vec2(x: Double(viewport.width), y: Double(viewport.height))
                )
            }
            guard screens.count >= 2 else { return }
            var path = Path()
            path.addLines(screens.map { CGPoint(x: $0.x, y: $0.y) })
            context.stroke(
                path,
                with: .color(FFPalette.textAccent.color),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .allowsHitTesting(false)
        // The same lesson Phase 39 learned: a full-viewport canvas published as
        // an accessibility element makes the Metal view beneath report
        // `isHittable == false`. The stroke is named by the panel instead.
        .accessibilityHidden(true)
    }
}

/// The pencil surface. A zero-distance drag is the shipping gesture; every
/// sample is resolved by the same plane-and-snap rule the line tool uses, so a
/// stroke can start on geometry without inventing a second placement policy.
/// The layer is transparent, takes all touches in sketch mode, and is hidden
/// from accessibility so the Metal element underneath stays the hittable one.
struct FFFreehandSurfaceLayer: View {
    let scene: FFViewportScene
    let camera: FFCamera
    let onSample: (Vec2?) -> Void
    let onEnd: () -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            onSample(resolve(value.location, viewport: proxy.size))
                        }
                        .onEnded { _ in
                            onEnd()
                        }
                )
        }
        .accessibilityHidden(true)
    }

    private func resolve(_ location: CGPoint, viewport: CGSize) -> Vec2? {
        guard viewport.width > 1, viewport.height > 1 else { return nil }
        return FFLineChainPlacement.point(
            at: Vec2(x: Double(location.x), y: Double(location.y)),
            scene: scene,
            camera: camera,
            viewport: Vec2(x: Double(viewport.width), y: Double(viewport.height))
        )
    }
}

/// The sketch tool's card: the live stroke readout, the two fit controls the
/// row names, the commit and cancel commands, and the primitive commands that
/// make Phase 41's curves reachable without inventing a primitive gesture.
/// It edits drafts only; every commit goes through the session.
struct FFFreehandPanel: View {
    let draft: FFFreehandDraft
    let pointCount: Int
    let length: Double
    let lastCommitted: String?
    let message: String?
    let unit: FFLengthUnit
    let onSmoothing: (Double) -> Void
    let onSimplify: (Double) -> Void
    let onFinish: () -> Void
    let onCancel: () -> Void
    let onAddPrimitive: (FFCurvePrimitiveKind) -> Void

    private var status: String {
        guard pointCount > 0 else {
            return lastCommitted ?? "Drag on the sketch plane to draw"
        }
        return "\(pointCount) points · \(FFPrecision.lengthString(millimetres: length, unit: unit))"
    }

    var body: some View {
        FFPanel(title: "Freehand spline", subtitle: "Drag to draw · fitted to NURBS", trailing: unit.label) {
            Text(status)
                .font(FFType.mono)
                .foregroundStyle(FFPalette.textPrimary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("shell.freehand.readout")
                .accessibilityLabel(status)

            if let lastCommitted, pointCount == 0 {
                Text(lastCommitted)
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.textSecondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("shell.freehand.committed")
                    .accessibilityLabel(lastCommitted)
            }

            control(
                label: "Smooth",
                value: draft.smoothing,
                range: 0...FFFreehandStroke.smoothingLimit,
                readout: FFPrecision.fixed(draft.smoothing, decimals: 2),
                identifier: "shell.freehand.smoothing",
                set: onSmoothing
            )

            control(
                label: "Simplify",
                value: draft.simplifyTolerance,
                range: 0.01...0.2,
                readout: FFPrecision.lengthString(
                    millimetres: draft.simplifyTolerance,
                    unit: unit
                ),
                identifier: "shell.freehand.simplify",
                set: onSimplify
            )

            if let message {
                Text(message)
                    .font(FFType.caption)
                    .foregroundStyle(FFPalette.warning.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("shell.freehand.message")
                    .accessibilityLabel(message)
            }

            HStack(spacing: FFSpace.xxs) {
                FFChip(
                    title: "Cancel",
                    accessibilityIdentifier: "shell.freehand.cancel"
                ) {
                    onCancel()
                }
                FFChip(
                    title: "Finish",
                    accessibilityIdentifier: "shell.freehand.finish"
                ) {
                    onFinish()
                }
                .disabled(pointCount < 2)
            }

            Divider()
                .overlay(FFPalette.separator.color)

            Text("Add curve")
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textTertiary.color)
                .accessibilityHidden(true)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: FFSpace.xxs),
                    GridItem(.flexible(), spacing: FFSpace.xxs),
                    GridItem(.flexible(), spacing: FFSpace.xxs),
                ],
                spacing: FFSpace.xxs
            ) {
                ForEach(FFCurvePrimitiveKind.allCases) { kind in
                    FFChip(
                        title: kind.label,
                        accessibilityIdentifier: "shell.freehand.add.\(kind.rawValue)"
                    ) {
                        onAddPrimitive(kind)
                    }
                }
            }
        }
        .frame(width: 340)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.freehand.card")
    }

    private func control(
        label: String,
        value: Double,
        range: ClosedRange<Double>,
        readout: String,
        identifier: String,
        set: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: FFSpace.xs) {
            Text(label)
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textSecondary.color)
                .frame(width: 58, alignment: .leading)
            Slider(
                value: Binding(get: { value }, set: set),
                in: range
            )
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(label)
            .accessibilityValue(readout)
            Text(readout)
                .font(FFType.monoSmall)
                .foregroundStyle(FFPalette.textTertiary.color)
                .frame(width: 74, alignment: .trailing)
        }
    }
}
