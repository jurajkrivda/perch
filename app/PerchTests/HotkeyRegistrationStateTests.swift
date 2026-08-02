import XCTest

final class HotkeyRegistrationStateTests: XCTestCase {
    func testRegisteredDisplayStringRequiresSuccessfulRegistration() throws {
        let registered = try XCTUnwrap(HotkeyBinding.defaultRestore(for: 0))
        let unregistered = try XCTUnwrap(HotkeyBinding.defaultRestore(for: 1))
        let state = HotkeyRegistrationState(registeredBindings: [registered])

        XCTAssertEqual(
            state.registeredDisplayString(for: registered),
            registered.displayString
        )
        XCTAssertNil(state.registeredDisplayString(for: unregistered))
        XCTAssertNil(state.registeredDisplayString(for: nil))
    }

    func testFailedBindingIsNotTreatedAsRegistered() throws {
        let registered = try XCTUnwrap(HotkeyBinding.defaultRestore(for: 0))
        let failed = try XCTUnwrap(HotkeyBinding.defaultRestore(for: 1))
        let failure = HotkeyRegistrationFailure(
            binding: failed,
            description: "Restore Focus",
            status: -9_876
        )
        let state = HotkeyRegistrationState(
            registeredBindings: [registered],
            failures: [failure]
        )

        XCTAssertTrue(state.isRegistered(registered))
        XCTAssertFalse(state.isRegistered(failed))
        XCTAssertEqual(state.failures, [failure])
    }

    func testEmptyStateExposesNoActiveBindings() throws {
        let configured = try XCTUnwrap(HotkeyBinding.defaultRestore(for: 0))
        let state = HotkeyRegistrationState()

        XCTAssertTrue(state.registeredBindings.isEmpty)
        XCTAssertFalse(state.isRegistered(configured))
        XCTAssertNil(state.registeredDisplayString(for: configured))
    }

    func testRestoreHintRequiresBindingRegisteredForThatExactLayout() throws {
        let binding = try XCTUnwrap(HotkeyBinding.defaultRestore(for: 0))
        let state = HotkeyRegistrationState(
            registeredBindings: [binding],
            registeredRestoreBindingsByLayoutID: ["layout-a": binding]
        )

        XCTAssertEqual(
            state.registeredRestoreDisplayString(
                for: "layout-a",
                configuredBinding: binding
            ),
            binding.displayString
        )
        XCTAssertNil(state.registeredRestoreDisplayString(
            for: "layout-b",
            configuredBinding: binding
        ))
    }

    func testRestoreHintRejectsStaleBindingForSameLayout() throws {
        let oldBinding = try XCTUnwrap(HotkeyBinding.defaultRestore(for: 0))
        let newBinding = try XCTUnwrap(HotkeyBinding.defaultRestore(for: 1))
        let state = HotkeyRegistrationState(
            registeredBindings: [oldBinding],
            registeredRestoreBindingsByLayoutID: ["layout": oldBinding]
        )

        XCTAssertNil(state.registeredRestoreDisplayString(
            for: "layout",
            configuredBinding: newBinding
        ))
    }

    func testRestoreHintRejectsInconsistentMapWithoutActiveBinding() throws {
        let binding = try XCTUnwrap(HotkeyBinding.defaultRestore(for: 0))
        let state = HotkeyRegistrationState(
            registeredRestoreBindingsByLayoutID: ["layout": binding]
        )

        XCTAssertNil(state.registeredRestoreDisplayString(
            for: "layout",
            configuredBinding: binding
        ))
    }

    func testAccumulatorSeparatesSuccessfulRestoreFromFailedBinding() throws {
        let successful = try XCTUnwrap(HotkeyBinding.defaultRestore(for: 0))
        let failed = try XCTUnwrap(HotkeyBinding.defaultRestore(for: 1))
        let failure = HotkeyRegistrationFailure(
            binding: failed,
            description: "Restore Other",
            status: -9_876
        )
        var accumulator = HotkeyRegistrationAccumulator()

        accumulator.recordSuccess(binding: successful, restoreLayoutID: "work")
        accumulator.recordFailure(failure)
        let state = accumulator.state

        XCTAssertTrue(state.isRegistered(successful))
        XCTAssertFalse(state.isRegistered(failed))
        XCTAssertEqual(state.registeredRestoreBindingsByLayoutID, ["work": successful])
        XCTAssertEqual(state.failures, [failure])
    }
}
