import CryptoKit
import SwiftUI
import XCTest
@testable import FacetForge

/// Pixel digests for `FFComponentFixtures`. The first run fails with the
/// recorded values in the test log; those values are then committed here so
/// later changes are compared against a real rendering.
enum SnapshotBaseline {
    // ImageRenderer output is host-architecture-dependent, so each simulator
    // architecture keeps its own recorded digests. A visible design change
    // still has to be reviewed and updated in both tables.
    static let arm64Hashes: [String: String] = [
        "button": "6c8b25966b097ea61660e2f13ebc0f783f2a9778afdf3b3ccf9474f941ee356b",
        "chip": "f4cdbbc995e5c90b56671ba9c0e1bd395176ee5e38ea733f75be965bd91c3c93",
        "empty-state": "de0a9fa4c068f2d61cbcc948bfc7330782793f23c328bdb8f62b44872d2bfb16",
        // Phase 24 pads the text box to a 44 pt target, which moves the
        // glyphs by a subpixel inside the capsule. Re-recorded from the arm64
        // gate run 42402521613.
        "field": "2073620f6772cdd61a9f07b87a58b6866a5075249e3b3ce7e348aacd84fd5c43",
        "list-row": "bf41d3027b5de69138b6e98466a7cf086143f7784e650d05df4c83903a37fc81",
        "panel": "257075d5e08ee458c3bd27c71629c302f043cc60afb10b6a67cbf79a04a0fdd9",
        "segmented": "28026aa57b65f2201a2e5500baa0629bfb268a07ab09dd876d35acb118f05176",
        "sheet": "ded23fd148ecf36f47eb9cc231b0d8ae926bc9fbbd2a6228f59af0f76277b4f2",
        "slider": "cb23dbdf54e8465d4350900c9ed56ed5476b0d57766419df9a6f31024ec10f08",
        "toast": "710e3439fd4ce3bb2eef31a6e0ea0acd25e152273465f7cb1c20b029c849cbc5",
        "toolbar": "55abe9f237655f0878edcba930712a44cee00b357eba423ea4b87e701e26f0d4",
        "tooltip": "ecb34488b8c9fb3b06e9d90bc8272a877a457a74a817ab3a679cfe7d519f4d87",
    ]

    // Recorded by the macos-26-intel gate on 2026-11-06 (run 42257558856).
    // Every value is a digest of the same committed fixture, not a new render.
    // "field" was the one value that predated Phase 24's 44 pt text box: no
    // Intel gate had rendered that change until the Phase 55 gate (run
    // 43519068321, head 8c4725d) became the first, and it recorded exactly the
    // value below. That run is the Intel table's re-record for "field", so the
    // two tables now describe the same source.
    static let x86_64Hashes: [String: String] = [
        "button": "a0c17c6dfc5c7b68a0d4e64e8dd7e88cadcbac7774bd8404b1c80bf010ffdf78",
        "chip": "1d7a26f25fe6eb9c310c4c9275bea081f785a6b12a06d84e9c90c9d99658cbba",
        "empty-state": "df29c36f26b456aa8d1a3b470e2bbc623ea571cca79cb95982e9edea0437eb81",
        "field": "d7e36262e7c298e7c3a90a37b55ba79b1d5195b7cfba6a2dc0791021d09fe038",
        "list-row": "12f9dbd3b446b64e9c1942fe51b83547740899375ba10a651f69b7e138a806e3",
        "panel": "3cf8b0b8ceb7fae154d20e2d2e5227e4d45f7409b96694f7de2004744305fd90",
        "segmented": "28539e5e44fd6997ace2cf86c0e53d22bc59925db50f16bf5c1f16bbfd8c7f7c",
        "sheet": "558c3400b524e4570b532e0e3604f84877769a071f47ee82f9730a6363c4d777",
        "slider": "e86875a40dd22f5c6936c4f6f13d6e6e4d79df9d955e1f1607096131ddb35ff1",
        "toast": "1f2ec1b0592a25731ad7613ca3067d8494db662ba0a3b2d296710097fb8c7f93",
        "toolbar": "a3ba7cf9cabf522615d7c0356002a0d8b9ffb5b065cb5f47d493dc7998c42884",
        "tooltip": "61ee7f4502920be4c0ee058c704f234ec12cb0063f243f712852f58ba2d8a1d5",
    ]

    static var hashes: [String: String] {
        #if arch(x86_64)
        return x86_64Hashes
        #else
        return arm64Hashes
        #endif
    }
}

@MainActor
final class ComponentSnapshotTests: XCTestCase {
    func testComponentSnapshotsMatchTheRecordedBaseline() {
        var recorded: [String: String] = [:]
        var failures: [String] = []

        for item in FFComponentFixtures.cases {
            let content = item.view
                .frame(width: item.size.width, height: item.size.height)
                .background(FFPalette.canvas.color)
                .environment(\.colorScheme, .dark)

            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            renderer.isOpaque = true
            renderer.proposedSize = ProposedViewSize(width: item.size.width, height: item.size.height)

            guard let image = renderer.uiImage, let png = image.pngData() else {
                failures.append("\(item.id): ImageRenderer produced no PNG")
                continue
            }

            let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            recorded[item.id] = digest

            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "component-\(item.id)"
            attachment.lifetime = .keepAlways
            add(attachment)

            if let expected = SnapshotBaseline.hashes[item.id], expected != digest {
                failures.append("\(item.id): expected \(expected), got \(digest)")
            } else if SnapshotBaseline.hashes[item.id] == nil {
                failures.append("\(item.id): no committed baseline")
            }
        }

        print("SNAPSHOT_MANIFEST_BEGIN")
        for id in recorded.keys.sorted() {
            print("SNAPSHOT \(id) \(recorded[id]!)")
        }
        print("SNAPSHOT_MANIFEST_END")

        if SnapshotBaseline.hashes.isEmpty {
            XCTFail("Snapshot baseline is empty. Commit the SNAPSHOT lines from this run into SnapshotBaseline.hashes.")
        } else {
            let missing = Set(SnapshotBaseline.hashes.keys).subtracting(recorded.keys)
            if !missing.isEmpty {
                failures.append("stale baselines: \(missing.sorted().joined(separator: ", "))")
            }
            XCTAssertTrue(
                failures.isEmpty,
                "Component snapshots changed:\n" + failures.joined(separator: "\n")
            )
        }
    }
}
