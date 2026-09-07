import Foundation

struct LayoutRevision: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let recordedAt: Date
    let layout: Slot
}

/// Valid previous layouts, kept separately from the live document so a damaged
/// store cannot destroy its history. Access is serialized by SlotStore.
struct LayoutHistory {
    static let maximumPerLayout = 10
    static let maximumTotal = 100

    let directoryURL: URL
    let fileManager: FileManager

    init(storeURL: URL, fileManager: FileManager) {
        directoryURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("Layout History", isDirectory: true)
        self.fileManager = fileManager
    }

    func revisions(layoutID: String? = nil) throws -> [LayoutRevision] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try fileManager.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ).compactMap { url in
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: url),
                  let revision = try? decoder.decode(LayoutRevision.self, from: data),
                  revision.id == url.deletingPathExtension().lastPathComponent,
                  UUID(uuidString: revision.id) != nil,
                  layoutID == nil || revision.layout.id == layoutID else { return nil }
            // Validate the saved content without positional shortcut conflicts.
            var layout = revision.layout
            layout.restoreHotkey = nil
            layout.restoreHotkeyDisabled = true
            guard (try? SlotStoreDocument(slots: [layout]).validate()) != nil else { return nil }
            return revision
        }.sorted {
            $0.recordedAt == $1.recordedAt ? $0.id > $1.id : $0.recordedAt > $1.recordedAt
        }
    }

    func preserveChanges(from previous: SlotStoreDocument, to next: SlotStoreDocument) throws {
        let changed = previous.slots.filter { old in
            guard old.lastSaved != nil || !old.windows.isEmpty else { return false }
            guard let new = next.slots.first(where: { $0.id == old.id }) else { return true }
            return old.windows != new.windows || old.capturedTopology != new.capturedTopology
        }
        guard !changed.isEmpty else { return }
        try fileManager.createDirectory(
            at: directoryURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let existing = try revisions()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        for layout in changed {
            // A failed live write may already have preserved this revision.
            if existing.first(where: { $0.layout.id == layout.id })?.layout == layout { continue }
            let revision = LayoutRevision(id: UUID().uuidString, recordedAt: Date(), layout: layout)
            let url = directoryURL.appendingPathComponent(revision.id).appendingPathExtension("json")
            try encoder.encode(revision).write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Only prune after the live write has committed. A failed write must never
    /// consume an old recovery point just to make room for the same data.
    func prune() throws {
        var counts: [String: Int] = [:]
        var kept = 0
        for revision in try revisions() {
            let count = counts[revision.layout.id, default: 0]
            if count < Self.maximumPerLayout && kept < Self.maximumTotal {
                counts[revision.layout.id] = count + 1
                kept += 1
            } else {
                let url = directoryURL.appendingPathComponent(revision.id).appendingPathExtension("json")
                try fileManager.removeItem(at: url)
            }
        }
    }
}
