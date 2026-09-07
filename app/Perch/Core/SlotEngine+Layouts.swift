import Foundation

extension SlotEngine {
    /// Captures before creating the record, so permission/capture failures never
    /// leave a misleading empty layout behind.
    func createLayoutFromCurrentWindows(name: String) async throws -> Slot {
        let name = try validatedLayoutName(name)
        return try await performExclusiveWindowOperation {
            let capture = try await captureLayoutWindows()
            guard !capture.windows.isEmpty else { throw SlotEngineError.noWindowsToCapture }
            let slot = try await store.createLayout(
                name: name, windows: capture.windows, topology: capture.topology, savedAt: Date()
            )
            notifyDocumentDidChange()
            return slot
        }
    }

    func captureLayoutWindows() async throws -> (windows: [WindowSnapshot], topology: DisplayTopologyFingerprint?) {
        try Task.checkCancellation()
        let before = capturedTopologyProvider()
        let windows = try await snapshotter.captureCurrentWindows()
        try Task.checkCancellation()
        let after = capturedTopologyProvider()
        guard before == after else { throw SlotEngineError.displayConfigurationChanged }
        return (windows, after)
    }

    func setPreferredLayout(_ layoutID: String?, for topology: DisplayTopologyFingerprint) async throws {
        try await store.update { document in
            if let layoutID {
                let index = try Self.index(of: layoutID, in: document)
                guard !document.slots[index].windows.isEmpty,
                      document.slots[index].capturedTopology?.matchesIdentity(of: topology) == true else {
                    throw SlotEngineError.displayConfigurationChanged
                }
            }
            document.settings.preferredLayoutsByTopology[topology.identity] = layoutID
        }
        notifyDocumentDidChange()
    }

    func layoutHistory(layoutID: String? = nil) async throws -> [LayoutRevision] {
        try await store.layoutHistory(layoutID: layoutID)
    }

    func restoreRevision(id: String) async throws {
        try await store.restoreRevision(id: id)
        notifyDocumentDidChange()
    }

    func repairCandidates(for window: WindowSnapshot) async throws -> [WindowSnapshot] {
        try await performExclusiveWindowOperation {
            try await snapshotter.captureCurrentWindows().filter {
                $0.bundleIdentifier == window.bundleIdentifier
            }
        }
    }

    func reassignWindow(layoutID: String, windowID: String, to candidate: WindowSnapshot) async throws {
        try await performExclusiveWindowOperation {
            let live = try await snapshotter.captureCurrentWindows()
            let matching = live.filter {
                $0.bundleIdentifier == candidate.bundleIdentifier &&
                $0.processIdentifier == candidate.processIdentifier &&
                $0.cgWindowID == candidate.cgWindowID &&
                $0.accessibilityIdentifier == candidate.accessibilityIdentifier &&
                $0.windowTitle == candidate.windowTitle
            }
            // A user selection must still be representable by saved identity.
            // Identical titles without distinct CG/AX IDs cannot be repaired by
            // storing the same ambiguous metadata again.
            guard matching.count == 1 else { throw SlotEngineError.repairWindowUnavailable }
            let document = try await store.update { document in
                let index = try Self.index(of: layoutID, in: document)
                guard let windowIndex = document.slots[index].windows.firstIndex(where: { $0.id == windowID }),
                      document.slots[index].windows[windowIndex].bundleIdentifier == candidate.bundleIdentifier else {
                    throw SlotEngineError.repairWindowUnavailable
                }
                guard !document.slots[index].windows.contains(where: { other in
                    guard other.id != windowID, other.bundleIdentifier == candidate.bundleIdentifier,
                          other.processIdentifier == candidate.processIdentifier else { return false }
                    if let cgID = candidate.cgWindowID { return other.cgWindowID == cgID }
                    if let axID = candidate.accessibilityIdentifier, !axID.isEmpty {
                        return other.accessibilityIdentifier == axID
                    }
                    return other.windowTitle == candidate.windowTitle && other.frame == candidate.frame
                }) else { throw SlotEngineError.windowAlreadyAssigned }
                // Keep the saved destination, updating only the window identity.
                document.slots[index].windows[windowIndex].windowTitle = candidate.windowTitle
                document.slots[index].windows[windowIndex].processIdentifier = candidate.processIdentifier
                document.slots[index].windows[windowIndex].cgWindowID = candidate.cgWindowID
                document.slots[index].windows[windowIndex].accessibilityIdentifier = candidate.accessibilityIdentifier
                document.slots[index].windows[windowIndex].capturedAt = candidate.capturedAt
                document.slots[index].lastSaved = Date()
            }
            if let slot = document.slots.first(where: { $0.id == layoutID }) {
                restoreSession.didRepair(slot: slot, windowID: windowID)
            }
            notifyDocumentDidChange()
        }
    }
}
