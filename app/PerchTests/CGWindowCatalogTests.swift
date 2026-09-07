import XCTest

final class CGWindowCatalogTests: XCTestCase {
    func testWindowIDAcceptsTheFullUnsignedRange() {
        XCTAssertEqual(CGWindowCatalog.uint32Value(NSNumber(value: 42)), 42)
        XCTAssertEqual(CGWindowCatalog.uint32Value(UInt32.max), UInt32.max)
        XCTAssertEqual(CGWindowCatalog.uint32Value(0), 0)
    }

    func testMalformedWindowIDIsRejectedRatherThanTruncatedOrWrapped() {
        for value: NSNumber in [
            NSNumber(value: -1), NSNumber(value: UInt64(UInt32.max) + 1),
            NSNumber(value: 1.5), NSNumber(value: Double.infinity),
            NSNumber(value: Double.nan)
        ] {
            XCTAssertNil(CGWindowCatalog.uint32Value(value))
        }
        XCTAssertNil(CGWindowCatalog.uint32Value("42"))
        XCTAssertNil(CGWindowCatalog.uint32Value(nil))
    }
}
