import Foundation

struct HotkeyRegistrationFailure: Equatable, Sendable {
    let binding: HotkeyBinding
    let description: String
    let status: OSStatus

    var displayString: String {
        binding.displayString
    }
}

/// Snapshot of the global shortcuts that are usable right now.
///
/// Configured bindings are deliberately not enough: Carbon can reject an
/// individual shortcut, or fail to install the event handler before any
/// shortcut is registered.
struct HotkeyRegistrationState: Equatable, Sendable {
    let registeredBindings: Set<HotkeyBinding>
    let registeredRestoreBindingsByLayoutID: [String: HotkeyBinding]
    let failures: [HotkeyRegistrationFailure]

    init(
        registeredBindings: Set<HotkeyBinding> = [],
        registeredRestoreBindingsByLayoutID: [String: HotkeyBinding] = [:],
        failures: [HotkeyRegistrationFailure] = []
    ) {
        self.registeredBindings = registeredBindings
        self.registeredRestoreBindingsByLayoutID = registeredRestoreBindingsByLayoutID
        self.failures = failures
    }

    func isRegistered(_ binding: HotkeyBinding?) -> Bool {
        guard let binding else { return false }
        return registeredBindings.contains(binding)
    }

    func registeredDisplayString(for binding: HotkeyBinding?) -> String? {
        guard let binding, isRegistered(binding) else { return nil }
        return binding.displayString
    }

    func registeredRestoreDisplayString(
        for layoutID: String,
        configuredBinding: HotkeyBinding?
    ) -> String? {
        guard let configuredBinding,
              isRegistered(configuredBinding),
              registeredRestoreBindingsByLayoutID[layoutID] == configuredBinding
        else {
            return nil
        }
        return configuredBinding.displayString
    }
}

/// Pure accumulator used by `HotkeyManager` after each Carbon registration
/// result, so failure/success bookkeeping is testable without registering real
/// global shortcuts in the unit-test process.
struct HotkeyRegistrationAccumulator: Sendable {
    private var registeredBindings = Set<HotkeyBinding>()
    private var registeredRestoreBindingsByLayoutID: [String: HotkeyBinding] = [:]
    private var failures: [HotkeyRegistrationFailure] = []

    mutating func recordSuccess(
        binding: HotkeyBinding,
        restoreLayoutID: String? = nil
    ) {
        registeredBindings.insert(binding)
        if let restoreLayoutID {
            registeredRestoreBindingsByLayoutID[restoreLayoutID] = binding
        }
    }

    mutating func recordFailure(_ failure: HotkeyRegistrationFailure) {
        failures.append(failure)
    }

    var state: HotkeyRegistrationState {
        HotkeyRegistrationState(
            registeredBindings: registeredBindings,
            registeredRestoreBindingsByLayoutID: registeredRestoreBindingsByLayoutID,
            failures: failures
        )
    }
}
