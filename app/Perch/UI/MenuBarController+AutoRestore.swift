extension MenuBarController: AutoRestorePresenting {
    func showRestorePrompt(_ prompt: AutoRestorePrompt) -> Bool {
        RestorePromptWindow.show(
            layoutName: prompt.layoutName,
            shortcutDescription: prompt.shortcutDescription,
            duration: 12,
            onConfirm: prompt.onConfirm,
            onDismiss: prompt.onDismiss,
            onSupersededByRestore: prompt.onSupersededByRestore
        )
    }

    func invalidateRestorePrompt() {
        RestorePromptWindow.invalidateCurrent()
    }
}
