import Foundation

struct StoreRecoveryNotice: Equatable, Sendable {
    let files: [URL]
}

/// Discovers preserved originals, including files quarantined by older builds.
/// SlotStore serializes access. Acknowledgement only renames the preserved
/// file; it never deletes its contents or hides a later recovery incident.
struct StoreRecoveryFiles {
    let storeURL: URL
    let fileManager: FileManager

    func pendingNotice() throws -> StoreRecoveryNotice? {
        let directory = storeURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: directory.path) else { return nil }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let files = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)
        ).filter { url in
            let prefix = storeURL.lastPathComponent + ".corrupt-"
            guard url.lastPathComponent.hasPrefix(prefix),
                  UUID(uuidString: String(url.lastPathComponent.dropFirst(prefix.count))) != nil
            else { return false }
            let values = try url.resourceValues(forKeys: keys)
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        return files.isEmpty ? nil : StoreRecoveryNotice(files: files)
    }

    func acknowledge(_ notice: StoreRecoveryNotice) throws {
        let pendingFiles = Set(try pendingNotice()?.files ?? [])
        for file in notice.files where pendingFiles.contains(file) {
            try fileManager.moveItem(
                at: file, to: file.appendingPathExtension("acknowledged")
            )
        }
    }
}
