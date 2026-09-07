import XCTest

final class DiagnosticsExporterTests: XCTestCase {
    func testDiagnosticSummaryOmitsLayoutNamesAndWindowTitles() throws {
        let window = makeSnapshot(id: "window-id", bundleIdentifier: "audit.app")
        var document = SlotStoreDocument(slots: [
            Slot(id: "layout-id", name: "PRIVATE_LAYOUT_NAME", windows: [window])
        ])
        document.settings.preferredLayoutsByTopology["PRIVATE_DISPLAY_UUID*"] = "layout-id"
        let summary = DiagnosticsExporter.summary(for: document)
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE_LAYOUT_NAME"))
        XCTAssertFalse(json.contains(window.windowTitle))
        XCTAssertFalse(json.contains("PRIVATE_DISPLAY_UUID"))
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
