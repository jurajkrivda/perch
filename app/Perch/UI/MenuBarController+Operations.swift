import AppKit

extension MenuBarController {
    func performLayoutOperation(
        kind: LayoutOperationKind,
        _ operation: @escaping @MainActor () async throws -> SlotOperationResult?
    ) async {
        do {
            guard let result = try await operation() else {
                AppLog.menu.error("Layout operation unavailable because SlotEngine is missing")
                return
            }

            AppLog.menu.info("Layout operation finished for \(result.slotName, privacy: .private): \(result.succeeded)/\(result.total)")
            showToast(for: result, kind: kind)
            reloadSlots()
        } catch SlotEngineError.operationInProgress {
            AppLog.menu.info("Ignored layout operation because another one is still running")
        } catch SlotEngineError.restorePreflightRejected {
            AppLog.menu.info("Cancelled automatic restore because its preflight was rejected")
        } catch is CancellationError {
            AppLog.menu.info("Layout operation cancelled; some windows may already have moved")
        } catch {
            // The description can carry user content (saved window titles), so it stays private.
            AppLog.menu.error("Layout operation failed: \(error.localizedDescription, privacy: .private)")
            if isAccessibilityPermissionError(error) {
                await handleAccessibilityPermissionFailure()
            } else {
                ToastWindow.show(LocalizedErrorMessages.message(for: error))
            }
        }
    }

    private func handleAccessibilityPermissionFailure() async {
        switch AccessibilityManager.permissionState() {
        case .trusted:
            rebuildMenu()
            ToastWindow.show(L10n.text(.accessibilityGranted))
        case .pending:
            AccessibilityManager.logStatus(reason: "operation failed while pending")
            rebuildMenu()
            ToastWindow.show(L10n.text(.accessibilityPermissionPending))
        case .notRequested:
            let isTrusted = await AccessibilityManager.requestPermissionAndWait()
            rebuildMenu()
            ToastWindow.show(
                isTrusted
                ? L10n.text(.accessibilityGranted)
                : L10n.text(.accessibilityBannerRequiredMessage)
            )
        }
    }

    func accessibilityMenuTitle(for permissionState: AccessibilityManager.PermissionState) -> String {
        switch permissionState {
        case .trusted:
            return ""
        case .notRequested:
            return L10n.text(.grantAccessibilityPermission)
        case .pending:
            return L10n.text(.grantAccessibilityPermissionPending)
        }
    }

    private func showToast(for result: SlotOperationResult, kind: LayoutOperationKind) {
        switch kind {
        case .save:
            ToastWindow.showSavedWindowCount(result.succeeded)
        case .restore:
            ToastWindow.show(result.restoreSummary, symbolName: restoreToastSymbol(for: result))
        }
    }

    private func restoreToastSymbol(for result: SlotOperationResult) -> String {
        result.skipped == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func isAccessibilityPermissionError(_ error: Error) -> Bool {
        switch error {
        case WindowSnapshotterError.accessibilityPermissionMissing,
             WindowMoverError.accessibilityPermissionMissing:
            true
        default:
            false
        }
    }

}
