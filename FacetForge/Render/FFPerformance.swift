import Foundation
import os
import SwiftUI

/// Phase 24's ProMotion rule. A 120 Hz iPad gets 120; a 60 Hz iPad or a
/// simulator that reports no usable maximum stays at 60; a pathological
/// report above the panel ceiling is clamped rather than trusted.
enum FFDisplayPacing {
    static let minimumFramesPerSecond = 60
    static let maximumFramesPerSecond = 120

    static func preferredFramesPerSecond(maximumFramesPerSecond: Int?) -> Int {
        guard let maximum = maximumFramesPerSecond,
              maximum >= minimumFramesPerSecond
        else { return minimumFramesPerSecond }
        return min(maximum, maximumFramesPerSecond)
    }
}

/// What one encoded render pass submitted. The renderer increments these at
/// each draw call, so the numbers the overlay shows are the frame that reached
/// Metal rather than a parallel estimate. Line draws count as draw calls and
/// contribute no triangles.
struct FFRenderCounters: Equatable, Sendable {
    private(set) var drawCalls = 0
    private(set) var triangles = 0

    mutating func recordTriangles(_ count: Int) {
        drawCalls += 1
        triangles += max(0, count)
    }

    mutating func recordLines() {
        drawCalls += 1
    }
}

/// The numbers Phase 21's HUD overlay shows, in one value. FPS and frame time
/// come from the renderer's rolling statistics; draw calls and triangles from
/// the counters of the last encoded pass; memory headroom from the OS; thermal
/// state from `ProcessInfo`.
struct FFPerformanceReport: Equatable, Sendable {
    var fps: Double = 0
    var frameMilliseconds: Double = 0
    var drawCalls: Int = 0
    var triangles: Int = 0
    var availableMemoryBytes: UInt64 = 0
    var thermalState: ProcessInfo.ThermalState = .nominal

    /// The OS figure the row names: the memory this process can still allocate
    /// before jetsam, not total device memory. The API returns 0 when it has no
    /// limit to report — which is what the simulator does — so that case falls
    /// back to physical memory instead of printing a misleading zero. On a
    /// device the first branch is the headroom the overlay promises.
    static func availableMemory() -> UInt64 {
        let headroom = UInt64(os_proc_available_memory())
        guard headroom == 0 else { return headroom }
        return ProcessInfo.processInfo.physicalMemory
    }

    static func current(
        statistics: FFFrameStatistics,
        counters: FFRenderCounters,
        processInfo: ProcessInfo = .processInfo
    ) -> FFPerformanceReport {
        FFPerformanceReport(
            fps: statistics.averageFPS,
            frameMilliseconds: statistics.lastFrameMilliseconds,
            drawCalls: counters.drawCalls,
            triangles: counters.triangles,
            availableMemoryBytes: availableMemory(),
            thermalState: processInfo.thermalState
        )
    }

    var fpsLabel: String {
        fps > 0 ? String(format: "%.0f fps", fps) : "starting"
    }

    var frameLabel: String {
        String(format: "%.1f ms", frameMilliseconds)
    }

    /// Binary units, because the value is a memory budget rather than a disk
    /// size. A gigabyte-and-up budget reads in GB with one decimal.
    var memoryLabel: String {
        let gib = Double(availableMemoryBytes) / 1_073_741_824
        if gib >= 1 {
            return String(format: "%.1f GB", gib)
        }
        return String(format: "%.0f MB", Double(availableMemoryBytes) / 1_048_576)
    }

    var thermalLabel: String {
        switch thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    var accessibilitySummary: String {
        "Performance overlay, FPS \(fpsLabel), frame \(frameLabel), "
            + "draw calls \(drawCalls), \(triangles) triangles, "
            + "memory \(memoryLabel), thermal \(thermalLabel)"
    }
}

extension FFMetalViewportRenderer {
    /// One report from the frame that just finished. The coordinator publishes
    /// it twice a second; sampling memory and thermal there keeps an OS call
    /// out of the per-frame path.
    var performanceReport: FFPerformanceReport {
        FFPerformanceReport.current(
            statistics: statistics,
            counters: lastCounters
        )
    }
}

/// A compact readout above the viewport HUD. It is a passive overlay: the HUD
/// chip toggles it, and it never swallows a touch meant for the scene.
struct FFPerformanceOverlay: View {
    let report: FFPerformanceReport

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Performance")
                .font(FFType.caption)
                .foregroundStyle(FFPalette.textSecondary.color)

            row("FPS", report.fpsLabel)
            row("Frame", report.frameLabel)
            row("Draw calls", "\(report.drawCalls)")
            row("Triangles", "\(report.triangles)")
            row("Memory", report.memoryLabel)
            row("Thermal", report.thermalLabel)
        }
        .padding(FFSpace.xs)
        .frame(minWidth: 148, alignment: .leading)
        .background(
            FFPalette.panel.color,
            in: RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: FFRadius.sm, style: .continuous)
                .stroke(FFPalette.separator.color, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("hud.performance.overlay")
        .accessibilityLabel(report.accessibilitySummary)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: FFSpace.sm) {
            Text(title)
                .foregroundStyle(FFPalette.textTertiary.color)

            Spacer(minLength: FFSpace.xs)

            Text(value)
                .foregroundStyle(FFPalette.textPrimary.color)
        }
        .font(FFType.monoSmall)
    }
}
