import Foundation

@MainActor
enum SingleInstanceLock {
    private static let lock = ProcessFileLock()

    static func acquire() -> Bool { lock.acquire(at: lockFileURL()) }
    static func release() { lock.release() }

    private static func lockFileURL() -> URL {
        if let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            return applicationSupportURL
                .appendingPathComponent("Perch", isDirectory: true)
                .appendingPathComponent("Perch.lock")
        }

        return FileManager.default.temporaryDirectory.appendingPathComponent("com.jurajkrivda.perch.lock")
    }

}
