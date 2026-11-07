import Foundation
import UIKit

/// Turns a snapped gizmo translation into at most one haptic per detent.
///
/// The driver is pure so the rule can be tested without a device: it tracks
/// the quantised translation at the start of a drag and returns `true` only
/// when a later sample lands on a different snap step. The 0.1 mm snap is
/// deliberately below the haptic floor; firing on a tenth of a millimetre
/// would buzz continuously rather than mark a detent.
struct FFSnapHapticDriver: Equatable, Sendable {
    static let minimumHapticStep = 0.5

    private var lastStep: [Int]?

    mutating func begin(transform: Mat4, step: Double) {
        lastStep = Self.key(transform: transform, step: step)
    }

    mutating func update(transform: Mat4, step: Double) -> Bool {
        guard step >= Self.minimumHapticStep else {
            lastStep = nil
            return false
        }
        guard let key = Self.key(transform: transform, step: step) else {
            lastStep = nil
            return false
        }
        guard key != lastStep else { return false }
        lastStep = key
        return true
    }

    mutating func reset() {
        lastStep = nil
    }

    private static func key(transform: Mat4, step: Double) -> [Int]? {
        guard step > 0, step.isFinite else { return nil }
        let values = [transform.m03, transform.m13, transform.m23]
        guard values.allSatisfy({ $0.isFinite }) else { return nil }
        return values.map { Int(($0 / step).rounded()) }
    }
}

/// One light impact per snap detent. The generator is main-actor isolated;
/// `assumeIsolated` keeps the call sites (SwiftUI gesture closures) free of an
/// actor hop while still proving they run on the main thread. A drag gesture
/// always does.
enum FFSnapHaptics {
    @MainActor
    private static let generator = UIImpactFeedbackGenerator(style: .light)

    static func prepare() {
        MainActor.assumeIsolated {
            generator.prepare()
        }
    }

    static func fire() {
        MainActor.assumeIsolated {
            generator.impactOccurred()
        }
    }
}
