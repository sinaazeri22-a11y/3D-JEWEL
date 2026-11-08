import Foundation
import SwiftUI

/// The four width bands the shell is designed around. Phase 4 names these
/// explicitly so the layout contract is testable without a rendered window.
enum FFBreakpoint: String, CaseIterable, Sendable {
    case compact
    case medium
    case regular
    case wide

    init(width: CGFloat) {
        if width >= 1366 {
            self = .wide
        } else if width >= 1024 {
            self = .regular
        } else if width >= 820 {
            self = .medium
        } else {
            self = .compact
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .compact: 0
        case .medium: 820
        case .regular: 1024
        case .wide: 1366
        }
    }

    var label: String {
        switch self {
        case .compact: "Compact"
        case .medium: "Medium"
        case .regular: "Regular"
        case .wide: "Wide"
        }
    }
}

/// Computed geometry for the three-zone workspace. The values are pure data,
/// so a unit test can freeze them as a layout snapshot and the UI test can
/// verify what the rendered shell actually produced.
struct FFShellMetrics: Equatable {
    let width: CGFloat
    let breakpoint: FFBreakpoint
    let toolsWidth: CGFloat
    let inspectorWidth: CGFloat
    let toolsCollapsed: Bool
    let inspectorCollapsed: Bool

    var viewportWidth: CGFloat {
        max(0, width - toolsWidth - inspectorWidth)
    }

    var isCompact: Bool {
        breakpoint == .compact
    }

    /// The five widths the Phase 4 UI test drives the shell through. They cover
    /// every breakpoint and both sides of the first threshold.
    static let testWidths: [CGFloat] = [640, 700, 820, 1024, 1366]

    static func calculate(
        width: CGFloat,
        toolsCollapsed: Bool = false,
        inspectorCollapsed: Bool = false
    ) -> FFShellMetrics {
        let safeWidth = max(0, width)
        let breakpoint = FFBreakpoint(width: safeWidth)

        let toolColumn: CGFloat
        let inspectorColumn: CGFloat
        switch breakpoint {
        case .wide:
            toolColumn = 88
            inspectorColumn = 320
        case .regular:
            toolColumn = 80
            inspectorColumn = 288
        case .medium:
            toolColumn = 72
            inspectorColumn = 240
        case .compact:
            toolColumn = 56
            inspectorColumn = 208
        }

        let visibleTools = toolsCollapsed ? 0 : toolColumn
        // Never let the inspector squeeze the viewport below 200 pt. At the
        // 640 pt minimum this cannot trigger; it is the guard for a scene that
        // is resized before the size restriction is applied.
        let availableForInspector = max(0, safeWidth - visibleTools - 200)
        let visibleInspector = inspectorCollapsed ? 0 : min(inspectorColumn, availableForInspector)

        return FFShellMetrics(
            width: safeWidth,
            breakpoint: breakpoint,
            toolsWidth: visibleTools,
            inspectorWidth: visibleInspector,
            toolsCollapsed: toolsCollapsed,
            inspectorCollapsed: inspectorCollapsed
        )
    }
}

/// The deliberate Phase 13 viewport layout. Fresh documents open in a single
/// maximised Perspective; four-up is a preset one chip away, not the default.
/// Keeping the panes as value data lets the unit test freeze the choice and the
/// UI test assert the rendered frames against it.
enum FFViewportLayout: String, CaseIterable, Identifiable, Sendable, Equatable {
    case single
    case fourUp

    static let defaultLayout = FFViewportLayout.single

    var id: String { rawValue }

    var label: String {
        switch self {
        case .single: "1-up"
        case .fourUp: "4-up"
        }
    }

    var accessibilityIdentifier: String { "shell.viewport.layout.\(rawValue)" }

    var panes: [FFViewportPanePlan] {
        switch self {
        case .single:
            [
                FFViewportPanePlan(
                    id: "perspective",
                    title: "Perspective",
                    namedView: .iso,
                    projection: .perspective
                ),
            ]
        case .fourUp:
            [
                FFViewportPanePlan(
                    id: "perspective",
                    title: "Perspective",
                    namedView: .iso,
                    projection: .perspective
                ),
                FFViewportPanePlan(
                    id: "top",
                    title: "Top",
                    namedView: .top,
                    projection: .orthographic
                ),
                FFViewportPanePlan(
                    id: "front",
                    title: "Front",
                    namedView: .front,
                    projection: .orthographic
                ),
                FFViewportPanePlan(
                    id: "right",
                    title: "Right",
                    namedView: .right,
                    projection: .orthographic
                ),
            ]
        }
    }

    var initialCameras: [String: FFCamera] {
        Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0.initialCamera) })
    }
}

/// One pane of a layout. The initial camera is derived from the named view and
/// projection only; framing stays user-controlled once the pane is live.
struct FFViewportPanePlan: Identifiable, Sendable {
    let id: String
    let title: String
    let namedView: FFNamedView?
    let projection: FFProjectionMode

    var accessibilityIdentifier: String { "shell.viewport.pane.\(id)" }

    var initialCamera: FFCamera {
        var camera = FFCamera.standard
        camera.setProjection(projection)
        if let namedView {
            camera.apply(namedView)
        }
        return camera
    }
}

private struct FFTool: Identifiable {
    let id: String
    let systemImage: String
    let label: String
}

/// The Phase 4 workspace. It is deliberately driven by its container width,
/// not by `horizontalSizeClass`, so Stage Manager resizes are continuous and
/// the layout laboratory can render any width without a second window.
struct FFAppShell: View {
    /// When set, the shell lays itself out at this width instead of the host
    /// width. The layout laboratory uses it; the app leaves it nil.
    var fixedWidth: CGFloat? = nil
    /// Test surface: seeds a saved bundle with a crash journal before opening
    /// it through the real reopen path. The shipping app leaves it false.
    var launchRecoveryDemo: Bool = false
    /// Test surface: seeds two real saved bundles so the browser suite lists
    /// only fixtures it controls. The shipping app leaves it false.
    var launchBrowserDemo: Bool = false
    var onOpenGallery: () -> Void = {}

    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTool = "select"
    @State private var toolsCollapsed = false
    @State private var inspectorCollapsed = false
    @State private var bandWidth = "18.00"
    @State private var performance = FFPerformanceReport()
    @State private var camera = FFCamera.standard
    @State private var namedView: FFNamedView? = .iso
    @State private var lengthUnit: FFLengthUnit = .millimetres
    @State private var showingBrowser = false
    /// The document and scene owner. The shell keeps layout and input only.
    @StateObject private var session = FFEditorSession()

    private let tools: [FFTool] = [
        FFTool(id: "select", systemImage: "cursorarrow", label: "Select"),
        FFTool(id: "sketch", systemImage: "scribble", label: "Sketch"),
        FFTool(id: "gem", systemImage: "diamond", label: "Gem"),
        FFTool(id: "measure", systemImage: "ruler", label: "Measure"),
        FFTool(id: "render", systemImage: "camera", label: "Render"),
    ]

    var body: some View {
        GeometryReader { proxy in
            let width = fixedWidth ?? proxy.size.width
            let metrics = FFShellMetrics.calculate(
                width: width,
                toolsCollapsed: toolsCollapsed,
                inspectorCollapsed: inspectorCollapsed
            )

            ZStack {
                VStack(spacing: 0) {
                FFAppBar(
                    width: width,
                    status: session.documentStatus,
                    canUndo: session.documentSession.canUndo,
                    onNewDocument: { session.newDocument() },
                    onLoadFixture: { session.loadFixture() },
                    onSave: { try? session.save() },
                    onReopen: { try? session.reopen() },
                    onUndo: { session.undo() },
                    onOpenBrowser: {
                        session.refreshLibrary()
                        showingBrowser = true
                    },
                    onOpenGallery: onOpenGallery
                )

                HStack(spacing: 0) {
                    if !toolsCollapsed {
                        FFToolRail(
                            tools: tools,
                            selectedTool: $selectedTool,
                            onCollapse: { toolsCollapsed = true }
                        )
                        .frame(width: metrics.toolsWidth)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("shell.tools")
                    }

                    FFViewport(
                        selectedTool: selectedTool,
                        toolsCollapsed: toolsCollapsed,
                        inspectorCollapsed: inspectorCollapsed,
                        performance: performance,
                        lengthUnit: lengthUnit,
                        camera: $camera,
                        namedView: $namedView,
                        scene: session.scene,
                        displayModes: session.displayModes,
                        lockedNodeIDs: session.lockedNodeIDs,
                        selection: $session.selection,
                        measurements: session.measurements,
                        onCommitMeasurement: { session.addMeasurement($0) },
                        onClearMeasurements: { session.clearMeasurements() },
                        onCommitGizmoTransform: { nodeID, transform, key in
                            session.commitGizmoTransform(
                                nodeID: nodeID,
                                worldTransform: transform,
                                dragKey: key
                            )
                        },
                        onUndoEdit: { session.undo() },
                        onCycleDisplayMode: { session.cycleDisplayMode(for: $0) },
                        onPerformance: { performance = $0 },
                        onShowTools: { toolsCollapsed = false },
                        onShowInspector: { inspectorCollapsed = false }
                    )
                    .frame(width: metrics.viewportWidth)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("shell.viewport")

                    if !inspectorCollapsed {
                        FFInspector(
                            bandWidth: $bandWidth,
                            lengthUnit: $lengthUnit,
                            scene: session.scene,
                            layers: session.layers,
                            currentLayerID: session.currentLayerID,
                            layerCounts: Dictionary(
                                uniqueKeysWithValues: session.layers.map {
                                    ($0.id, session.nodeCount(inLayer: $0.id))
                                }
                            ),
                            selection: $session.selection,
                            onAddLayer: { session.addLayer() },
                            onSetCurrentLayer: { session.setCurrentLayer($0) },
                            onToggleLayerVisibility: { id in
                                guard let layer = session.layer(withID: id) else { return }
                                session.setLayerVisible(id, isVisible: !layer.isVisible)
                            },
                            onToggleLayerLock: { id in
                                guard let layer = session.layer(withID: id) else { return }
                                session.setLayerLocked(id, isLocked: !layer.isLocked)
                            },
                            onCycleLayerColor: { session.cycleLayerColor($0) },
                            onSelectLayer: { session.selectLayer($0) },
                            onAssignToLayer: { session.assignSelection(to: $0) },
                            onCollapse: { inspectorCollapsed = true }
                        )
                        .frame(width: metrics.inspectorWidth)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("shell.inspector")
                    }
                }
                .frame(maxHeight: .infinity)
                }

                if let offer = session.recoveryOffer {
                    FFRecoveryPromptView(
                        offer: offer,
                        onRestore: { session.restoreRecovery() },
                        onDiscard: { session.discardRecovery() }
                    )
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            .animation(.easeOut(duration: 0.15), value: session.recoveryOffer != nil)
            .frame(width: width, height: proxy.size.height)
            .background(FFPalette.canvas.color)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("shell")
            .onAppear {
                if launchRecoveryDemo, let url = FFLaunchFixtures.prepareRecoveryDocument() {
                    try? session.reopen(from: url)
                }
                if launchBrowserDemo {
                    FFLaunchFixtures.prepareBrowserDocuments()
                    session.refreshLibrary()
                }
                session.startAutosave()
            }
            .onDisappear {
                session.stopAutosave()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    session.autosaveForBackground()
                }
            }
            .onOpenURL { url in
                try? session.openExternalDocument(at: url)
            }
            .sheet(isPresented: $showingBrowser) {
                FFDocumentBrowserView(
                    session: session,
                    onClose: { showingBrowser = false }
                )
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - App bar

private struct FFAppBar: View {
    let width: CGFloat
    let status: String
    let canUndo: Bool
    let onNewDocument: () -> Void
    let onLoadFixture: () -> Void
    let onSave: () -> Void
    let onReopen: () -> Void
    let onUndo: () -> Void
    let onOpenBrowser: () -> Void
    let onOpenGallery: () -> Void

    private var isCompact: Bool {
        width < 820
    }

    private func documentButton(
        _ systemImage: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void,
        isEnabled: Bool = true
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(FFPalette.textSecondary.color)
                .frame(width: FFHitTarget.minimum, height: FFHitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(FFPressStyle())
        .disabled(!isEnabled)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
        .accessibilityHint(isEnabled ? label : "\(label), unavailable")
    }

    var body: some View {
        HStack(spacing: FFSpace.sm) {
            Image(systemName: "diamond.fill")
                .font(.system(size: 21, weight: .light))
                .foregroundStyle(FFPalette.accent.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(AppIdentity.displayName)
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .foregroundStyle(FFPalette.textPrimary.color)

                if !isCompact {
                    Text(AppIdentity.tagline)
                        .font(FFType.caption)
                        .foregroundStyle(FFPalette.textTertiary.color)
                }
            }

            Spacer(minLength: FFSpace.xs)

            // Document commands are explicit buttons, not a Menu. A Menu's
            // items exist in the accessibility tree before it presents, so a
            // touch driver could find an item it cannot actually hit; these
            // buttons are visible and hittable on the bar itself.
            HStack(spacing: 0) {
                documentButton("doc.badge.plus", label: "New document", identifier: "shell.document.new", action: onNewDocument)
                documentButton("shippingbox", label: "Load fixture", identifier: "shell.document.fixture", action: onLoadFixture)
                documentButton("square.and.arrow.down", label: "Save", identifier: "shell.document.save", action: onSave)
                documentButton("arrow.clockwise", label: "Reopen", identifier: "shell.document.reopen", action: onReopen)
                documentButton("arrow.uturn.backward", label: "Undo", identifier: "shell.document.undo", action: onUndo, isEnabled: canUndo)
            }

            if !isCompact {
                Text(status)
                    .font(FFType.monoSmall)
                    .foregroundStyle(FFPalette.textSecondary.color)
                    .lineLimit(1)
                    .accessibilityIdentifier("shell.document.status")
                    .accessibilityLabel(status)
            }

            Button(action: onOpenGallery) {
                HStack(spacing: FFSpace.xxs) {
                    Image(systemName: "square.grid.2x2")
                    if !isCompact {
                        Text("Components")
                    }
                }
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textSecondary.color)
                .frame(width: isCompact ? 44 : 116, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(FFPressStyle())
            .accessibilityIdentifier("shell.openGallery")
            .accessibilityLabel("Open component gallery")

            // The documents entry takes the slot of the old inert export stub,
            // so the bar's 640 pt budget is unchanged. Below the medium band
            // Files remains the way in; the browser is deliberately not another
            // control competing for that row.
            if !isCompact {
                documentButton(
                    "folder",
                    label: "Documents",
                    identifier: "shell.document.browser",
                    action: onOpenBrowser
                )
            }
        }
        .padding(.horizontal, FFSpace.sm)
        .frame(minHeight: 56)
        .background(FFPalette.panel.color)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FFPalette.separator.color)
                .frame(height: 1)
        }
    }
}

// MARK: - Tools

private struct FFToolRail: View {
    let tools: [FFTool]
    @Binding var selectedTool: String
    let onCollapse: () -> Void

    var body: some View {
        VStack(spacing: FFSpace.xxs) {
            ForEach(tools) { tool in
                Button {
                    selectedTool = tool.id
                } label: {
                    Image(systemName: tool.systemImage)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(
                            selectedTool == tool.id
                                ? FFPalette.onAccent.color
                                : FFPalette.textSecondary.color
                        )
                        .frame(width: 44, height: 44)
                        .background(
                            selectedTool == tool.id ? FFPalette.accent.color : Color.clear,
                            in: RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(FFPressStyle())
                .accessibilityIdentifier("shell.tool.\(tool.id)")
                .accessibilityLabel(tool.label)
                .accessibilityAddTraits(selectedTool == tool.id ? .isSelected : [])
            }

            Spacer(minLength: FFSpace.xs)

            Button(action: onCollapse) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(FFPalette.textTertiary.color)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FFPressStyle())
            .accessibilityLabel("Hide tools")
        }
        .padding(.vertical, FFSpace.xs)
        .frame(maxHeight: .infinity)
        .background(FFPalette.panel.color)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(FFPalette.separator.color)
                .frame(width: 1)
        }
    }
}

// MARK: - Viewport

private struct FFViewport: View {
    let selectedTool: String
    let toolsCollapsed: Bool
    let inspectorCollapsed: Bool
    let performance: FFPerformanceReport
    let lengthUnit: FFLengthUnit
    @Binding var camera: FFCamera
    @Binding var namedView: FFNamedView?
    let scene: FFViewportScene
    let displayModes: [String: FFDisplayMode]
    let lockedNodeIDs: Set<UUID>
    @Binding var selection: FFSelectionState
    let measurements: [FFMeasurement]
    let onCommitMeasurement: (FFMeasurement) -> Void
    let onClearMeasurements: () -> Void
    let onCommitGizmoTransform: (UUID, Mat4, String) -> Void
    let onUndoEdit: () -> Void
    let onCycleDisplayMode: (String) -> Void
    let onPerformance: (FFPerformanceReport) -> Void
    let onShowTools: () -> Void
    let onShowInspector: () -> Void
    @State private var viewportSize = CGSize(width: 800, height: 600)
    @State private var layout: FFViewportLayout = .defaultLayout
    @State private var fourUpCameras: [String: FFCamera] = [:]
    /// Measurements outlive a layout switch, so the session belongs here rather
    /// than to one pane. The row asks for the tool and its labels; annotations
    /// are not part of the saved document.
    @State private var measurement = FFMeasurementSession()
    /// The Phase 21 readout is a view of the renderer's own counters, so the
    /// switch that shows it is pane UI state, not document state.
    @State private var showsPerformanceOverlay = false

    private var isMeasuring: Bool { selectedTool == "measure" }

    private var scaleBarPlan: FFScaleBarPlan? {
        guard let units = camera.worldUnitsPerPoint(
            viewport: Vec2(x: viewportSize.width, y: viewportSize.height)
        ) else { return nil }
        return FFScaleBar.plan(millimetresPerPoint: units)
    }

    private var fpsLabel: String {
        performance.fpsLabel
    }

    private var cameraLabel: String {
        let prefix = namedView.map { "\($0.label) · " } ?? "Free · "
        return prefix + camera.summary
    }

    var body: some View {
        ZStack {
            FFPalette.canvas.color

            viewportSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: FFSpace.sm) {
                    // Display modes live on the pane itself, one chip per
                    // viewport, so four-up can mix a shaded Perspective with
                    // a technical Top. A second, global set of mode buttons
                    // here would be a lie.
                    Spacer(minLength: 0)

                    Text(selectedTool.uppercased())
                        .font(FFType.monoSmall)
                        .foregroundStyle(FFPalette.textTertiary.color)
                        .padding(.top, FFSpace.sm)
                        .accessibilityIdentifier("shell.viewport.toolName")
                }
                .padding(FFSpace.sm)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: FFSpace.xxs) {
                        ForEach(FFViewportLayout.allCases) { option in
                            FFChip(
                                title: option.label,
                                isSelected: layout == option,
                                accessibilityIdentifier: option.accessibilityIdentifier
                            ) {
                                layout = option
                            }
                        }

                        if layout == .single {
                            ForEach([FFNamedView.iso, .front, .top]) { view in
                                FFChip(
                                    title: view.shortLabel,
                                    isSelected: namedView == view,
                                    accessibilityIdentifier: "shell.viewport.namedView.\(view.rawValue)"
                                ) {
                                    camera.apply(view)
                                    namedView = view
                                }
                            }

                            FFChip(
                                title: camera.projection.label,
                                systemImage: "cube.transparent",
                                accessibilityIdentifier: "shell.viewport.projection"
                            ) {
                                camera.setProjection(
                                    camera.projection == .perspective ? .orthographic : .perspective
                                )
                            }

                            FFChip(
                                title: "Frame",
                                systemImage: "viewfinder",
                                accessibilityIdentifier: "shell.viewport.frame"
                            ) {
                                FFCameraNavigation.frameAll(&camera)
                                namedView = nil
                            }
                        }
                    }
                    .padding(.horizontal, FFSpace.sm)
                }
                .scrollClipDisabled()

                Spacer(minLength: FFSpace.sm)

                HStack(alignment: .bottom, spacing: FFSpace.xs) {
                    VStack(alignment: .leading, spacing: FFSpace.xxs) {
                        if layout == .single, let plan = scaleBarPlan {
                            HStack(spacing: FFSpace.xxs) {
                                Rectangle()
                                    .fill(FFPalette.textSecondary.color)
                                    .frame(width: CGFloat(plan.pixelWidth), height: 2)
                                Text(plan.label)
                                    .font(FFType.monoSmall)
                                    .foregroundStyle(FFPalette.textTertiary.color)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("shell.viewport.scaleBar")
                            .accessibilityLabel("Scale bar, \(plan.label)")
                        }

                        HStack(spacing: FFSpace.xxs) {
                            Circle()
                                .fill(FFPalette.success.color)
                                .frame(width: 6, height: 6)
                            Text(layout == .single ? cameraLabel : "Four-up · Perspective / Top / Front / Right")
                                .font(FFType.monoSmall)
                                .foregroundStyle(FFPalette.textTertiary.color)
                                .lineLimit(1)
                                .accessibilityIdentifier("shell.viewport.camera")
                                .accessibilityLabel(layout == .single ? cameraLabel : "Four-up layout with Perspective, Top, Front and Right panes")

                            Text("\(fpsLabel) · \(layout == .single ? camera.projection.label.lowercased() : "four-up")")
                                .font(FFType.monoSmall)
                                .foregroundStyle(FFPalette.textTertiary.color)
                                .accessibilityIdentifier("shell.viewport.fps")
                                .accessibilityLabel("Metal viewport, grid and world axes, \(fpsLabel)")

                            Button {
                                showsPerformanceOverlay.toggle()
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: "gauge.with.dots.needle.50percent")
                                        .accessibilityHidden(true)
                                    Text("Perf")
                                }
                                .font(FFType.monoSmall)
                                .foregroundStyle(
                                    showsPerformanceOverlay
                                        ? FFPalette.onAccent.color
                                        : FFPalette.textSecondary.color
                                )
                                .padding(.horizontal, FFSpace.xs)
                                .frame(minHeight: 44)
                                .background(
                                    showsPerformanceOverlay
                                        ? FFPalette.accent.color
                                        : FFPalette.raised.color,
                                    in: Capsule()
                                )
                            }
                            .buttonStyle(FFPressStyle())
                            .accessibilityIdentifier("hud.performance.toggle")
                            .accessibilityLabel("Performance overlay")
                            .accessibilityValue(showsPerformanceOverlay ? "On" : "Off")

                            // The layout chips above already show the current layout
                            // with their selected state. A duplicate label here
                            // overflowed the 749 pt viewport and printed on top of
                            // the fps readout in the Phase 13 snapshot.
                        }
                    }

                    Spacer(minLength: 0)

                    if toolsCollapsed {
                        shellToggle(systemImage: "sidebar.leading", label: "Show tools", action: onShowTools)
                    }
                    if inspectorCollapsed {
                        shellToggle(systemImage: "sidebar.trailing", label: "Show inspector", action: onShowInspector)
                    }
                }
                .padding(FFSpace.sm)
            }

            if showsPerformanceOverlay {
                VStack {
                    Spacer(minLength: 0)
                    HStack(alignment: .bottom) {
                        FFPerformanceOverlay(report: performance)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, FFSpace.sm)
                    .padding(.bottom, 64)
                }
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            viewportSize = size
        }
        .clipped()
    }

    @ViewBuilder
    private var viewportSurface: some View {
        switch layout {
        case .single:
            if let pane = FFViewportLayout.single.panes.first {
                FFViewportPane(
                    plan: pane,
                    camera: $camera,
                    scene: scene,
                    mode: displayModes[pane.id] ?? .shaded,
                    lockedNodeIDs: lockedNodeIDs,
                    selection: $selection,
                    measurement: measurement,
                    measurements: measurements,
                    onCommitMeasurement: onCommitMeasurement,
                    onClearMeasurements: onClearMeasurements,
                    onCommitGizmoTransform: onCommitGizmoTransform,
                    onUndoEdit: onUndoEdit,
                    isMeasuring: isMeasuring,
                    unit: lengthUnit,
                    metalIdentifier: "shell.viewport.metal",
                    onCycleDisplayMode: { onCycleDisplayMode(pane.id) },
                    onCameraChange: { updated in
                        camera = updated
                        namedView = FFCameraNavigation.namedView(for: updated)
                    },
                    onPerformance: onPerformance
                )
            }
        case .fourUp:
            fourUpGrid
        }
    }

    private var fourUpGrid: some View {
        let panes = FFViewportLayout.fourUp.panes
        return GeometryReader { proxy in
            let gap: CGFloat = 1
            let paneWidth = max(1, (proxy.size.width - gap) / 2)
            let paneHeight = max(1, (proxy.size.height - gap) / 2)

            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    fourUpPane(panes[0])
                        .frame(width: paneWidth, height: paneHeight)
                    fourUpPane(panes[1])
                        .frame(width: paneWidth, height: paneHeight)
                }
                HStack(spacing: gap) {
                    fourUpPane(panes[2])
                        .frame(width: paneWidth, height: paneHeight)
                    fourUpPane(panes[3])
                        .frame(width: paneWidth, height: paneHeight)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // The single pane is a UIView host and fills the whole viewport element.
        // A GeometryReader is safe-area aware, so on iPad it stopped 20 pt short
        // of the bottom home-indicator inset and the preset was not a true half
        // split. Ignoring the container inset makes both layouts fill the same
        // rectangle the acceptance test measures.
        .ignoresSafeArea(.container, edges: .bottom)
        .background(FFPalette.separator.color)
    }

    private func fourUpPane(_ pane: FFViewportPanePlan) -> some View {
        FFViewportPane(
            plan: pane,
            camera: fourUpBinding(for: pane),
            scene: scene,
            mode: displayModes[pane.id] ?? .shaded,
            lockedNodeIDs: lockedNodeIDs,
            selection: $selection,
            measurement: measurement,
            measurements: measurements,
            onCommitMeasurement: onCommitMeasurement,
            onClearMeasurements: onClearMeasurements,
            onCommitGizmoTransform: onCommitGizmoTransform,
            onUndoEdit: onUndoEdit,
            // The four-up panes are camera previews; measuring happens in the
            // maximised Perspective pane that a document opens in.
            isMeasuring: false,
            unit: lengthUnit,
            metalIdentifier: "shell.viewport.metal.\(pane.id)",
            onCycleDisplayMode: { onCycleDisplayMode(pane.id) },
            onCameraChange: { updated in
                fourUpCameras[pane.id] = updated
            },
            onPerformance: onPerformance
        )
    }

    private func fourUpBinding(for pane: FFViewportPanePlan) -> Binding<FFCamera> {
        Binding(
            get: { fourUpCameras[pane.id] ?? pane.initialCamera },
            set: { fourUpCameras[pane.id] = $0 }
        )
    }

    private func shellToggle(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(FFPalette.textSecondary.color)
                .frame(width: 44, height: 44)
                .background(
                    FFPalette.panel.color,
                    in: RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
                        .stroke(FFPalette.separator.color, lineWidth: 1)
                }
        }
        .buttonStyle(FFPressStyle())
        .accessibilityLabel(label)
    }
}

/// Carries the tap's hover sample from the viewport callback into the pick
/// callback. A reference type is deliberate: SwiftUI state writes are not
/// guaranteed to be readable by a second callback in the same run loop turn.
private final class FFMeasureTapBox {
    var point: Vec2?
}

/// One live viewport pane. The binding is owned by the layout, so the single
/// pane shares the global camera and the four-up panes keep independent ones.
private struct FFViewportPane: View {
    let plan: FFViewportPanePlan
    @Binding var camera: FFCamera
    let scene: FFViewportScene
    let mode: FFDisplayMode
    let lockedNodeIDs: Set<UUID>
    @Binding var selection: FFSelectionState
    @ObservedObject var measurement: FFMeasurementSession
    let measurements: [FFMeasurement]
    let onCommitMeasurement: (FFMeasurement) -> Void
    let onClearMeasurements: () -> Void
    let onCommitGizmoTransform: (UUID, Mat4, String) -> Void
    let onUndoEdit: () -> Void
    let isMeasuring: Bool
    let unit: FFLengthUnit
    let metalIdentifier: String
    let onCycleDisplayMode: () -> Void
    let onCameraChange: (FFCamera) -> Void
    let onPerformance: (FFPerformanceReport) -> Void

    @State private var gumball = FFGumballSession()
    @State private var gizmoDragging = false
    @State private var snapMarkers: [FFSnapMarker] = []
    @State private var hoverPoint: Vec2?
    @State private var paneSize = CGSize(width: 1, height: 1)
    /// The viewport publishes hover before pick on a tap; a reference box keeps
    /// that sample readable inside the pick callback without a SwiftUI state
    /// round-trip.
    @State private var measureTap = FFMeasureTapBox()

    /// The four-up panes are camera previews, not editing surfaces. The gizmo
    /// lives in the maximised Perspective pane, the one a document opens in.
    private var showsGumball: Bool { metalIdentifier == "shell.viewport.metal" }

    private var selectionScene: FFViewportScene {
        selection.applying(to: scene)
    }

    private var selectedNode: FFRenderNode? {
        selectionScene.nodes.first(where: \.isSelected)
    }

    /// A gizmo exists only on a node that is both drawn and editable. A hidden
    /// layer has no gizmo, and a locked layer has none because the session
    /// would reject the edit a drag produces.
    private var editableGumballNodeID: UUID? {
        guard let nodeID = gumball.nodeID,
              let node = selectionScene.node(id: nodeID),
              node.isVisible,
              !lockedNodeIDs.contains(nodeID)
        else { return nil }
        return nodeID
    }

    private var displayScene: FFViewportScene {
        guard let nodeID = editableGumballNodeID,
              let index = selectionScene.nodes.firstIndex(where: { $0.id == nodeID })
        else { return selectionScene }
        var copy = selectionScene
        copy.nodes[index].transform = gumball.transform
        return copy
    }

    /// The centre of the selected mesh in world space, used by the Pivot
    /// control. It follows the gizmo transform so the button stays meaningful
    /// after a move.
    private var selectionCentre: Vec3? {
        guard let node = selectedNode, let bounds = node.mesh.bounds else { return nil }
        let local = Vec3(
            x: (bounds.minimum.x + bounds.maximum.x) * 0.5,
            y: (bounds.minimum.y + bounds.maximum.y) * 0.5,
            z: (bounds.minimum.z + bounds.maximum.z) * 0.5
        )
        let transform = node.id == gumball.nodeID ? gumball.transform : node.transform
        let world = transform * Vec4(x: local.x, y: local.y, z: local.z, w: 1)
        guard abs(world.w) > FFMath.eps else { return nil }
        return Vec3(x: world.x / world.w, y: world.y / world.w, z: world.z / world.w)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                FFMetalViewportView(
                    camera: camera,
                    scene: displayScene,
                    mode: mode,
                    accessibilityIdentifier: metalIdentifier,
                    allowsCameraGestures: !gizmoDragging && !selection.isMarquee,
                    pickFilter: selection.filter,
                    onHover: { point in
                        measureTap.point = point
                        updateHover(point, viewport: paneSize)
                    },
                    onCameraChange: { updated in
                        camera = updated
                        onCameraChange(updated)
                    },
                    onPick: { result in
                        if isMeasuring {
                            // While the Measure tool is selected a tap is a
                            // point, not a selection. The pick is ignored so a
                            // measurement cannot move the Phase 17 selection.
                            addMeasurementPoint()
                            return
                        }
                        // Phase 14's pick becomes Phase 17's selection here.
                        // iPadOS has no Shift-click on touch, so the Multi
                        // chip is the extend contract the CI drives.
                        selection.click(
                            result?.nodeID,
                            extend: selection.isMultiSelect
                        )
                    },
                    onPerformance: onPerformance
                )

                FFSnapOverlay(markers: snapMarkers)

                if showsGumball, isMeasuring {
                    FFMeasurementOverlay(
                        session: measurement,
                        measurements: measurements,
                        camera: camera,
                        viewport: proxy.size,
                        unit: unit
                    )
                }

                if showsGumball, editableGumballNodeID != nil, !isMeasuring {
                    FFGumballOverlay(
                        session: $gumball,
                        camera: camera,
                        viewport: proxy.size,
                        selectionCentre: selectionCentre,
                        onDragStateChange: { gizmoDragging = $0 },
                        onCommitTransform: { transform, key in
                            if let nodeID = gumball.nodeID {
                                onCommitGizmoTransform(nodeID, transform, key)
                            }
                        },
                        onUndo: onUndoEdit
                    )
                }

                if showsGumball, selection.isMarquee {
                    FFMarqueeOverlay { box in
                        let ids = FFMarqueeSelection.nodeIDs(
                            in: box,
                            scene: selectionScene,
                            camera: camera,
                            viewport: Vec2(
                                x: Double(proxy.size.width),
                                y: Double(proxy.size.height)
                            ),
                            filter: selection.filter
                        )
                        selection.select(ids, extend: selection.isMultiSelect)
                    }
                }
            }
            // The per-viewport mode chip sits on the trailing edge, vertically
            // centred: away from the top tool strip, the bottom HUD, the gizmo
            // at the stone and the marquee's starting corners.
            .overlay(alignment: .trailing) {
                FFChip(
                    title: mode.shortLabel,
                    systemImage: mode.systemImage,
                    isSelected: mode != .shaded,
                    accessibilityIdentifier: "shell.viewport.mode.\(plan.id)"
                ) {
                    onCycleDisplayMode()
                }
                .accessibilityLabel("Display mode, \(mode.label)")
                .accessibilityValue(mode.label)
                .accessibilityHint("Cycles the display mode for this viewport")
                .padding(.trailing, FFSpace.xs)
            }
            // The card names the kinds and shows the live value. It sits above
            // the HUD strip so the value is readable while tapping.
            .overlay(alignment: .bottomLeading) {
                if showsGumball, isMeasuring {
                    FFMeasurementPanel(
                        session: measurement,
                        measurements: measurements,
                        unit: unit,
                        onClear: {
                            measurement.clear()
                            onClearMeasurements()
                        }
                    )
                    .padding(.leading, FFSpace.sm)
                    .padding(.bottom, 72)
                }
            }
            .onGeometryChange(for: CGSize.self) { geometry in
                geometry.size
            } action: { size in
                paneSize = size
            }
            // Markers are world points. Re-resolving on a camera change keeps
            // them under the same cursor after a zoom instead of leaving stale
            // screen coordinates behind.
            .onChange(of: camera) { _, _ in
                refreshSnapMarkers(viewport: paneSize)
            }
        .onChange(of: scene) { _, _ in
                // A document commit, undo or reopen replaces the scene. The
                // gizmo is live interaction state, so reseed it from the new
                // document transforms instead of keeping a stale matrix.
                guard !gizmoDragging else { return }
                if let nodeID = gumball.nodeID,
                   let node = scene.nodes.first(where: { $0.id == nodeID }) {
                    gumball.select(nodeID: nodeID, transform: node.transform)
                } else if let node = scene.nodes.first(where: {
                    selection.selectedIDs.contains($0.id) && !lockedNodeIDs.contains($0.id)
                }) {
                    gumball.select(nodeID: node.id, transform: node.transform)
                }
            }
        .onChange(of: measurements) { _, latest in
                measurement.replaceCommitted(latest)
            }
        }
        .onAppear(perform: configureGumball)
        .onChange(of: selection.selectedIDs) { _, ids in
            // A gizmo cannot outlive its selection or float over a node the
            // jeweller just hid or locked. Follow the primary editable
            // selection, or clear.
            if let nodeID = gumball.nodeID, !ids.contains(nodeID) {
                if let node = scene.nodes.first(where: {
                    ids.contains($0.id) && !lockedNodeIDs.contains($0.id)
                }) {
                    gumball.select(nodeID: node.id, transform: node.transform)
                } else {
                    gumball = FFGumballSession()
                }
            } else if gumball.nodeID == nil,
                      let node = scene.nodes.first(where: {
                          ids.contains($0.id) && !lockedNodeIDs.contains($0.id)
                      }) {
                gumball.select(nodeID: node.id, transform: node.transform)
            }
            refreshSnapMarkers(viewport: paneSize)
        }
        .onChange(of: lockedNodeIDs) { _, locked in
            // Locking the active layer retires a gizmo that was already on
            // screen, so the next drag cannot start an edit the session will
            // refuse. Unlocking brings it back for the same selection.
            if let nodeID = gumball.nodeID, locked.contains(nodeID) {
                gumball = FFGumballSession()
            } else if gumball.nodeID == nil,
                      let node = selectedNode,
                      node.isVisible,
                      !locked.contains(node.id) {
                gumball.select(nodeID: node.id, transform: node.transform)
            }
        }
        // The pane name is a label, not a floating badge. The bottom HUD already
        // names the layout and every pane, and a badge in the corner printed on
        // top of that HUD in the Phase 13 snapshots at 749 pt.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(plan.accessibilityIdentifier)
        .accessibilityLabel(plan.title)
    }

    private func configureGumball() {
        guard gumball.nodeID == nil,
              let node = selectedNode,
              node.isVisible,
              !lockedNodeIDs.contains(node.id)
        else { return }
        gumball.select(nodeID: node.id, transform: node.transform)
    }

    /// Resolves the last published hover sample through the snapping engine and
    /// appends it to the live measurement. A tap that finds no snap adds
    /// nothing, so a stray finger cannot create a point off the geometry.
    private func addMeasurementPoint() {
        guard let tap = measureTap.point, paneSize.width > 1, paneSize.height > 1 else { return }
        guard let point = FFMeasurementSnap.point(
            at: tap,
            scene: displayScene,
            camera: camera,
            viewport: Vec2(x: Double(paneSize.width), y: Double(paneSize.height))
        ) else { return }
        if let committed = measurement.add(point) {
            onCommitMeasurement(committed)
        }
        refreshSnapMarkers(viewport: paneSize)
    }

    private func updateHover(_ point: Vec2?, viewport: CGSize) {
        hoverPoint = point
        refreshSnapMarkers(viewport: viewport)
    }

    private func refreshSnapMarkers(viewport: CGSize) {
        guard let hoverPoint, viewport.width > 1, viewport.height > 1 else {
            snapMarkers = []
            return
        }
        snapMarkers = FFSnapHover.markers(
            hover: hoverPoint,
            scene: displayScene,
            selectedID: gumball.nodeID,
            reference: gizmoDragging ? gumball.pivot : nil,
            camera: camera,
            viewport: Vec2(x: Double(viewport.width), y: Double(viewport.height))
        )
    }
}

// MARK: - Inspector

private struct FFInspector: View {
    @Binding var bandWidth: String
    @Binding var lengthUnit: FFLengthUnit
    let scene: FFViewportScene
    let layers: [FFLayer]
    let currentLayerID: UUID?
    let layerCounts: [UUID: Int]
    @Binding var selection: FFSelectionState
    let onAddLayer: () -> Void
    let onSetCurrentLayer: (UUID) -> Void
    let onToggleLayerVisibility: (UUID) -> Void
    let onToggleLayerLock: (UUID) -> Void
    let onCycleLayerColor: (UUID) -> Void
    let onSelectLayer: (UUID) -> Void
    let onAssignToLayer: (UUID) -> Void
    let onCollapse: () -> Void

    private var selectedNodes: [FFRenderNode] {
        scene.nodes.filter { selection.selectedIDs.contains($0.id) }
    }

    private var currentLayer: FFLayer? {
        layers.first { $0.id == currentLayerID }
    }

    /// The three layer commands, shared by both `ViewThatFits` layouts so the
    /// identifiers and enabled rules cannot drift between breakpoints.
    @ViewBuilder
    private var layerCommandChips: some View {
        FFChip(
            title: "Add",
            systemImage: "plus",
            accessibilityIdentifier: "layer.add"
        ) {
            onAddLayer()
        }

        FFChip(
            title: "Select",
            systemImage: "square.dashed",
            accessibilityIdentifier: "layer.select"
        ) {
            if let currentLayerID { onSelectLayer(currentLayerID) }
        }
        .disabled(currentLayer == nil || currentLayer?.isVisible == false)

        FFChip(
            title: "Move",
            systemImage: "arrow.right.to.line",
            accessibilityIdentifier: "layer.assign"
        ) {
            if let currentLayerID { onAssignToLayer(currentLayerID) }
        }
        .disabled(selection.selectedIDs.isEmpty || currentLayer?.isLocked == true)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FFSpace.sm) {
                HStack(spacing: FFSpace.xs) {
                    Text("Inspector")
                        .font(FFType.section)
                        .foregroundStyle(FFPalette.textPrimary.color)

                    Spacer(minLength: 0)

                    Button(action: onCollapse) {
                        Image(systemName: "sidebar.trailing")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(FFPalette.textTertiary.color)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(FFPressStyle())
                    .accessibilityLabel("Hide inspector")
                }

                // Phase 20's layer panel. The session owns membership,
                // visibility, lock, colour and the current layer; this panel
                // only renders them and routes taps back to the session.
                FFPanel(
                    title: "Layers",
                    subtitle: "\(layers.count) layers",
                    trailing: currentLayer.map { "Current: \($0.name)" }
                ) {
                    // Phase 24's 44 pt target plus chip padding makes each
                    // command 68 pt wide, so the row needs 212 pt. The compact
                    // inspector's content box is narrower than that: keep the
                    // single row where it fits and stack the same three
                    // commands where it does not, instead of letting the
                    // column spill into the viewport.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: FFSpace.xxs) {
                            layerCommandChips
                        }

                        VStack(alignment: .leading, spacing: FFSpace.xxs) {
                            layerCommandChips
                        }
                    }

                    ForEach(Array(layers.enumerated()), id: \.element.id) { index, layer in
                        // The row and its icon controls are separate lines. The
                        // three icons at Phase 24's 44 pt minimum would leave
                        // no width for the row inside a 240 pt inspector, so
                        // the row keeps the full width and the icons sit below
                        // it. Every target stays 44×44 at every breakpoint.
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                onSetCurrentLayer(layer.id)
                            } label: {
                                HStack(spacing: FFSpace.xxs) {
                                    Circle()
                                        .stroke(
                                            layer.id == currentLayerID
                                                ? FFPalette.accent.color
                                                : FFPalette.textTertiary.color,
                                            lineWidth: 1.5
                                        )
                                        .background(
                                            Circle().fill(
                                                layer.id == currentLayerID
                                                    ? FFPalette.accent.color
                                                    : Color.clear
                                            )
                                        )
                                        .frame(width: 9, height: 9)

                                    Text(layer.name)
                                        .font(FFType.caption)
                                        .foregroundStyle(
                                            layer.isVisible
                                                ? FFPalette.textPrimary.color
                                                : FFPalette.textTertiary.color
                                        )
                                        .lineLimit(1)

                                    Spacer(minLength: FFSpace.xxs)

                                    Text("\(layerCounts[layer.id] ?? 0)")
                                        .font(FFType.monoSmall)
                                        .foregroundStyle(FFPalette.textTertiary.color)
                                }
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: FFHitTarget.minimum,
                                    alignment: .leading
                                )
                                // The row's blank middle is part of the target:
                                // a finger aiming at the row, not at the name
                                // glyph, must still make it current.
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(FFPressStyle())
                            .accessibilityIdentifier("layer.row.\(index)")
                            .accessibilityLabel("\(layer.name), \(layerCounts[layer.id] ?? 0) objects")
                            .accessibilityValue(
                                layer.isLocked ? "Locked" : (layer.isVisible ? "Visible" : "Hidden")
                            )

                            HStack(spacing: 2) {
                                layerIconButton(
                                    layer.isVisible ? "eye" : "eye.slash",
                                    label: "\(layer.name) visibility",
                                    identifier: "layer.visible.\(index)",
                                    isSelected: !layer.isVisible
                                ) {
                                    onToggleLayerVisibility(layer.id)
                                }

                                layerIconButton(
                                    layer.isLocked ? "lock.fill" : "lock.open",
                                    label: "\(layer.name) lock",
                                    identifier: "layer.lock.\(index)",
                                    isSelected: layer.isLocked
                                ) {
                                    onToggleLayerLock(layer.id)
                                }

                                Button {
                                    onCycleLayerColor(layer.id)
                                } label: {
                                    Circle()
                                        .fill(swatch(layer.color))
                                        .frame(width: 16, height: 16)
                                        .frame(
                                            width: FFHitTarget.minimum,
                                            height: FFHitTarget.minimum
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(FFPressStyle())
                                .accessibilityLabel("\(layer.name) colour")
                                .accessibilityIdentifier("layer.color.\(index)")
                            }
                        }
                    }

                    if let currentLayer {
                        Text(
                            "Current: \(currentLayer.name) · \(layerCounts[currentLayer.id] ?? 0) objects"
                                + (currentLayer.isLocked ? " · locked" : "")
                        )
                        .font(FFType.monoSmall)
                        .foregroundStyle(FFPalette.textTertiary.color)
                        .accessibilityIdentifier("layer.current")
                    }
                }

                // Phase 17's touch controls. iPadOS has no Shift-click on
                // touch and no modifier-click API, so Multi is the extend
                // contract; the CI drives it. Keeping them in the inspector
                // leaves the viewport's top strip free for the marquee's start
                // above the stone.
                FFPanel(title: "Select", subtitle: "Touch mode and pick filter") {
                    HStack(spacing: FFSpace.xxs) {
                        FFChip(
                            title: "Multi",
                            systemImage: "square.on.square",
                            isSelected: selection.isMultiSelect,
                            accessibilityIdentifier: "selection.multi"
                        ) {
                            selection.isMultiSelect.toggle()
                        }

                        FFChip(
                            title: "Box",
                            systemImage: "rectangle.dashed",
                            isSelected: selection.isMarquee,
                            accessibilityIdentifier: "selection.marquee"
                        ) {
                            selection.isMarquee.toggle()
                        }
                    }

                    HStack(spacing: FFSpace.xxs) {
                        FFChip(
                            title: "All",
                            isSelected: selection.filter == .all,
                            accessibilityIdentifier: "selection.filter.all"
                        ) {
                            selection.filter = .all
                        }

                        FFChip(
                            title: "Solid",
                            isSelected: selection.filter == .solid,
                            accessibilityIdentifier: "selection.filter.solid"
                        ) {
                            selection.filter = .solid
                        }
                    }

                    HStack(spacing: FFSpace.xxs) {
                        FFChip(
                            title: "Stone",
                            isSelected: selection.filter == .stone,
                            accessibilityIdentifier: "selection.filter.stone"
                        ) {
                            selection.filter = .stone
                        }

                        FFChip(
                            title: "Curve",
                            isSelected: selection.filter == .curve,
                            accessibilityIdentifier: "selection.filter.curve"
                        ) {
                            selection.filter = .curve
                        }
                    }
                }

                FFPanel(
                    title: "Selection",
                    subtitle: selection.summary(in: scene),
                    trailing: selection.visibilitySummary(in: scene)
                ) {
                    Text(selection.summary(in: scene))
                        .font(FFType.body)
                        .foregroundStyle(FFPalette.textPrimary.color)
                        .accessibilityIdentifier("selection.summary")

                    if selectedNodes.isEmpty {
                        Text("Nothing selected")
                            .font(FFType.caption)
                            .foregroundStyle(FFPalette.textTertiary.color)
                    } else {
                        ForEach(selectedNodes) { node in
                            FFListRow(title: node.name, trailing: node.kind.rawValue.capitalized)
                        }
                    }

                    VStack(alignment: .leading, spacing: FFSpace.xxs) {
                        HStack(spacing: FFSpace.xxs) {
                            FFChip(
                                title: "Isolate",
                                systemImage: "square.dashed",
                                isSelected: selection.isolatedIDs != nil,
                                accessibilityIdentifier: "selection.isolate"
                            ) {
                                selection.isolateSelection()
                            }

                            FFChip(
                                title: "Hide",
                                systemImage: "eye.slash",
                                accessibilityIdentifier: "selection.hide"
                            ) {
                                selection.hideSelection()
                            }
                        }

                        FFChip(
                            title: "Show all",
                            systemImage: "eye",
                            accessibilityIdentifier: "selection.showAll"
                        ) {
                            selection.showAll()
                        }
                    }

                    Text(selection.visibilitySummary(in: scene))
                        .font(FFType.monoSmall)
                        .foregroundStyle(FFPalette.textTertiary.color)
                        .accessibilityIdentifier("selection.visibility")
                }

                FFPanel(title: "Selection sets", subtitle: "\(selection.sets.count) saved") {
                    Button {
                        selection.saveSelectionSet()
                    } label: {
                        HStack(spacing: FFSpace.xxs) {
                            Image(systemName: "square.and.arrow.down")
                            Text("Save selection")
                        }
                        .font(FFType.caption)
                        .foregroundStyle(
                            selection.selectedIDs.isEmpty
                                ? FFPalette.textTertiary.color
                                : FFPalette.accent.color
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            FFPalette.raised.color,
                            in: RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
                        )
                    }
                    .buttonStyle(FFPressStyle())
                    .disabled(selection.selectedIDs.isEmpty)
                    .accessibilityIdentifier("selection.saveSet")

                    if selection.sets.isEmpty {
                        Text("No saved sets")
                            .font(FFType.caption)
                            .foregroundStyle(FFPalette.textTertiary.color)
                    } else {
                        ForEach(Array(selection.sets.enumerated()), id: \.element.id) { index, set in
                            Button {
                                selection.apply(set)
                            } label: {
                                FFListRow(title: set.name, trailing: "\(set.nodeIDs.count) objects")
                            }
                            .buttonStyle(FFPressStyle())
                            .accessibilityIdentifier("selection.set.\(index)")
                        }
                    }
                }

                FFPanel(title: "Dimensions", subtitle: "Millimetres") {
                    FFField(label: "Band width", value: $bandWidth, unit: "mm")
                    FFListRow(title: "Wall", trailing: "1.20 mm")

                    HStack(spacing: FFSpace.xxs) {
                        ForEach(FFLengthUnit.allCases) { unit in
                            FFChip(
                                title: unit.label,
                                isSelected: lengthUnit == unit,
                                accessibilityIdentifier: "shell.inspector.unit.\(unit.rawValue)"
                            ) {
                                lengthUnit = unit
                            }
                        }
                    }

                    FFListRow(
                        title: "Converted",
                        trailing: lengthUnit.formatted(millimetres: Double(bandWidth) ?? 18)
                    )
                    FFListRow(
                        title: "Ring size",
                        trailing: String(
                            format: "US %.1f",
                            FFRingSize(innerDiameterMM: 18).usSize
                        )
                    )
                }

                FFPanel(title: "Manufacturing") {
                    FFToast(message: "Wall check passed", kind: .success)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(AppIdentity.phaseLabel)
                        .foregroundStyle(FFPalette.textTertiary.color)
                    Text(FFSceneSizePolicy.summary)
                        .foregroundStyle(FFPalette.textTertiary.color)
                        .accessibilityIdentifier("shell.scenePolicy")
                }
                .font(FFType.caption)
                .padding(.horizontal, FFSpace.xs)
                .padding(.bottom, FFSpace.sm)
            }
            .padding(FFSpace.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(FFPalette.panel.color)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(FFPalette.separator.color)
                .frame(width: 1)
        }
    }

    private func layerIconButton(
        _ systemImage: String,
        label: String,
        identifier: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    isSelected ? FFPalette.accent.color : FFPalette.textSecondary.color
                )
                .frame(width: FFHitTarget.minimum, height: FFHitTarget.minimum)
                .background(
                    isSelected ? FFPalette.raised.color : Color.clear,
                    in: RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(FFPressStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func swatch(_ color: FFRGBA) -> Color {
        Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: 1)
    }
}
