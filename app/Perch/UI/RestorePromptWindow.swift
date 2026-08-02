import AppKit

private final class PromptHoverView: NSVisualEffectView {
    var onHoverChange: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class PromptButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class RestorePromptWindow: NSPanel {
    private static var currentPrompt: RestorePromptWindow?

    static var isShowing: Bool {
        currentPrompt != nil
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let onConfirm: @MainActor () -> Void
    private let onDismiss: @MainActor () -> Void
    private let onSupersededByRestore: @MainActor () -> Void
    private var dismissTask: Task<Void, Never>?
    private var dismissDuration: TimeInterval = 12
    private var didDeliverCompletion = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func show(
        layoutName: String,
        shortcutDescription: String?,
        duration: TimeInterval = 12,
        onConfirm: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void,
        onSupersededByRestore: @escaping @MainActor () -> Void
    ) {
        currentPrompt?.dismiss(animated: false, notifyDismissal: true)

        let prompt = RestorePromptWindow(
            layoutName: layoutName,
            shortcutDescription: shortcutDescription,
            onConfirm: onConfirm,
            onDismiss: onDismiss,
            onSupersededByRestore: onSupersededByRestore
        )
        currentPrompt = prompt
        prompt.present(duration: duration)
    }

    static func dismissCurrent() {
        currentPrompt?.dismiss(animated: true, notifyDismissal: true)
    }

    /// Used when a restore action itself supersedes the prompt (including the
    /// existing global layout shortcut). The action is a confirmation, not a
    /// prompt dismissal, but it already owns the restore call.
    static func dismissCurrentForRestore() {
        currentPrompt?.supersedeByRestore()
    }

    private init(
        layoutName: String,
        shortcutDescription: String?,
        onConfirm: @escaping @MainActor () -> Void,
        onDismiss: @escaping @MainActor () -> Void,
        onSupersededByRestore: @escaping @MainActor () -> Void
    ) {
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
        self.onSupersededByRestore = onSupersededByRestore

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        worksWhenModal = true
        level = .statusBar
        ignoresMouseEvents = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        setContent(layoutName: layoutName, shortcutDescription: shortcutDescription)
    }

    deinit {
        dismissTask?.cancel()
    }

    private func setContent(layoutName: String, shortcutDescription: String?) {
        let container = PromptHoverView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.onHoverChange = { [weak self] isHovering in
            guard let self else { return }
            if isHovering {
                dismissTask?.cancel()
                dismissTask = nil
            } else {
                scheduleDismissal()
            }
        }

        let iconView = NSImageView()
        iconView.image = NSImage(
            systemSymbolName: "macwindow.on.rectangle",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 21, weight: .medium))
        iconView.contentTintColor = .white
        iconView.setAccessibilityElement(false)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.stringValue = L10n.format(.restorePromptTitleFormat, layoutName)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setAccessibilityElement(true)
        titleLabel.setAccessibilityRole(.staticText)
        titleLabel.setAccessibilityLabel(titleLabel.stringValue)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)

        if let shortcutDescription, !shortcutDescription.isEmpty {
            let shortcutLabel = NSTextField(
                labelWithString: L10n.format(.restorePromptShortcutFormat, shortcutDescription)
            )
            shortcutLabel.font = .systemFont(ofSize: 12)
            shortcutLabel.textColor = NSColor.white.withAlphaComponent(0.7)
            shortcutLabel.lineBreakMode = .byTruncatingTail
            shortcutLabel.maximumNumberOfLines = 1
            textStack.addArrangedSubview(shortcutLabel)
        }

        let restoreButton = PromptButton(
            title: L10n.text(.restorePromptButton),
            target: self,
            action: #selector(confirmRestore)
        )
        restoreButton.bezelStyle = .rounded
        restoreButton.controlSize = .regular
        restoreButton.setButtonType(.momentaryPushIn)
        restoreButton.setContentHuggingPriority(.required, for: .horizontal)

        let closeButton = PromptButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil) ?? NSImage(),
            target: self,
            action: #selector(dismissTapped)
        )
        closeButton.isBordered = false
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.72)
        closeButton.toolTip = L10n.text(.restorePromptDismiss)
        closeButton.setAccessibilityLabel(L10n.text(.restorePromptDismiss))
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [iconView, textStack, restoreButton, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(10, after: restoreButton)

        container.addSubview(stack)
        contentView = container

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 170),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 13),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -13),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])

        layoutIfNeeded()
        setFrame(NSRect(origin: .zero, size: container.fittingSize), display: false)
    }

    private func present(duration: TimeInterval) {
        dismissDuration = max(duration, 0)
        positionOnBestScreen()
        alphaValue = 0
        orderFrontRegardless()

        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: titleLabel.stringValue,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
        scheduleDismissal()
    }

    private func scheduleDismissal() {
        dismissTask?.cancel()
        let nanoseconds = UInt64(dismissDuration * 1_000_000_000)
        dismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            self?.dismiss(animated: true, notifyDismissal: true)
        }
    }

    @objc private func confirmRestore() {
        guard !didDeliverCompletion else { return }
        didDeliverCompletion = true
        let completion = onConfirm
        dismiss(animated: true, notifyDismissal: false)
        completion()
    }

    @objc private func dismissTapped() {
        dismiss(animated: true, notifyDismissal: true)
    }

    private func supersedeByRestore() {
        guard !didDeliverCompletion else { return }
        didDeliverCompletion = true
        let completion = onSupersededByRestore
        dismiss(animated: true, notifyDismissal: false)
        completion()
    }

    private func dismiss(animated: Bool, notifyDismissal: Bool) {
        dismissTask?.cancel()
        dismissTask = nil

        if notifyDismissal, !didDeliverCompletion {
            didDeliverCompletion = true
            onDismiss()
        }

        guard animated else {
            finishDismissal()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor [weak self] in
                self?.finishDismissal()
            }
        }
    }

    private func finishDismissal() {
        orderOut(nil)
        if Self.currentPrompt === self {
            Self.currentPrompt = nil
        }
    }

    private func positionOnBestScreen() {
        let targetScreen = screen ?? NSApp.keyWindow?.screen ?? NSScreen.main
        guard let visibleFrame = targetScreen?.visibleFrame else { return }

        let origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.maxY - frame.height - 72
        )
        setFrameOrigin(origin)
    }
}
