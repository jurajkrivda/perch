import AppKit
import Foundation
import UniformTypeIdentifiers

enum DiagnosticsExporter {
    struct Report: Codable {
        struct App: Codable {
            var version: String
            var build: String
            var bundleIdentifier: String
        }

        struct System: Codable {
            var generatedAt: Date
            var operatingSystemVersion: String
            var architecture: String
            var accessibilityTrusted: Bool
            var accessibilityPermissionState: String
            var launchAtLoginStatus: String
        }

        struct Display: Codable {
            var index: Int
            var x: Double
            var y: Double
            var width: Double
            var height: Double
            var isMain: Bool
        }

        struct StoredDocumentSummary: Codable {
            struct Layout: Codable {
                var id: String
                var windowCount: Int
                var lastSaved: Date?
                var hasCustomRestoreHotkey: Bool
            }

            var version: Int
            var layoutCount: Int
            var totalSavedWindowCount: Int
            var settings: PerchSettings
            var layouts: [Layout]
        }

        struct LiveWindowSnapshot: Codable {
            var status: String
            var windowCount: Int
            var appBundleIdentifiers: [String]
            var error: String?
        }

        var app: App
        var system: System
        var displays: [Display]
        var storedDocument: StoredDocumentSummary?
        var storedDocumentError: String?
        var lastAutomaticRestoreDecision: String
        var liveWindowSnapshot: LiveWindowSnapshot
    }

    @MainActor
    static func export() async throws -> URL {
        let report = await makeReport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Perch-Diagnostics-\(Self.fileTimestamp()).json"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            throw CocoaError(.userCancelled)
        }

        try data.write(to: url, options: .atomic)
        return url
    }

    @MainActor
    static func makeReport() async -> Report {
        let bundle = Bundle.main
        let info = bundle.infoDictionary
        let displayReports = DisplayManager.currentDisplays().enumerated().map { index, display in
            Report.Display(
                index: index,
                x: display.bounds.origin.x,
                y: display.bounds.origin.y,
                width: display.bounds.width,
                height: display.bounds.height,
                isMain: display.isMain
            )
        }

        let storedDocumentResult = await loadStoredDocument()
        let liveSnapshot = await captureLiveWindows()

        return Report(
            app: Report.App(
                version: info?["CFBundleShortVersionString"] as? String ?? "",
                build: info?["CFBundleVersion"] as? String ?? "",
                bundleIdentifier: bundle.bundleIdentifier ?? ""
            ),
            system: Report.System(
                generatedAt: Date(),
                operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: systemArchitecture(),
                accessibilityTrusted: AccessibilityManager.isTrusted(),
                accessibilityPermissionState: String(describing: AccessibilityManager.permissionState()),
                launchAtLoginStatus: LaunchAtLogin.diagnosticStatus
            ),
            displays: displayReports,
            storedDocument: storedDocumentResult.document.map(summary),
            storedDocumentError: storedDocumentResult.error,
            lastAutomaticRestoreDecision: AutoRestoreDiagnostics.lastDecision,
            liveWindowSnapshot: liveSnapshot
        )
    }

    @MainActor
    private static func loadStoredDocument() async -> (document: SlotStoreDocument?, error: String?) {
        do {
            return (try await SlotEngine.shared().currentDocument(), nil)
        } catch {
            return (nil, redactedErrorDescription(error))
        }
    }

    private static func captureLiveWindows() async -> Report.LiveWindowSnapshot {
        do {
            let windows = try await WindowSnapshotter().captureCurrentWindows()
            return Report.LiveWindowSnapshot(
                status: "ok",
                windowCount: windows.count,
                appBundleIdentifiers: uniqueBundleIdentifiers(in: windows),
                error: nil
            )
        } catch {
            return Report.LiveWindowSnapshot(
                status: "failed",
                windowCount: 0,
                appBundleIdentifiers: [],
                error: redactedErrorDescription(error)
            )
        }
    }

    static func summary(for document: SlotStoreDocument) -> Report.StoredDocumentSummary {
        Report.StoredDocumentSummary(
            version: document.version,
            layoutCount: document.slots.count,
            totalSavedWindowCount: document.slots.reduce(0) { $0 + $1.windows.count },
            settings: document.settings,
            layouts: document.slots.map { slot in
                Report.StoredDocumentSummary.Layout(
                    id: slot.id,
                    windowCount: slot.windows.count,
                    lastSaved: slot.lastSaved,
                    hasCustomRestoreHotkey: slot.restoreHotkey != nil
                )
            }
        )
    }

    /// Localized descriptions can contain paths or user-provided content.
    /// Export only an error domain and code, never NSError.userInfo.
    static func redactedErrorDescription(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) (\(error.code))"
    }

    private static func uniqueBundleIdentifiers(in windows: [WindowSnapshot]) -> [String] {
        Array(Set(windows.map(\.bundleIdentifier))).sorted()
    }

    private static func systemArchitecture() -> String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
