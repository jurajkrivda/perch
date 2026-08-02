import AppKit

@MainActor
final class ToastWindow: NSPanel {
    private static var currentToast: ToastWindow?
    private static let confirmationSymbol = "checkmark.circle.fill"

    private let messageLabel = NSTextField(labelWithString: "")
    private var dismissTask: Task<Void, Never>?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func show(_ message: String, symbolName: String? = nil, duration: TimeInterval = 1.8) {
        currentToast?.dismiss(animated: false)

        let toast = ToastWindow(message: message, symbolName: symbolName)
        currentToast = toast
        toast.present(duration: duration)
    }

    static func showSavedWindowCount(_ count: Int, duration: TimeInterval = 1.8) {
        show(L10n.savedWindowCount(count), symbolName: Self.confirmationSymbol, duration: duration)
    }

    private init(message: String, symbolName: String?) {
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
        ignoresMouseEvents = true
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        setContent(message: message, symbolName: symbolName)
    }

    deinit {
        dismissTask?.cancel()
    }

    private func setContent(message: String, symbolName: String?) {
        let container = NSVisualEffectView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        messageLabel.stringValue = message
        messageLabel.alignment = symbolName == nil ? .center : .natural
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.maximumNumberOfLines = 2
        messageLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        messageLabel.textColor = .white
        messageLabel.setAccessibilityElement(true)
        messageLabel.setAccessibilityRole(.staticText)
        messageLabel.setAccessibilityLabel(message)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let symbolName,
           let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let configured = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            ) ?? symbol
            let imageView = NSImageView(image: configured)
            imageView.setAccessibilityElement(false)
            imageView.contentTintColor = .white
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.setContentHuggingPriority(.required, for: .horizontal)
            imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
            stack.addArrangedSubview(imageView)
        }
        stack.addArrangedSubview(messageLabel)

        container.addSubview(stack)
        contentView = container

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])

        layoutIfNeeded()
        let fittingSize = container.fittingSize
        setFrame(NSRect(origin: .zero, size: fittingSize), display: false)
    }

    private func present(duration: TimeInterval) {
        positionOnBestScreen()
        alphaValue = 0
        orderFrontRegardless()
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: messageLabel.stringValue,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }

        let nanoseconds = UInt64(max(duration, 0) * 1_000_000_000)
        dismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }

            self?.dismiss(animated: true)
        }
    }

    private func dismiss(animated: Bool) {
        dismissTask?.cancel()
        dismissTask = nil

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
        if Self.currentToast === self {
            Self.currentToast = nil
        }
    }

    private func positionOnBestScreen() {
        let targetScreen = screen ?? NSApp.keyWindow?.screen ?? NSScreen.main
        guard let visibleFrame = targetScreen?.visibleFrame else { return }

        let frameSize = frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - frameSize.width / 2,
            y: visibleFrame.maxY - frameSize.height - 72
        )

        setFrameOrigin(origin)
    }
}
