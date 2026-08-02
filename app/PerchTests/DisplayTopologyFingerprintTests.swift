import CoreGraphics
import Foundation
import XCTest

final class DisplayTopologyFingerprintTests: XCTestCase {
    func testIdentityIsIndependentOfDisplayOrder() {
        let first = DisplayTopologyFingerprint(displays: [
            display(id: 2, uuid: "display-b", x: 1440, isMain: false),
            display(id: 1, uuid: "display-a", x: 0, isMain: true)
        ])
        let second = DisplayTopologyFingerprint(displays: [
            display(id: 1, uuid: "display-a", x: 0, isMain: true),
            display(id: 2, uuid: "display-b", x: 1440, isMain: false)
        ])

        XCTAssertEqual(first.identity, "display-a*|display-b")
        XCTAssertEqual(first.identity, second.identity)
        XCTAssertTrue(first.matchesIdentity(of: second))
    }

    func testIdentityChangesWhenMainDisplayChanges() {
        let first = DisplayTopologyFingerprint(displays: [
            display(id: 1, uuid: "display-a", x: 0, isMain: true),
            display(id: 2, uuid: "display-b", x: 1440, isMain: false)
        ])
        let second = DisplayTopologyFingerprint(displays: [
            display(id: 1, uuid: "display-a", x: 0, isMain: false),
            display(id: 2, uuid: "display-b", x: 1440, isMain: true)
        ])

        XCTAssertNotEqual(first.identity, second.identity)
        XCTAssertFalse(first.matchesIdentity(of: second))
    }

    func testIdentityIgnoresBoundsChanges() {
        let original = DisplayTopologyFingerprint(displays: [
            display(id: 1, uuid: "display-a", x: 0, width: 1440, isMain: true),
            display(id: 2, uuid: "display-b", x: 1440, width: 1920, isMain: false)
        ])
        let renegotiated = DisplayTopologyFingerprint(displays: [
            display(id: 1, uuid: "display-a", x: 1, width: 1439, isMain: true),
            display(id: 2, uuid: "display-b", x: 1441, width: 1919, isMain: false)
        ])

        XCTAssertNotEqual(original, renegotiated)
        XCTAssertEqual(original.identity, renegotiated.identity)
        XCTAssertTrue(original.matchesIdentity(of: renegotiated))
    }

    func testCodableRoundTripPreservesFingerprint() throws {
        let fingerprint = DisplayTopologyFingerprint(displays: [
            display(id: 2, uuid: "display-b", x: -1920, width: 1920, isMain: false),
            display(id: 1, uuid: "display-a", x: 0, width: 1512, isMain: true)
        ])

        let data = try JSONEncoder().encode(fingerprint)
        let decoded = try JSONDecoder().decode(DisplayTopologyFingerprint.self, from: data)

        XCTAssertEqual(decoded, fingerprint)
        XCTAssertEqual(decoded.identity, "display-a*|display-b")
        XCTAssertEqual(Set([fingerprint, decoded]).count, 1)
    }

    func testTopologyFingerprintRejectsEmptyOrPartiallyMappedActiveDisplays() {
        let mappedDisplay = display(
            id: 1,
            uuid: "display-a",
            x: 0,
            isMain: true
        )

        XCTAssertNil(DisplayManager.topologyFingerprint(
            displays: [],
            activeDisplayCount: 0
        ))
        XCTAssertNil(DisplayManager.topologyFingerprint(
            displays: [mappedDisplay],
            activeDisplayCount: 2
        ))
        XCTAssertEqual(
            DisplayManager.topologyFingerprint(
                displays: [mappedDisplay],
                activeDisplayCount: 1
            )?.identity,
            "display-a*"
        )
    }

    private func display(
        id: CGDirectDisplayID,
        uuid: String,
        x: CGFloat,
        width: CGFloat = 1440,
        isMain: Bool
    ) -> DisplayInfo {
        DisplayInfo(
            id: id,
            uuid: uuid,
            bounds: CGRect(x: x, y: 0, width: width, height: 900),
            isMain: isMain
        )
    }
}
