import Foundation
import SwiftUI

/// Phase 24's gizmo targets. The plane keeps its 24 pt picture but gains a
/// 44 pt hit area; the arrows already use 44 pt and are drawn last so they win
/// wherever the two overlap.
enum FFGumballHitTarget {
    static let minimum = FFHitTarget.minimum
    static let planeVisual: CGFloat = 24
}

/// Screen-space gizmo over the single Metal pane. Handles are projected from
/// the same camera the renderer uses, so the arrow a user grabs is the arrow
/// the picture shows. The model state lives in `FFGumballSession`; this view
/// only turns touches into constrained deltas.
struct FFGumballOverlay: View {
    @Binding var session: FFGumballSession
    let camera: FFCamera
    let viewport: CGSize
    let selectionCentre: Vec3?
    /// Tells the pane to suspend camera gestures for the duration of a drag.
    let onDragStateChange: (Bool) -> Void
    /// Reports the finished world transform to the document owner. The gizmo
    /// session stays the live interaction state; the commit is what makes the
    /// drag an undoable document edit.
    let onCommitTransform: (Mat4, String) -> Void
    /// Undo is a document command now, not the gizmo's private stack.
    let onUndo: () -> Void

    @State private var numericX = ""
    @State private var numericY = ""
    @State private var numericZ = ""
    @State private var draggingAxis: FFGumballAxis?
    @State private var pivotAtCentre = true
    /// One key per gesture, so repeated commit reports coalesce into one step
    /// while two separate drags stay two steps.
    @State private var dragKey = UUID().uuidString
    /// Haptics are driven by the snapped transform, not by the raw finger
    /// sample, so a sub-step wobble cannot buzz.
    @State private var snapHaptics = FFSnapHapticDriver()

    private var viewportVector: Vec2 {
        Vec2(x: Double(viewport.width), y: Double(viewport.height))
    }

    private var positionLabel: String {
        String(
            format: "X %.3f · Y %.3f · Z %.3f",
            session.transform.m03,
            session.transform.m13,
            session.transform.m23
        )
    }

    private var snapLabel: String {
        session.snapStep < 1
            ? String(format: "%.1f mm", session.snapStep)
            : String(format: "%.0f mm", session.snapStep)
    }

    var body: some View {
        ZStack {
            if let pivot = camera.screenPoint(for: session.pivot, viewport: viewportVector) {
                pivotMarker(at: pivot)

                // Planes first, arrows last. A plane tile is a 24 pt square at
                // 6 mm from the pivot and an arrow's touch target is 44 pt at
                // 10 mm; after an orbit the two can overlap. Drawing the
                // arrows on top means a touch on the arrow is always an axis
                // move, never a plane move that happens to start under it.
                planeHandle(first: .x, second: .y, pivotScreen: pivot)
                planeHandle(first: .y, second: .z, pivotScreen: pivot)
                planeHandle(first: .x, second: .z, pivotScreen: pivot)

                ForEach(FFGumballAxis.allCases) { axis in
                    axisHandle(axis, pivotScreen: pivot)
                }
            }

            VStack {
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    controlCard
                }
            }
            .padding(.horizontal, FFSpace.sm)
            .padding(.top, FFSpace.sm)
            // The viewport HUD owns the bottom strip; the card sits above it
            // so the fps and camera readouts stay legible in the snapshot.
            .padding(.bottom, 72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pivotMarker(at point: Vec2) -> some View {
        Circle()
            .strokeBorder(FFPalette.textPrimary.color, lineWidth: 2)
            .frame(width: 12, height: 12)
            .position(x: point.x, y: point.y)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityIdentifier("gumball.pivot")
            .accessibilityLabel("Gumball pivot")
    }

    private func axisHandle(_ axis: FFGumballAxis, pivotScreen: Vec2) -> some View {
        let tip = camera.screenPoint(
            for: session.pivot + axis.direction * FFGumballMath.axisLengthMillimetres,
            viewport: viewportVector
        )
        return Group {
            if let tip {
                Path { path in
                    path.move(to: CGPoint(x: pivotScreen.x, y: pivotScreen.y))
                    path.addLine(to: CGPoint(x: tip.x, y: tip.y))
                }
                .stroke(axisColor(axis), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .allowsHitTesting(false)

                ZStack {
                    Circle()
                        .fill(axisColor(axis))
                        .frame(width: 12, height: 12)
                    Circle()
                        .fill(axisColor(axis).opacity(0.001))
                        .frame(width: FFGumballHitTarget.minimum, height: FFGumballHitTarget.minimum)
                }
                .frame(width: FFGumballHitTarget.minimum, height: FFGumballHitTarget.minimum)
                .contentShape(Circle())
                .position(x: tip.x, y: tip.y)
                .gesture(axisDrag(axis))
                .accessibilityElement()
                .accessibilityIdentifier("gumball.handle.\(axis.rawValue)")
                .accessibilityLabel("Gumball \(axis.label) axis")
            }
        }
    }

    private func planeHandle(
        first: FFGumballAxis,
        second: FFGumballAxis,
        pivotScreen: Vec2
    ) -> some View {
        let anchor = session.pivot + (first.direction + second.direction) * 6
        let point = camera.screenPoint(for: anchor, viewport: viewportVector)
        return Group {
            if let point {
                RoundedRectangle(cornerRadius: 4)
                    .fill(axisColor(first).opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(axisColor(second).opacity(0.8), lineWidth: 1)
                    )
                    .frame(
                        width: FFGumballHitTarget.planeVisual,
                        height: FFGumballHitTarget.planeVisual
                    )
                    .frame(
                        width: FFGumballHitTarget.minimum,
                        height: FFGumballHitTarget.minimum
                    )
                    .contentShape(Rectangle())
                    .position(x: point.x, y: point.y)
                    .gesture(planeDrag(first: first, second: second))
                    .accessibilityElement()
                    .accessibilityIdentifier("gumball.plane.\(first.rawValue)\(second.rawValue)")
                    .accessibilityLabel("Gumball \(first.label)\(second.label) plane")
            }
        }
    }

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.xxs) {
            HStack(spacing: FFSpace.xxs) {
                ForEach(FFGumballMode.allCases) { mode in
                    FFChip(
                        title: mode.label,
                        isSelected: session.mode == mode,
                        accessibilityIdentifier: "gumball.mode.\(mode.rawValue)"
                    ) {
                        session.mode = mode
                    }
                }
            }

            HStack(spacing: FFSpace.xxs) {
                numericField("X", text: $numericX, identifier: "gumball.numeric.x")
                numericField("Y", text: $numericY, identifier: "gumball.numeric.y")
                numericField("Z", text: $numericZ, identifier: "gumball.numeric.z")

                Button("Set") {
                    session.setTranslation(
                        x: Double(numericX),
                        y: Double(numericY),
                        z: Double(numericZ)
                    )
                    onCommitTransform(session.transform, "numeric-\(UUID().uuidString)")
                    numericX = ""
                    numericY = ""
                    numericZ = ""
                }
                .font(FFType.caption)
                .frame(minWidth: FFHitTarget.minimum, minHeight: FFHitTarget.minimum)
                .contentShape(Rectangle())
                .foregroundStyle(FFPalette.textPrimary.color)
                .accessibilityIdentifier("gumball.numeric.apply")
            }

            HStack(spacing: FFSpace.xxs) {
                FFChip(
                    title: "Snap \(snapLabel)",
                    accessibilityIdentifier: "gumball.snap"
                ) {
                    session.cycleSnap()
                }

                FFChip(
                    title: "Pivot",
                    accessibilityIdentifier: "gumball.pivotButton"
                ) {
                    pivotAtCentre.toggle()
                    session.setPivot(
                        pivotAtCentre ? (selectionCentre ?? session.pivot) : .zero
                    )
                }

                FFChip(
                    title: "Undo",
                    accessibilityIdentifier: "gumball.undo"
                ) {
                    onUndo()
                }
            }

            Text(positionLabel)
                .font(FFType.monoSmall)
                .foregroundStyle(FFPalette.textSecondary.color)
                .lineLimit(1)
                .accessibilityIdentifier("gumball.position")
                .accessibilityLabel("Gumball position \(positionLabel)")
        }
        .padding(FFSpace.xs)
        .background(FFPalette.panel.color.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(FFPalette.separator.color, lineWidth: 1)
        )
        .frame(maxWidth: 340)
    }

    private func numericField(
        _ placeholder: String,
        text: Binding<String>,
        identifier: String
    ) -> some View {
        TextField(placeholder, text: text)
            .font(FFType.monoSmall)
            .foregroundStyle(FFPalette.textPrimary.color)
            .keyboardType(.numbersAndPunctuation)
            .frame(width: 54, height: FFHitTarget.minimum)
            .padding(.horizontal, 4)
            .background(FFPalette.raised.color, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier(identifier)
            .accessibilityLabel("Gumball \(placeholder) numeric entry")
    }

    private func axisDrag(_ axis: FFGumballAxis) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if draggingAxis != axis {
                    draggingAxis = axis
                    dragKey = UUID().uuidString
                    session.beginDrag()
                    snapHaptics.begin(transform: session.transform, step: session.snapStep)
                    FFSnapHaptics.prepare()
                    onDragStateChange(true)
                }
                switch session.mode {
                case .move:
                    if let delta = FFGumballMath.moveDelta(
                        constraint: .axis(axis),
                        screenTranslation: value.translation,
                        camera: camera,
                        pivot: session.activePivot,
                        viewport: viewportVector,
                        snap: session.snapStep
                    ) {
                        session.move(by: delta)
                        fireHapticIfSnapped()
                    }
                case .rotate:
                    session.rotate(
                        around: axis,
                        degrees: FFGumballMath.rotationDegrees(
                            screenTranslation: value.translation
                        )
                    )
                case .scale:
                    session.scale(
                        around: axis,
                        factor: FFGumballMath.scaleFactor(screenTranslation: value.translation)
                    )
                }
            }
            .onEnded { _ in
                session.commitDrag()
                onCommitTransform(session.transform, dragKey)
                snapHaptics.reset()
                draggingAxis = nil
                onDragStateChange(false)
            }
    }

    private func planeDrag(first: FFGumballAxis, second: FFGumballAxis) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if draggingAxis != first {
                    draggingAxis = first
                    dragKey = UUID().uuidString
                    session.beginDrag()
                    snapHaptics.begin(transform: session.transform, step: session.snapStep)
                    FFSnapHaptics.prepare()
                    onDragStateChange(true)
                }
                guard session.mode == .move else { return }
                if let delta = FFGumballMath.moveDelta(
                    constraint: .plane(first, second),
                    screenTranslation: value.translation,
                    camera: camera,
                    pivot: session.activePivot,
                    viewport: viewportVector,
                    snap: session.snapStep
                ) {
                    session.move(by: delta)
                    fireHapticIfSnapped()
                }
            }
            .onEnded { _ in
                session.commitDrag()
                onCommitTransform(session.transform, dragKey)
                snapHaptics.reset()
                draggingAxis = nil
                onDragStateChange(false)
            }
    }

    private func fireHapticIfSnapped() {
        guard snapHaptics.update(
            transform: session.transform,
            step: session.snapStep
        ) else { return }
        FFSnapHaptics.fire()
    }

    private func axisColor(_ axis: FFGumballAxis) -> Color {
        switch axis {
        case .x: return Color(red: 0.92, green: 0.26, blue: 0.28)
        case .y: return Color(red: 0.34, green: 0.80, blue: 0.36)
        case .z: return Color(red: 0.30, green: 0.55, blue: 0.95)
        }
    }
}
