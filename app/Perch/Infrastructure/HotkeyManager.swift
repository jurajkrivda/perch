import Carbon
import Foundation

@MainActor
final class HotkeyManager {
    typealias SaveAction = @MainActor @Sendable (Int) -> Void
    typealias RestoreAction = @MainActor @Sendable (String) -> Void

    private var eventHandler: EventHandlerRef?
    private var registrations: [RegisteredHotkey] = []
    private(set) var registrationState = HotkeyRegistrationState()
    private var onSave: SaveAction?
    private var onRestore: RestoreAction?
    private let signature = FourCharCode("PRCH")

    init() {}

    func register(
        document: SlotStoreDocument,
        save: @escaping SaveAction,
        restore: @escaping RestoreAction
    ) {
        onSave = save
        onRestore = restore

        unregisterAll()

        guard installEventHandlerIfNeeded() else {
            return
        }

        var registrationAccumulator = HotkeyRegistrationAccumulator()
        for registration in registrations(for: document) {
            if let failure = register(registration) {
                registrationAccumulator.recordFailure(failure)
            } else {
                let restoreLayoutID: String? = if case let .restore(layoutID) = registration.action {
                    layoutID
                } else {
                    nil
                }
                registrationAccumulator.recordSuccess(
                    binding: registration.binding,
                    restoreLayoutID: restoreLayoutID
                )
            }
        }
        registrationState = registrationAccumulator.state
    }

    func unregisterAll() {
        for registration in registrations {
            UnregisterEventHotKey(registration.reference)
        }

        registrations.removeAll()
        registrationState = HotkeyRegistrationState()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func registrations(for document: SlotStoreDocument) -> [HotkeyRegistration] {
        document.slots.enumerated().flatMap { index, slot in
            var registrations: [HotkeyRegistration] = []

            if let saveHotkey = document.effectiveSaveHotkey(at: index) {
                registrations.append(HotkeyRegistration(
                    id: UInt32(index + 1),
                    binding: saveHotkey,
                    action: .save(slotIndex: index),
                    description: L10n.format(.hotkeyActionSaveFormat, slot.name)
                ))
            }

            if let restoreHotkey = document.effectiveRestoreHotkey(at: index) {
                registrations.append(HotkeyRegistration(
                    id: UInt32(index + 101),
                    binding: restoreHotkey,
                    action: .restore(layoutID: slot.id),
                    description: L10n.format(.hotkeyActionRestoreFormat, slot.name)
                ))
            }

            return registrations
        }
    }

    private func installEventHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else {
            return true
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installedHandler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &installedHandler
        )

        guard status == noErr, let installedHandler else {
            AppLog.hotkeys.error("Failed to install global hotkey event handler: \(status)")
            return false
        }

        eventHandler = installedHandler
        return true
    }

    private func register(_ hotkey: HotkeyRegistration) -> HotkeyRegistrationFailure? {
        let hotkeyID = EventHotKeyID(
            signature: signature,
            id: hotkey.id
        )
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.binding.keyCode,
            hotkey.binding.modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            AppLog.hotkeys.error("Failed to register global hotkey \(hotkey.description, privacy: .public): \(status)")
            return HotkeyRegistrationFailure(
                binding: hotkey.binding,
                description: hotkey.description,
                status: status
            )
        }

        registrations.append(RegisteredHotkey(hotkey: hotkey, reference: reference))
        return nil
    }

    fileprivate func handlePressedHotkey(id: UInt32, signature: OSType) {
        guard signature == self.signature,
              let registration = registrations.first(where: { $0.hotkey.id == id })
        else {
            return
        }

        switch registration.hotkey.action {
        case let .save(slotIndex):
            onSave?(slotIndex)
        case let .restore(layoutID):
            onRestore?(layoutID)
        }
    }
}

private let hotkeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event,
          let userData
    else {
        return OSStatus(eventNotHandledErr)
    }

    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )

    guard status == noErr else {
        return status
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        manager.handlePressedHotkey(id: hotkeyID.id, signature: hotkeyID.signature)
    }

    return noErr
}

private struct RegisteredHotkey {
    let hotkey: HotkeyRegistration
    let reference: EventHotKeyRef
}

private struct HotkeyRegistration {
    enum Action {
        case save(slotIndex: Int)
        case restore(layoutID: String)
    }

    let id: UInt32
    let binding: HotkeyBinding
    let action: Action
    let description: String
}

private func FourCharCode(_ string: StaticString) -> OSType {
    var result: OSType = 0

    for byte in string.utf8Start..<string.utf8Start + string.utf8CodeUnitCount {
        result = (result << 8) + OSType(byte.pointee)
    }

    return result
}
