import XCTest

final class DiagnosticsExporterTests: XCTestCase {
    func testDiagnosticSummaryOmitsLayoutNamesAndWindowTitles() throws {
        let window = makeSnapshot(id: "window-id", bundleIdentifier: "audit.app")
        let document = SlotStoreDocument(slots: [
            Slot(id: "layout-id", name: "PRIVATE_LAYOUT_NAME", windows: [window])
        ])
        let summary = DiagnosticsExporter.summary(for: document)
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE_LAYOUT_NAME"))
        XCTAssertFalse(json.contains(window.windowTitle))
        XCTAssertEqual(summary.totalSavedWindowCount, 1)
        XCTAssertEqual(summary.layouts.first?.id, "layout-id")
    }

    func testErrorExportDoesNotIncludeLocalizedDescriptionOrFilePaths() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 640, userInfo: [
            NSLocalizedDescriptionKey: "PRIVATE_WINDOW_TITLE",
            NSFilePathErrorKey: "/Users/private-user/private-document"
        ])
        XCTAssertEqual(DiagnosticsExporter.redactedErrorDescription(error), "NSCocoaErrorDomain (640)")
    }
}
