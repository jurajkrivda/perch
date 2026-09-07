import Foundation

func makeTemporaryStoreURL() -> (directoryURL: URL, fileURL: URL) {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("PerchTests-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directoryURL.appendingPathComponent("slots.json", isDirectory: false)
    return (directoryURL, fileURL)
}

func makeVersion1StoreData(hotkeys: [HotkeyBinding?]) throws -> Data {
    let slots: [[String: Any]] = hotkeys.enumerated().map { index, hotkey in
        var slot: [String: Any] = [
            "id": "layout-\(index)",
            "name": "Layout \(index)",
            "windows": []
        ]
        if let hotkey {
            slot["restoreHotkey"] = [
                "keyCode": NSNumber(value: hotkey.keyCode),
                "modifiers": NSNumber(value: hotkey.modifiers)
            ]
        }
        return slot
    }

    return try JSONSerialization.data(withJSONObject: [
        "version": 1,
        "settings": [
            "matchStrictness": "strict",
            "opensMissingApplicationsOnRestore": true,
            "retryAttempts": 5,
            "showsMenuBarLabel": false,
            "stabilizationTimeout": 4.5
        ],
        "slots": slots
    ])
}

func posixPermissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

func makeSnapshot(
    id: String = "window-1",
    bundleIdentifier: String = "com.example.App"
) -> WindowSnapshot {
    WindowSnapshot(
        id: id,
        bundleIdentifier: bundleIdentifier,
        windowTitle: "Example Window",
        frame: CodableRect(CGRect(x: 100, y: 100, width: 800, height: 600)),
        displayUUID: nil,
        displayLocalFrame: nil,
        windowRole: "AXWindow",
        processIdentifier: 1234,
        capturedAt: Date(timeIntervalSince1970: 1_779_190_400)
    )
}
