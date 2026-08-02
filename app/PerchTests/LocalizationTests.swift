import XCTest

@MainActor
final class LocalizationTests: XCTestCase {
    func testSystemLanguageChoosesFirstSupportedPreferredLanguage() {
        let effectiveLanguage = AppLanguage.effectiveLanguage(
            selected: .system,
            preferredLanguages: ["fr-FR", "sk-SK", "en-US"]
        )

        XCTAssertEqual(effectiveLanguage, .slovak)
    }

    func testSystemLanguageFallsBackToEnglishWhenUnsupported() {
        let effectiveLanguage = AppLanguage.effectiveLanguage(
            selected: .system,
            preferredLanguages: ["fr-FR", "it-IT"]
        )

        XCTAssertEqual(effectiveLanguage, .english)
    }

    func testExplicitLanguageIgnoresPreferredLanguages() {
        let effectiveLanguage = AppLanguage.effectiveLanguage(
            selected: .german,
            preferredLanguages: ["cs-CZ"]
        )

        XCTAssertEqual(effectiveLanguage, .german)
    }

    func testSelectedLanguagePersistsAndPostsNotification() {
        let defaults = makeDefaults()
        let manager = LocalizationManager(
            userDefaults: defaults,
            preferredLanguagesProvider: { ["en-US"] }
        )
        let expectation = expectation(description: "language change notification")
        let observer = NotificationCenter.default.addObserver(
            forName: .perchLanguageDidChange,
            object: manager,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        manager.selectedLanguage = .spanish

        XCTAssertEqual(defaults.string(forKey: LocalizationManager.userDefaultsKey), "es")
        XCTAssertEqual(manager.selectedLanguage, .spanish)
        XCTAssertEqual(manager.effectiveLanguage, .spanish)
        wait(for: [expectation], timeout: 1)
    }

    func testSavedLanguageRestoresFromDefaults() {
        let defaults = makeDefaults()
        defaults.set("de", forKey: LocalizationManager.userDefaultsKey)

        let manager = LocalizationManager(
            userDefaults: defaults,
            preferredLanguagesProvider: { ["en-US"] }
        )

        XCTAssertEqual(manager.selectedLanguage, .german)
        XCTAssertEqual(manager.effectiveLanguage, .german)
    }

    func testInvalidSavedLanguageUsesSystemDefault() {
        let defaults = makeDefaults()
        defaults.set("fr", forKey: LocalizationManager.userDefaultsKey)

        let manager = LocalizationManager(
            userDefaults: defaults,
            preferredLanguagesProvider: { ["cs-CZ"] }
        )

        XCTAssertEqual(manager.selectedLanguage, .system)
        XCTAssertEqual(manager.effectiveLanguage, .czech)
    }

    func testLookupFallsBackToEnglishForMissingNonEnglishKey() {
        let catalog = LocalizationCatalog(translations: [
            .english: [.settingsWindowTitle: "Perch Settings"],
            .german: [:]
        ])
        let manager = LocalizationManager(
            userDefaults: makeDefaults(),
            preferredLanguagesProvider: { ["de-DE"] },
            catalog: catalog
        )

        manager.selectedLanguage = .german

        XCTAssertEqual(manager.text(.settingsWindowTitle), "Perch Settings")
    }

    func testDefaultCatalogHasEveryKeyForEverySupportedLanguage() {
        let missingPairs = AppLanguage.translatedCases.flatMap { language in
            LocalizationKey.allCases.compactMap { key in
                LocalizationCatalog.default.hasTranslation(for: key, language: language)
                    ? nil
                    : "\(language.rawValue):\(key.rawValue)"
            }
        }

        XCTAssertEqual(missingPairs, [])
    }

    func testKnownTranslationsResolveForEachLanguage() {
        let manager = LocalizationManager(
            userDefaults: makeDefaults(),
            preferredLanguagesProvider: { ["en-US"] }
        )

        manager.selectedLanguage = .czech
        XCTAssertEqual(manager.text(.generalTabTitle), "Obecné")

        manager.selectedLanguage = .slovak
        XCTAssertEqual(manager.text(.generalTabTitle), "Všeobecné")

        manager.selectedLanguage = .english
        XCTAssertEqual(manager.text(.generalTabTitle), "General")

        manager.selectedLanguage = .spanish
        XCTAssertEqual(manager.text(.generalTabTitle), "General")

        manager.selectedLanguage = .german
        XCTAssertEqual(manager.text(.generalTabTitle), "Allgemein")
    }

    func testSavedWindowCountFormattingUsesEffectiveLanguage() {
        let manager = LocalizationManager(
            userDefaults: makeDefaults(),
            preferredLanguagesProvider: { ["cs-CZ"] }
        )

        XCTAssertEqual(manager.savedWindowCount(1), "Uloženo 1 okno")
        XCTAssertEqual(manager.savedWindowCount(2), "Uložena 2 okna")
        XCTAssertEqual(manager.savedWindowCount(5), "Uloženo 5 oken")

        manager.selectedLanguage = .english
        XCTAssertEqual(manager.savedWindowCount(1), "Saved 1 window")
        XCTAssertEqual(manager.savedWindowCount(2), "Saved 2 windows")
    }

    func testRestoreSummaryFormattingIncludesOpenedApps() {
        let manager = LocalizationManager(
            userDefaults: makeDefaults(),
            preferredLanguagesProvider: { ["de-DE"] }
        )

        XCTAssertEqual(
            manager.restoreSummary(succeeded: 2, total: 3, openedAppCount: 1),
            "2/3 wiederhergestellt; 1 App geöffnet"
        )
        XCTAssertEqual(
            manager.restoreSummary(succeeded: 2, total: 3, openedAppCount: 2),
            "2/3 wiederhergestellt; 2 Apps geöffnet"
        )

        manager.selectedLanguage = .english
        XCTAssertEqual(
            manager.restoreSummary(succeeded: 2, total: 3, openedAppCount: 0),
            "Restored 2/3 windows"
        )
    }

    func testLocalizedErrorMessagesMapEngineErrors() {
        let manager = LocalizationManager(
            userDefaults: makeDefaults(),
            preferredLanguagesProvider: { ["en-US"] }
        )
        LocalizationManager.shared.selectedLanguage = .english
        _ = manager

        XCTAssertEqual(
            LocalizedErrorMessages.message(for: SlotEngineError.invalidLayoutName),
            "Layout name cannot be empty."
        )
        XCTAssertEqual(
            LocalizedErrorMessages.message(for: SlotEngineError.operationInProgress),
            "Another save or restore is already running."
        )
        XCTAssertEqual(
            LocalizedErrorMessages.message(for: WindowMoverError.accessibilityPermissionMissing),
            "Perch needs Accessibility access to read and move windows."
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "LocalizationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
