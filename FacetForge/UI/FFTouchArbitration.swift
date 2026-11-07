import CoreGraphics
import UIKit

/// What kind of contact the tablet reports. A Pencil is explicit; a direct
/// contact is a finger unless its contact area is palm-sized. Palm rejection
/// uses both signals: a large direct contact is ignored, and every direct
/// contact that overlaps a Pencil is treated as the resting hand.
enum FFTouchKind: String, CaseIterable, Equatable, Sendable {
    case finger
    case pencil
    case palm

    /// A fingertip reports a major radius near ten points; a resting palm is
    /// several times larger. The threshold is deliberately conservative so a
    /// thumb press or a wide fingertip is still a finger.
    static let palmMajorRadius: CGFloat = 40

    static func classify(
        touchType: UITouch.TouchType,
        majorRadius: CGFloat
    ) -> FFTouchKind {
        switch touchType {
        case .pencil:
            return .pencil
        case .direct:
            #if targetEnvironment(simulator)
            // The simulator synthesises every direct touch with the same
            // contact shape, so there is no meaningful palm radius to read.
            // Device classification uses the real value; the physical record
            // is what proves it.
            return .finger
            #else
            return classifyDirectContact(majorRadius: majorRadius)
            #endif
        case .indirect, .indirectPointer:
            return .finger
        @unknown default:
            return .finger
        }
    }

    /// The device's contact-area rule, split out so the threshold can be
    /// tested on the simulator where `UITouch.majorRadius` is synthetic.
    static func classifyDirectContact(majorRadius: CGFloat) -> FFTouchKind {
        majorRadius >= palmMajorRadius ? .palm : .finger
    }

    init(touch: UITouch) {
        self = Self.classify(touchType: touch.type, majorRadius: touch.majorRadius)
    }
}

/// The only camera motion a direct-touch sequence may produce.
enum FFCameraGestureIntent: String, Equatable, Sendable {
    case orbit
    case pan
    case none
}

/// Phase 24's single gesture authority. It does not project a camera delta;
/// it answers whether the current contact set is allowed to orbit, pan, frame
/// or select. The coordinator still receives the delta from UIKit, but the
/// decision is made here so a Pencil, a palm or a resting hand can veto it.
///
/// Rules:
/// - one eligible finger orbits; two eligible fingers pan; three or more do
///   nothing, so a stray third contact cannot turn a gesture into a camera move;
/// - a palm never orbits, pans, frames or selects;
/// - a Pencil never moves the camera; it may select;
/// - every direct contact that begins before or during a Pencil contact is a
///   resting hand for the rest of that sequence, even after the Pencil lifts;
/// - an indirect pointer (trackpad) always pans, because it is not a touch.
struct FFTouchArbitration: Equatable, Sendable {
    private(set) var activeContacts: [Int: FFTouchKind] = [:]
    private(set) var suppressedDirectIDs: Set<Int> = []
    private(set) var directSuppressedThisSequence = false
    /// Counts touch sequences, not samples. The synthetic suite asserts that
    /// 100 scenarios produce 100 sequences, so a stale contact cannot silently
    /// join the next gesture.
    private(set) var sequenceCount = 0

    var isIdle: Bool { activeContacts.isEmpty }

    var pencilActive: Bool {
        activeContacts.values.contains(.pencil)
    }

    var palmActive: Bool {
        activeContacts.values.contains(.palm)
    }

    /// A finger that is not a palm and is not part of a resting hand.
    var eligibleFingerCount: Int {
        activeContacts.reduce(into: 0) { count, entry in
            guard entry.value == .finger else { return }
            guard !suppressedDirectIDs.contains(entry.key) else { return }
            count += 1
        }
    }

    /// Pinch, two-finger double tap and frame-all share this veto. They are
    /// camera commands, so a Pencil, a palm or a resting hand must not trigger
    /// them even when UIKit's recogniser sees two contacts.
    var cameraCommandBlocked: Bool {
        pencilActive || palmActive || !suppressedDirectIDs.isEmpty
    }

    mutating func begin(id: Int, kind: FFTouchKind) {
        if activeContacts.isEmpty {
            directSuppressedThisSequence = false
            suppressedDirectIDs.removeAll()
            sequenceCount += 1
        }

        if kind == .pencil {
            if activeContacts.values.contains(.finger) {
                directSuppressedThisSequence = true
            }
            for (contactID, contactKind) in activeContacts where contactKind == .finger {
                suppressedDirectIDs.insert(contactID)
            }
        }

        if kind == .finger, pencilActive {
            suppressedDirectIDs.insert(id)
            directSuppressedThisSequence = true
        }

        activeContacts[id] = kind
    }

    mutating func end(id: Int) {
        activeContacts.removeValue(forKey: id)
        suppressedDirectIDs.remove(id)
    }

    mutating func cancel(id: Int) {
        end(id: id)
    }

    mutating func reset() {
        activeContacts.removeAll()
        suppressedDirectIDs.removeAll()
        directSuppressedThisSequence = false
        sequenceCount = 0
    }

    /// `touchCount` is UIKit's recogniser count and is only a fallback for the
    /// first frame before the observer has recorded a contact. Once the
    /// observer knows the contact set, only its eligible fingers count.
    func cameraIntent(isIndirect: Bool, touchCount: Int) -> FFCameraGestureIntent {
        if isIndirect {
            return .pan
        }
        if pencilActive {
            return .none
        }
        if activeContacts.isEmpty {
            switch touchCount {
            case 1: return .orbit
            case 2: return .pan
            default: return .none
            }
        }
        if !suppressedDirectIDs.isEmpty {
            return .none
        }
        switch eligibleFingerCount {
        case 1: return .orbit
        case 2: return .pan
        default: return .none
        }
    }

    /// A direct tap that started before a Pencil landed is a resting hand and
    /// cannot select. The Pencil itself is always a valid selection contact.
    func selectionAllowed(kind: FFTouchKind) -> Bool {
        switch kind {
        case .palm:
            return false
        case .pencil:
            return true
        case .finger:
            return !pencilActive
                && !directSuppressedThisSequence
                && suppressedDirectIDs.isEmpty
        }
    }
}

/// Observes raw contact kinds without recognising anything. A `.possible`
/// gesture recogniser receives touches and does not cancel them, so adding this
/// to the Metal view does not steal a touch from the camera or pick recognisers.
/// It is deliberately not part of `cameraGestureRecognizers`: the pane may
/// disable camera gestures during a gizmo drag, but it still needs to know
/// which contacts remain down.
final class FFTouchContactObserver: UIGestureRecognizer {
    var onBegin: ((Int, FFTouchKind) -> Void)?
    var onEnd: ((Int) -> Void)?

    private var identifiers: [ObjectIdentifier: Int] = [:]
    private var nextIdentifier = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        for touch in touches {
            let key = ObjectIdentifier(touch)
            let identifier: Int
            if let existing = identifiers[key] {
                identifier = existing
            } else {
                nextIdentifier += 1
                identifiers[key] = nextIdentifier
                identifier = nextIdentifier
            }
            onBegin?(identifier, FFTouchKind(touch: touch))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        end(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        end(touches)
    }

    override func reset() {
        // The view can be dismantled mid-touch, in which case UIKit resets the
        // recogniser without a touchesEnded callback. Ending every tracked
        // contact here keeps the arbitration state from surviving into the
        // next viewport.
        for identifier in identifiers.values {
            onEnd?(identifier)
        }
        identifiers.removeAll()
        super.reset()
    }

    private func end(_ touches: Set<UITouch>) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard let identifier = identifiers.removeValue(forKey: key) else { continue }
            onEnd?(identifier)
        }
    }
}

/// A one-tap recogniser that remembers which kind of contact started it. The
/// plain `UITapGestureRecognizer` does not expose that after recognition, and a
/// direct tap that became a resting hand must be rejected by the pick handler.
final class FFTouchTapGestureRecognizer: UITapGestureRecognizer {
    private(set) var firstTouchKind: FFTouchKind = .finger

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first {
            firstTouchKind = FFTouchKind(touch: touch)
        }
        super.touchesBegan(touches, with: event)
    }
}
