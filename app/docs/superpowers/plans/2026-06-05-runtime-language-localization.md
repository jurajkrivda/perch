# Runtime Language Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Czech, Slovak, English, Spanish, and German UI language support with a Settings picker, system-language detection, and immediate runtime switching.

**Architecture:** Introduce a small app-owned localization layer in `Perch/Infrastructure/Localization` instead of relying on bundle language switching. SwiftUI settings screens observe a shared `LocalizationManager`; AppKit menu/toast code reads from the same manager and rebuilds on a language-change notification.

**Tech Stack:** Swift 6, SwiftUI Observation, AppKit, XCTest, XcodeGen, macOS 14.

---

## File Structure

- Create `Perch/Infrastructure/Localization/AppLanguage.swift`: supported languages, display names, and preferred-language detection.
- Create `Perch/Infrastructure/Localization/LocalizationKey.swift`: enum of user-facing string keys.
- Create `Perch/Infrastructure/Localization/LocalizationCatalog.swift`: in-code translation table and English fallback lookup.
- Create `Perch/Infrastructure/Localization/LocalizationManager.swift`: observable selected language, `UserDefaults` persistence, notification posting, and formatted string helpers.
- Create `Perch/Infrastructure/Localization/L10n.swift`: convenience accessors for existing AppKit code paths.
- Create `PerchTests/LocalizationTests.swift`: unit coverage for detection, persistence, fallback, key coverage, and count formatting.
- Modify `project.yml`: add `Perch/Infrastructure/Localization` to the `PerchTests` source list.
- Regenerate `Perch.xcodeproj/project.pbxproj` with XcodeGen after new files and `project.yml` changes.
- Modify UI and app files:
  - `Perch/PerchApp.swift`
  - `Perch/Infrastructure/LaunchAtLogin.swift`
  - `Perch/Core/SlotEngine.swift`
  - `Perch/Core/WindowMover.swift`
  - `Perch/Core/WindowSnapshotter.swift`
  - `Perch/UI/SettingsWindowController.swift`
  - `Perch/UI/SettingsView.swift`
  - `Perch/UI/Settings/SettingsModel.swift`
  - `Perch/UI/Settings/GeneralSettingsTab.swift`
  - `Perch/UI/Settings/LayoutsSettingsTab.swift`
  - `Perch/UI/Settings/AccessibilityBanner.swift`
  - `Perch/UI/Settings/AboutSettingsTab.swift`
  - `Perch/UI/MenuBarController.swift`
  - `Perch/UI/ToastWindow.swift`
  - `Perch/UI/HotkeyRecorder.swift`

Before each commit, run `git status --short` and stage only files listed in that task.

### Task 1: Add Failing Localization Tests

**Files:**
- Create: `PerchTests/LocalizationTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `PerchTests/LocalizationTests.swift`:

```swift
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

    private func makeDefaults() -> UserDefaults {
        let suiteName = "LocalizationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
```

- [ ] **Step 2: Regenerate project so the new test is in the test target**

Run:

```bash
xcodegen generate --spec project.yml
```

Expected: exit 0. `Perch.xcodeproj/project.pbxproj` changes include `LocalizationTests.swift in Sources`.

- [ ] **Step 3: Run the localization test and verify it fails**

Run:

```bash
xcodebuild test -project Perch.xcodeproj -scheme PerchModelTests -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:PerchTests/LocalizationTests
```

Expected: FAIL at compile time with unresolved symbols such as `Cannot find 'AppLanguage' in scope` and `Cannot find 'LocalizationManager' in scope`.

### Task 2: Implement Core Localization API

**Files:**
- Create: `Perch/Infrastructure/Localization/AppLanguage.swift`
- Create: `Perch/Infrastructure/Localization/LocalizationKey.swift`
- Create: `Perch/Infrastructure/Localization/LocalizationCatalog.swift`
- Create: `Perch/Infrastructure/Localization/LocalizationManager.swift`
- Create: `Perch/Infrastructure/Localization/L10n.swift`
- Modify: `project.yml`
- Modify: `Perch.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add localization source path to the test target**

In `project.yml`, add this source under `targets.PerchTests.sources`, after `PerchTests`:

```yaml
      - path: Perch/Infrastructure/Localization
```

- [ ] **Step 2: Create `AppLanguage.swift`**

```swift
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case czech = "cs"
    case slovak = "sk"
    case english = "en"
    case spanish = "es"
    case german = "de"

    var id: String { rawValue }

    static let translatedCases: [AppLanguage] = [.czech, .slovak, .english, .spanish, .german]

    var displayName: String {
        switch self {
        case .system: "System"
        case .czech: "Čeština"
        case .slovak: "Slovenčina"
        case .english: "English"
        case .spanish: "Español"
        case .german: "Deutsch"
        }
    }

    static func effectiveLanguage(
        selected: AppLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        guard selected == .system else {
            return selected
        }

        for preferredLanguage in preferredLanguages {
            let code = preferredLanguage
                .split(separator: "-")
                .first
                .map(String.init)?
                .lowercased()

            if let code, let language = AppLanguage(rawValue: code), language != .system {
                return language
            }
        }

        return .english
    }
}
```

- [ ] **Step 3: Create `LocalizationKey.swift`**

```swift
import Foundation

enum LocalizationKey: String, CaseIterable, Sendable {
    case aboutAccessibilityLabel
    case aboutDescriptionPrivacy
    case aboutDescriptionRestore
    case aboutDescriptionSummary
    case aboutDiagnosticsRedacted
    case aboutExportDiagnostics
    case aboutMadeBy
    case aboutMissing
    case aboutTabTitle
    case aboutGranted
    case aboutVersionFormat
    case accessibilityBannerPendingMessage
    case accessibilityBannerPendingTitle
    case accessibilityBannerRequiredMessage
    case accessibilityBannerRequiredTitle
    case accessibilityGranted
    case accessibilityPermissionPending
    case accessibilityPermissionResetEnable
    case addButton
    case allWindowsRestored
    case appLabel
    case applicationClosed
    case applicationNotInstalled
    case bundleIDLabel
    case cancelButton
    case clearCustomShortcutHelp
    case createLayout
    case createdLayoutFormat
    case deleteButton
    case deleteLayoutHelp
    case deleteLayoutMessageFormat
    case deleteLayoutTitle
    case diagnosticsExported
    case errorSectionTitle
    case exportDiagnostics
    case generalTabTitle
    case grantAccessibilityPermission
    case grantAccessibilityPermissionPending
    case hotkeyRecordPrompt
    case hotkeyRequiresModifier
    case languagePickerLabel
    case languageSectionTitle
    case lastRestoreReport
    case launchAtLogin
    case launchAtLoginStatus
    case launchStatusDisabled
    case launchStatusEnabled
    case launchStatusRequiresApproval
    case launchStatusUnavailable
    case launchStatusUnknown
    case layoutNameCannotBeEmpty
    case layoutNameField
    case layoutNotFoundFormat
    case layoutsSectionTitle
    case layoutsTabTitle
    case matchedByLabel
    case menuBarFooter
    case menuBarSectionTitle
    case menuBarShowLabel
    case menuOutcomeAmbiguousWindows
    case menuOutcomeClosed
    case menuOutcomeLaunchFailed
    case menuOutcomeMoveFailed
    case menuOutcomeNotInstalled
    case menuOutcomeOpenedAndRestored
    case menuOutcomeRestored
    case menuOutcomeSkipped
    case menuOutcomeWindowNotFound
    case newLayoutDefaultName
    case newLayoutNamePlaceholder
    case noLayouts
    case noLayoutsYet
    case noRestoreShortcut
    case noWindowsSaved
    case noWindowsSavedYet
    case openMissingAppsDuringRestore
    case openSystemSettings
    case openedDuringRestore
    case quitPerch
    case reasonLabel
    case recordRestoreShortcutHelp
    case refreshButton
    case resetAccessibilityPermission
    case resetPermissionButton
    case restartPerch
    case restoreLayoutFormat
    case restoreSectionFooter
    case restoreSectionTitle
    case saveButton
    case saveCurrentWindowsFormat
    case settingsMenuItem
    case settingsWindowTitle
    case shortcutAlreadyUsedRestoreFormat
    case shortcutAlreadyUsedSaveFormat
    case shortcutRejectedTooltipFormat
    case slotNotFoundFormat
    case someShortcutsUnavailable
    case startupSectionTitle
    case updateLayoutWindowsFormat
    case windowLabel
    case windowsAndShortcutFormat
}
```

- [ ] **Step 4: Create `LocalizationCatalog.swift` with complete translations**

Use these exact keys and translations in `LocalizationCatalog.defaultTranslations`:

```swift
import Foundation

struct LocalizationCatalog: Sendable {
    static let `default` = LocalizationCatalog(translations: defaultTranslations)

    private static let defaultTranslations: [AppLanguage: [LocalizationKey: String]] = [
        .english: [
            .settingsWindowTitle: "Perch Settings",
            .generalTabTitle: "General",
            .layoutsTabTitle: "Layouts",
            .aboutTabTitle: "About",
            .aboutVersionFormat: "Version %@",
            .languageSectionTitle: "Language",
            .languagePickerLabel: "Language",
            .startupSectionTitle: "Startup",
            .launchAtLogin: "Launch at login",
            .launchAtLoginStatus: "Login item status",
            .launchStatusEnabled: "Enabled",
            .launchStatusDisabled: "Disabled",
            .launchStatusRequiresApproval: "Requires approval in System Settings",
            .launchStatusUnavailable: "Unavailable",
            .launchStatusUnknown: "Unknown",
            .menuBarSectionTitle: "Menu bar",
            .menuBarShowLabel: "Show label next to menu bar icon",
            .menuBarFooter: "When off, only the Perch icon is shown in the menu bar.",
            .menuOutcomeRestored: "restored",
            .menuOutcomeOpenedAndRestored: "opened and restored",
            .menuOutcomeNotInstalled: "not installed",
            .menuOutcomeLaunchFailed: "launch failed",
            .menuOutcomeClosed: "closed",
            .menuOutcomeWindowNotFound: "window not found",
            .menuOutcomeAmbiguousWindows: "ambiguous windows",
            .menuOutcomeMoveFailed: "move failed",
            .menuOutcomeSkipped: "skipped",
            .restoreSectionTitle: "Restore",
            .openMissingAppsDuringRestore: "Open missing apps during restore",
            .restoreSectionFooter: "When off, closed apps stay closed and only currently open windows are moved.",
            .accessibilityBannerPendingTitle: "Accessibility permission pending",
            .accessibilityBannerRequiredTitle: "Accessibility permission required",
            .accessibilityBannerPendingMessage: "If Perch is already enabled in System Settings, restart it so macOS attaches the permission to the running app.",
            .accessibilityBannerRequiredMessage: "Perch needs Accessibility access to read and move windows.",
            .openSystemSettings: "Open System Settings",
            .refreshButton: "Refresh",
            .resetPermissionButton: "Reset Permission",
            .restartPerch: "Restart Perch",
            .layoutsSectionTitle: "Layouts",
            .noLayouts: "No layouts yet.",
            .noLayoutsYet: "No layouts yet",
            .newLayoutNamePlaceholder: "New layout name",
            .addButton: "Add",
            .errorSectionTitle: "Error",
            .deleteLayoutTitle: "Delete layout?",
            .deleteLayoutMessageFormat: "“%@” and its saved windows will be removed.",
            .cancelButton: "Cancel",
            .deleteButton: "Delete",
            .layoutNameField: "Layout name",
            .windowsAndShortcutFormat: "%d %@ · %@",
            .recordRestoreShortcutHelp: "Record restore shortcut",
            .clearCustomShortcutHelp: "Clear custom shortcut",
            .deleteLayoutHelp: "Delete layout",
            .restoreLayoutFormat: "Restore %@",
            .noRestoreShortcut: "No restore shortcut",
            .hotkeyRecordPrompt: "Click here, then press a shortcut",
            .hotkeyRequiresModifier: "Use at least one modifier",
            .aboutDescriptionSummary: "Perch is a quiet menu bar app for saving your Mac window setup and restoring it when you need the same workspace again.",
            .aboutDescriptionRestore: "Create named layouts for work, focus, meetings, or anything else. Restore them from the menu bar or with keyboard shortcuts, even across multiple displays.",
            .aboutDescriptionPrivacy: "Layouts are stored locally on this Mac. Perch only reads and moves windows when you ask it to save or restore a layout.",
            .aboutMadeBy: "Made by Code&live",
            .aboutAccessibilityLabel: "Accessibility",
            .aboutGranted: "Granted",
            .aboutMissing: "Missing",
            .aboutExportDiagnostics: "Export Diagnostics…",
            .aboutDiagnosticsRedacted: "Diagnostics are redacted. Window titles and layout names are not exported.",
            .diagnosticsExported: "Diagnostics exported",
            .exportDiagnostics: "Export Diagnostics…",
            .newLayoutDefaultName: "New Layout",
            .createLayout: "Create Layout",
            .settingsMenuItem: "Settings…",
            .quitPerch: "Quit Perch",
            .noWindowsSavedYet: "No windows saved yet",
            .updateLayoutWindowsFormat: "Update “%@” with Current Windows",
            .saveCurrentWindowsFormat: "Save Current Windows to “%@”",
            .someShortcutsUnavailable: "Some Shortcuts Are Unavailable",
            .shortcutRejectedTooltipFormat: "macOS rejected this shortcut with status %d. It may already be used by the system or another app.",
            .resetAccessibilityPermission: "Reset Accessibility Permission…",
            .lastRestoreReport: "Last Restore Report",
            .allWindowsRestored: "All windows restored",
            .appLabel: "App",
            .bundleIDLabel: "Bundle ID",
            .windowLabel: "Window",
            .openedDuringRestore: "Perch opened this app during restore.",
            .matchedByLabel: "Matched by",
            .reasonLabel: "Reason",
            .createdLayoutFormat: "Created %@",
            .accessibilityGranted: "Accessibility permission granted",
            .accessibilityPermissionPending: "Accessibility permission pending. Restart Perch if it is already enabled.",
            .accessibilityPermissionResetEnable: "Accessibility permission reset. Enable Perch in System Settings.",
            .grantAccessibilityPermission: "Grant Accessibility Permission…",
            .grantAccessibilityPermissionPending: "Accessibility Permission Pending…",
            .noWindowsSaved: "No windows saved",
            .applicationNotInstalled: "Application is not installed.",
            .applicationClosed: "Application is closed.",
            .layoutNameCannotBeEmpty: "Layout name cannot be empty.",
            .slotNotFoundFormat: "Slot not found: %@",
            .layoutNotFoundFormat: "Layout not found: %@",
            .shortcutAlreadyUsedSaveFormat: "Shortcut is already used to save %@.",
            .shortcutAlreadyUsedRestoreFormat: "Shortcut is already used to restore %@."
        ],
        .czech: [
            .settingsWindowTitle: "Nastavení Perch",
            .generalTabTitle: "Obecné",
            .layoutsTabTitle: "Rozložení",
            .aboutTabTitle: "O aplikaci",
            .aboutVersionFormat: "Verze %@",
            .languageSectionTitle: "Jazyk",
            .languagePickerLabel: "Jazyk",
            .startupSectionTitle: "Spuštění",
            .launchAtLogin: "Spustit po přihlášení",
            .launchAtLoginStatus: "Stav položky přihlášení",
            .launchStatusEnabled: "Zapnuto",
            .launchStatusDisabled: "Vypnuto",
            .launchStatusRequiresApproval: "Vyžaduje schválení v Nastavení systému",
            .launchStatusUnavailable: "Nedostupné",
            .launchStatusUnknown: "Neznámé",
            .menuBarSectionTitle: "Lišta nabídek",
            .menuBarShowLabel: "Zobrazit popisek vedle ikony v liště",
            .menuBarFooter: "Když je volba vypnutá, v liště se zobrazí jen ikona Perch.",
            .menuOutcomeRestored: "obnoveno",
            .menuOutcomeOpenedAndRestored: "otevřeno a obnoveno",
            .menuOutcomeNotInstalled: "není nainstalováno",
            .menuOutcomeLaunchFailed: "spuštění selhalo",
            .menuOutcomeClosed: "zavřeno",
            .menuOutcomeWindowNotFound: "okno nenalezeno",
            .menuOutcomeAmbiguousWindows: "nejednoznačná okna",
            .menuOutcomeMoveFailed: "přesun selhal",
            .menuOutcomeSkipped: "přeskočeno",
            .restoreSectionTitle: "Obnovení",
            .openMissingAppsDuringRestore: "Při obnovení otevřít chybějící aplikace",
            .restoreSectionFooter: "Když je volba vypnutá, zavřené aplikace zůstanou zavřené a přesunou se jen právě otevřená okna.",
            .accessibilityBannerPendingTitle: "Oprávnění Zpřístupnění čeká",
            .accessibilityBannerRequiredTitle: "Je vyžadováno oprávnění Zpřístupnění",
            .accessibilityBannerPendingMessage: "Pokud už je Perch v Nastavení systému povolený, restartujte ho, aby macOS oprávnění připojil k běžící aplikaci.",
            .accessibilityBannerRequiredMessage: "Perch potřebuje přístup ke Zpřístupnění, aby mohl číst a přesouvat okna.",
            .openSystemSettings: "Otevřít Nastavení systému",
            .refreshButton: "Obnovit",
            .resetPermissionButton: "Resetovat oprávnění",
            .restartPerch: "Restartovat Perch",
            .layoutsSectionTitle: "Rozložení",
            .noLayouts: "Zatím žádná rozložení.",
            .noLayoutsYet: "Zatím žádná rozložení",
            .newLayoutNamePlaceholder: "Název nového rozložení",
            .addButton: "Přidat",
            .errorSectionTitle: "Chyba",
            .deleteLayoutTitle: "Smazat rozložení?",
            .deleteLayoutMessageFormat: "„%@“ a jeho uložená okna budou odstraněna.",
            .cancelButton: "Zrušit",
            .deleteButton: "Smazat",
            .layoutNameField: "Název rozložení",
            .windowsAndShortcutFormat: "%d %@ · %@",
            .recordRestoreShortcutHelp: "Nahrát zkratku pro obnovení",
            .clearCustomShortcutHelp: "Vymazat vlastní zkratku",
            .deleteLayoutHelp: "Smazat rozložení",
            .restoreLayoutFormat: "Obnovit %@",
            .noRestoreShortcut: "Žádná zkratka pro obnovení",
            .hotkeyRecordPrompt: "Klikněte sem a stiskněte zkratku",
            .hotkeyRequiresModifier: "Použijte alespoň jeden modifikátor",
            .aboutDescriptionSummary: "Perch je nenápadná aplikace v liště pro ukládání nastavení oken na Macu a jejich obnovení, když znovu potřebujete stejný pracovní prostor.",
            .aboutDescriptionRestore: "Vytvářejte pojmenovaná rozložení pro práci, soustředění, schůzky nebo cokoliv dalšího. Obnovíte je z lišty nebo klávesovou zkratkou, i přes více displejů.",
            .aboutDescriptionPrivacy: "Rozložení se ukládají lokálně na tomto Macu. Perch čte a přesouvá okna jen tehdy, když požádáte o uložení nebo obnovení rozložení.",
            .aboutMadeBy: "Vytvořilo Code&live",
            .aboutAccessibilityLabel: "Zpřístupnění",
            .aboutGranted: "Povoleno",
            .aboutMissing: "Chybí",
            .aboutExportDiagnostics: "Exportovat diagnostiku…",
            .aboutDiagnosticsRedacted: "Diagnostika je anonymizovaná. Názvy oken a rozložení se neexportují.",
            .diagnosticsExported: "Diagnostika exportována",
            .exportDiagnostics: "Exportovat diagnostiku…",
            .newLayoutDefaultName: "Nové rozložení",
            .createLayout: "Vytvořit rozložení",
            .settingsMenuItem: "Nastavení…",
            .quitPerch: "Ukončit Perch",
            .noWindowsSavedYet: "Zatím nejsou uložena žádná okna",
            .updateLayoutWindowsFormat: "Aktualizovat „%@“ aktuálními okny",
            .saveCurrentWindowsFormat: "Uložit aktuální okna do „%@“",
            .someShortcutsUnavailable: "Některé zkratky nejsou dostupné",
            .shortcutRejectedTooltipFormat: "macOS odmítl tuto zkratku se stavem %d. Možná ji už používá systém nebo jiná aplikace.",
            .resetAccessibilityPermission: "Resetovat oprávnění Zpřístupnění…",
            .lastRestoreReport: "Poslední hlášení obnovení",
            .allWindowsRestored: "Všechna okna obnovena",
            .appLabel: "Aplikace",
            .bundleIDLabel: "Bundle ID",
            .windowLabel: "Okno",
            .openedDuringRestore: "Perch tuto aplikaci během obnovení otevřel.",
            .matchedByLabel: "Shoda podle",
            .reasonLabel: "Důvod",
            .createdLayoutFormat: "Vytvořeno %@",
            .accessibilityGranted: "Oprávnění Zpřístupnění povoleno",
            .accessibilityPermissionPending: "Oprávnění Zpřístupnění čeká. Pokud už je Perch povolený, restartujte ho.",
            .accessibilityPermissionResetEnable: "Oprávnění Zpřístupnění resetováno. Povolte Perch v Nastavení systému.",
            .grantAccessibilityPermission: "Udělit oprávnění Zpřístupnění…",
            .grantAccessibilityPermissionPending: "Oprávnění Zpřístupnění čeká…",
            .noWindowsSaved: "Nejsou uložena žádná okna",
            .applicationNotInstalled: "Aplikace není nainstalovaná.",
            .applicationClosed: "Aplikace je zavřená.",
            .layoutNameCannotBeEmpty: "Název rozložení nesmí být prázdný.",
            .slotNotFoundFormat: "Slot nenalezen: %@",
            .layoutNotFoundFormat: "Rozložení nenalezeno: %@",
            .shortcutAlreadyUsedSaveFormat: "Zkratka se už používá pro uložení %@.",
            .shortcutAlreadyUsedRestoreFormat: "Zkratka se už používá pro obnovení %@."
        ],
        .slovak: [
            .settingsWindowTitle: "Nastavenia Perch",
            .generalTabTitle: "Všeobecné",
            .layoutsTabTitle: "Rozloženia",
            .aboutTabTitle: "O aplikácii",
            .aboutVersionFormat: "Verzia %@",
            .languageSectionTitle: "Jazyk",
            .languagePickerLabel: "Jazyk",
            .startupSectionTitle: "Spustenie",
            .launchAtLogin: "Spustiť po prihlásení",
            .launchAtLoginStatus: "Stav položky prihlásenia",
            .launchStatusEnabled: "Zapnuté",
            .launchStatusDisabled: "Vypnuté",
            .launchStatusRequiresApproval: "Vyžaduje schválenie v Nastaveniach systému",
            .launchStatusUnavailable: "Nedostupné",
            .launchStatusUnknown: "Neznáme",
            .menuBarSectionTitle: "Lišta menu",
            .menuBarShowLabel: "Zobraziť popis vedľa ikony v lište",
            .menuBarFooter: "Keď je voľba vypnutá, v lište sa zobrazí iba ikona Perch.",
            .menuOutcomeRestored: "obnovené",
            .menuOutcomeOpenedAndRestored: "otvorené a obnovené",
            .menuOutcomeNotInstalled: "nie je nainštalované",
            .menuOutcomeLaunchFailed: "spustenie zlyhalo",
            .menuOutcomeClosed: "zatvorené",
            .menuOutcomeWindowNotFound: "okno nenájdené",
            .menuOutcomeAmbiguousWindows: "nejednoznačné okná",
            .menuOutcomeMoveFailed: "presun zlyhal",
            .menuOutcomeSkipped: "preskočené",
            .restoreSectionTitle: "Obnovenie",
            .openMissingAppsDuringRestore: "Pri obnovení otvoriť chýbajúce aplikácie",
            .restoreSectionFooter: "Keď je voľba vypnutá, zatvorené aplikácie zostanú zatvorené a presunú sa iba aktuálne otvorené okná.",
            .accessibilityBannerPendingTitle: "Oprávnenie Prístupnosť čaká",
            .accessibilityBannerRequiredTitle: "Vyžaduje sa oprávnenie Prístupnosť",
            .accessibilityBannerPendingMessage: "Ak je Perch už povolený v Nastaveniach systému, reštartujte ho, aby macOS pripojil oprávnenie k bežiacej aplikácii.",
            .accessibilityBannerRequiredMessage: "Perch potrebuje prístup k Prístupnosti, aby mohol čítať a presúvať okná.",
            .openSystemSettings: "Otvoriť Nastavenia systému",
            .refreshButton: "Obnoviť",
            .resetPermissionButton: "Resetovať oprávnenie",
            .restartPerch: "Reštartovať Perch",
            .layoutsSectionTitle: "Rozloženia",
            .noLayouts: "Zatiaľ žiadne rozloženia.",
            .noLayoutsYet: "Zatiaľ žiadne rozloženia",
            .newLayoutNamePlaceholder: "Názov nového rozloženia",
            .addButton: "Pridať",
            .errorSectionTitle: "Chyba",
            .deleteLayoutTitle: "Vymazať rozloženie?",
            .deleteLayoutMessageFormat: "„%@“ a jeho uložené okná budú odstránené.",
            .cancelButton: "Zrušiť",
            .deleteButton: "Vymazať",
            .layoutNameField: "Názov rozloženia",
            .windowsAndShortcutFormat: "%d %@ · %@",
            .recordRestoreShortcutHelp: "Nahrať skratku pre obnovenie",
            .clearCustomShortcutHelp: "Vymazať vlastnú skratku",
            .deleteLayoutHelp: "Vymazať rozloženie",
            .restoreLayoutFormat: "Obnoviť %@",
            .noRestoreShortcut: "Žiadna skratka pre obnovenie",
            .hotkeyRecordPrompt: "Kliknite sem a stlačte skratku",
            .hotkeyRequiresModifier: "Použite aspoň jeden modifikátor",
            .aboutDescriptionSummary: "Perch je nenápadná aplikácia v lište na ukladanie nastavenia okien na Macu a jeho obnovenie, keď znova potrebujete rovnaký pracovný priestor.",
            .aboutDescriptionRestore: "Vytvárajte pomenované rozloženia pre prácu, sústredenie, schôdzky alebo čokoľvek ďalšie. Obnovíte ich z lišty alebo klávesovou skratkou, aj cez viac displejov.",
            .aboutDescriptionPrivacy: "Rozloženia sa ukladajú lokálne na tomto Macu. Perch číta a presúva okná iba vtedy, keď požiadate o uloženie alebo obnovenie rozloženia.",
            .aboutMadeBy: "Vytvorilo Code&live",
            .aboutAccessibilityLabel: "Prístupnosť",
            .aboutGranted: "Povolené",
            .aboutMissing: "Chýba",
            .aboutExportDiagnostics: "Exportovať diagnostiku…",
            .aboutDiagnosticsRedacted: "Diagnostika je anonymizovaná. Názvy okien a rozložení sa neexportujú.",
            .diagnosticsExported: "Diagnostika exportovaná",
            .exportDiagnostics: "Exportovať diagnostiku…",
            .newLayoutDefaultName: "Nové rozloženie",
            .createLayout: "Vytvoriť rozloženie",
            .settingsMenuItem: "Nastavenia…",
            .quitPerch: "Ukončiť Perch",
            .noWindowsSavedYet: "Zatiaľ nie sú uložené žiadne okná",
            .updateLayoutWindowsFormat: "Aktualizovať „%@“ aktuálnymi oknami",
            .saveCurrentWindowsFormat: "Uložiť aktuálne okná do „%@“",
            .someShortcutsUnavailable: "Niektoré skratky nie sú dostupné",
            .shortcutRejectedTooltipFormat: "macOS odmietol túto skratku so stavom %d. Možno ju už používa systém alebo iná aplikácia.",
            .resetAccessibilityPermission: "Resetovať oprávnenie Prístupnosť…",
            .lastRestoreReport: "Posledné hlásenie obnovenia",
            .allWindowsRestored: "Všetky okná obnovené",
            .appLabel: "Aplikácia",
            .bundleIDLabel: "Bundle ID",
            .windowLabel: "Okno",
            .openedDuringRestore: "Perch túto aplikáciu počas obnovenia otvoril.",
            .matchedByLabel: "Zhoda podľa",
            .reasonLabel: "Dôvod",
            .createdLayoutFormat: "Vytvorené %@",
            .accessibilityGranted: "Oprávnenie Prístupnosť povolené",
            .accessibilityPermissionPending: "Oprávnenie Prístupnosť čaká. Ak je Perch už povolený, reštartujte ho.",
            .accessibilityPermissionResetEnable: "Oprávnenie Prístupnosť resetované. Povoľte Perch v Nastaveniach systému.",
            .grantAccessibilityPermission: "Udeliť oprávnenie Prístupnosť…",
            .grantAccessibilityPermissionPending: "Oprávnenie Prístupnosť čaká…",
            .noWindowsSaved: "Nie sú uložené žiadne okná",
            .applicationNotInstalled: "Aplikácia nie je nainštalovaná.",
            .applicationClosed: "Aplikácia je zatvorená.",
            .layoutNameCannotBeEmpty: "Názov rozloženia nesmie byť prázdny.",
            .slotNotFoundFormat: "Slot nenájdený: %@",
            .layoutNotFoundFormat: "Rozloženie nenájdené: %@",
            .shortcutAlreadyUsedSaveFormat: "Skratka sa už používa na uloženie %@.",
            .shortcutAlreadyUsedRestoreFormat: "Skratka sa už používa na obnovenie %@."
        ],
        .spanish: [
            .settingsWindowTitle: "Ajustes de Perch",
            .generalTabTitle: "General",
            .layoutsTabTitle: "Diseños",
            .aboutTabTitle: "Acerca de",
            .aboutVersionFormat: "Versión %@",
            .languageSectionTitle: "Idioma",
            .languagePickerLabel: "Idioma",
            .startupSectionTitle: "Inicio",
            .launchAtLogin: "Abrir al iniciar sesión",
            .launchAtLoginStatus: "Estado del inicio de sesión",
            .launchStatusEnabled: "Activado",
            .launchStatusDisabled: "Desactivado",
            .launchStatusRequiresApproval: "Requiere aprobación en Ajustes del Sistema",
            .launchStatusUnavailable: "No disponible",
            .launchStatusUnknown: "Desconocido",
            .menuBarSectionTitle: "Barra de menús",
            .menuBarShowLabel: "Mostrar etiqueta junto al icono de la barra",
            .menuBarFooter: "Si está desactivado, solo se muestra el icono de Perch en la barra de menús.",
            .menuOutcomeRestored: "restaurada",
            .menuOutcomeOpenedAndRestored: "abierta y restaurada",
            .menuOutcomeNotInstalled: "no instalada",
            .menuOutcomeLaunchFailed: "fallo al abrir",
            .menuOutcomeClosed: "cerrada",
            .menuOutcomeWindowNotFound: "ventana no encontrada",
            .menuOutcomeAmbiguousWindows: "ventanas ambiguas",
            .menuOutcomeMoveFailed: "fallo al mover",
            .menuOutcomeSkipped: "omitida",
            .restoreSectionTitle: "Restauración",
            .openMissingAppsDuringRestore: "Abrir apps faltantes al restaurar",
            .restoreSectionFooter: "Si está desactivado, las apps cerradas permanecen cerradas y solo se mueven las ventanas abiertas.",
            .accessibilityBannerPendingTitle: "Permiso de Accesibilidad pendiente",
            .accessibilityBannerRequiredTitle: "Se requiere permiso de Accesibilidad",
            .accessibilityBannerPendingMessage: "Si Perch ya está permitido en Ajustes del Sistema, reinícialo para que macOS asocie el permiso a la app en ejecución.",
            .accessibilityBannerRequiredMessage: "Perch necesita acceso de Accesibilidad para leer y mover ventanas.",
            .openSystemSettings: "Abrir Ajustes del Sistema",
            .refreshButton: "Actualizar",
            .resetPermissionButton: "Restablecer permiso",
            .restartPerch: "Reiniciar Perch",
            .layoutsSectionTitle: "Diseños",
            .noLayouts: "Todavía no hay diseños.",
            .noLayoutsYet: "Todavía no hay diseños",
            .newLayoutNamePlaceholder: "Nombre del nuevo diseño",
            .addButton: "Añadir",
            .errorSectionTitle: "Error",
            .deleteLayoutTitle: "¿Eliminar diseño?",
            .deleteLayoutMessageFormat: "“%@” y sus ventanas guardadas se eliminarán.",
            .cancelButton: "Cancelar",
            .deleteButton: "Eliminar",
            .layoutNameField: "Nombre del diseño",
            .windowsAndShortcutFormat: "%d %@ · %@",
            .recordRestoreShortcutHelp: "Grabar atajo de restauración",
            .clearCustomShortcutHelp: "Borrar atajo personalizado",
            .deleteLayoutHelp: "Eliminar diseño",
            .restoreLayoutFormat: "Restaurar %@",
            .noRestoreShortcut: "Sin atajo de restauración",
            .hotkeyRecordPrompt: "Haz clic aquí y pulsa un atajo",
            .hotkeyRequiresModifier: "Usa al menos un modificador",
            .aboutDescriptionSummary: "Perch es una app discreta de barra de menús para guardar la disposición de ventanas de tu Mac y restaurarla cuando necesites el mismo espacio de trabajo.",
            .aboutDescriptionRestore: "Crea diseños con nombre para trabajo, concentración, reuniones o cualquier otra cosa. Restáuralos desde la barra de menús o con atajos de teclado, incluso en varios monitores.",
            .aboutDescriptionPrivacy: "Los diseños se guardan localmente en este Mac. Perch solo lee y mueve ventanas cuando le pides guardar o restaurar un diseño.",
            .aboutMadeBy: "Hecho por Code&live",
            .aboutAccessibilityLabel: "Accesibilidad",
            .aboutGranted: "Concedido",
            .aboutMissing: "Falta",
            .aboutExportDiagnostics: "Exportar diagnóstico…",
            .aboutDiagnosticsRedacted: "El diagnóstico está anonimizado. Los títulos de ventanas y nombres de diseños no se exportan.",
            .diagnosticsExported: "Diagnóstico exportado",
            .exportDiagnostics: "Exportar diagnóstico…",
            .newLayoutDefaultName: "Nuevo diseño",
            .createLayout: "Crear diseño",
            .settingsMenuItem: "Ajustes…",
            .quitPerch: "Salir de Perch",
            .noWindowsSavedYet: "Todavía no hay ventanas guardadas",
            .updateLayoutWindowsFormat: "Actualizar “%@” con las ventanas actuales",
            .saveCurrentWindowsFormat: "Guardar ventanas actuales en “%@”",
            .someShortcutsUnavailable: "Algunos atajos no están disponibles",
            .shortcutRejectedTooltipFormat: "macOS rechazó este atajo con estado %d. Puede que el sistema u otra app ya lo use.",
            .resetAccessibilityPermission: "Restablecer permiso de Accesibilidad…",
            .lastRestoreReport: "Último informe de restauración",
            .allWindowsRestored: "Todas las ventanas restauradas",
            .appLabel: "App",
            .bundleIDLabel: "Bundle ID",
            .windowLabel: "Ventana",
            .openedDuringRestore: "Perch abrió esta app durante la restauración.",
            .matchedByLabel: "Coincidencia por",
            .reasonLabel: "Motivo",
            .createdLayoutFormat: "%@ creado",
            .accessibilityGranted: "Permiso de Accesibilidad concedido",
            .accessibilityPermissionPending: "Permiso de Accesibilidad pendiente. Reinicia Perch si ya está permitido.",
            .accessibilityPermissionResetEnable: "Permiso de Accesibilidad restablecido. Permite Perch en Ajustes del Sistema.",
            .grantAccessibilityPermission: "Conceder permiso de Accesibilidad…",
            .grantAccessibilityPermissionPending: "Permiso de Accesibilidad pendiente…",
            .noWindowsSaved: "No hay ventanas guardadas",
            .applicationNotInstalled: "La aplicación no está instalada.",
            .applicationClosed: "La aplicación está cerrada.",
            .layoutNameCannotBeEmpty: "El nombre del diseño no puede estar vacío.",
            .slotNotFoundFormat: "Slot no encontrado: %@",
            .layoutNotFoundFormat: "Diseño no encontrado: %@",
            .shortcutAlreadyUsedSaveFormat: "El atajo ya se usa para guardar %@.",
            .shortcutAlreadyUsedRestoreFormat: "El atajo ya se usa para restaurar %@."
        ],
        .german: [
            .settingsWindowTitle: "Perch-Einstellungen",
            .generalTabTitle: "Allgemein",
            .layoutsTabTitle: "Layouts",
            .aboutTabTitle: "Info",
            .aboutVersionFormat: "Version %@",
            .languageSectionTitle: "Sprache",
            .languagePickerLabel: "Sprache",
            .startupSectionTitle: "Start",
            .launchAtLogin: "Beim Anmelden starten",
            .launchAtLoginStatus: "Status des Anmeldeobjekts",
            .launchStatusEnabled: "Aktiviert",
            .launchStatusDisabled: "Deaktiviert",
            .launchStatusRequiresApproval: "Erfordert Zustimmung in den Systemeinstellungen",
            .launchStatusUnavailable: "Nicht verfügbar",
            .launchStatusUnknown: "Unbekannt",
            .menuBarSectionTitle: "Menüleiste",
            .menuBarShowLabel: "Beschriftung neben dem Menüleistensymbol anzeigen",
            .menuBarFooter: "Wenn deaktiviert, wird in der Menüleiste nur das Perch-Symbol angezeigt.",
            .menuOutcomeRestored: "wiederhergestellt",
            .menuOutcomeOpenedAndRestored: "geöffnet und wiederhergestellt",
            .menuOutcomeNotInstalled: "nicht installiert",
            .menuOutcomeLaunchFailed: "Start fehlgeschlagen",
            .menuOutcomeClosed: "geschlossen",
            .menuOutcomeWindowNotFound: "Fenster nicht gefunden",
            .menuOutcomeAmbiguousWindows: "mehrdeutige Fenster",
            .menuOutcomeMoveFailed: "Verschieben fehlgeschlagen",
            .menuOutcomeSkipped: "übersprungen",
            .restoreSectionTitle: "Wiederherstellen",
            .openMissingAppsDuringRestore: "Fehlende Apps beim Wiederherstellen öffnen",
            .restoreSectionFooter: "Wenn deaktiviert, bleiben geschlossene Apps geschlossen und nur aktuell geöffnete Fenster werden verschoben.",
            .accessibilityBannerPendingTitle: "Bedienungshilfen-Berechtigung ausstehend",
            .accessibilityBannerRequiredTitle: "Bedienungshilfen-Berechtigung erforderlich",
            .accessibilityBannerPendingMessage: "Wenn Perch in den Systemeinstellungen bereits erlaubt ist, starte es neu, damit macOS die Berechtigung der laufenden App zuordnet.",
            .accessibilityBannerRequiredMessage: "Perch benötigt Zugriff auf Bedienungshilfen, um Fenster zu lesen und zu verschieben.",
            .openSystemSettings: "Systemeinstellungen öffnen",
            .refreshButton: "Aktualisieren",
            .resetPermissionButton: "Berechtigung zurücksetzen",
            .restartPerch: "Perch neu starten",
            .layoutsSectionTitle: "Layouts",
            .noLayouts: "Noch keine Layouts.",
            .noLayoutsYet: "Noch keine Layouts",
            .newLayoutNamePlaceholder: "Name des neuen Layouts",
            .addButton: "Hinzufügen",
            .errorSectionTitle: "Fehler",
            .deleteLayoutTitle: "Layout löschen?",
            .deleteLayoutMessageFormat: "„%@“ und die gespeicherten Fenster werden entfernt.",
            .cancelButton: "Abbrechen",
            .deleteButton: "Löschen",
            .layoutNameField: "Layoutname",
            .windowsAndShortcutFormat: "%d %@ · %@",
            .recordRestoreShortcutHelp: "Tastenkürzel zum Wiederherstellen aufnehmen",
            .clearCustomShortcutHelp: "Eigenes Tastenkürzel löschen",
            .deleteLayoutHelp: "Layout löschen",
            .restoreLayoutFormat: "%@ wiederherstellen",
            .noRestoreShortcut: "Kein Wiederherstellungs-Tastenkürzel",
            .hotkeyRecordPrompt: "Hier klicken und ein Tastenkürzel drücken",
            .hotkeyRequiresModifier: "Mindestens eine Modifikatortaste verwenden",
            .aboutDescriptionSummary: "Perch ist eine ruhige Menüleisten-App zum Speichern deiner Mac-Fensteranordnung und zum Wiederherstellen desselben Arbeitsbereichs.",
            .aboutDescriptionRestore: "Erstelle benannte Layouts für Arbeit, Fokus, Meetings oder anderes. Stelle sie über die Menüleiste oder Tastenkürzel wieder her, auch über mehrere Displays hinweg.",
            .aboutDescriptionPrivacy: "Layouts werden lokal auf diesem Mac gespeichert. Perch liest und verschiebt Fenster nur, wenn du ein Layout speicherst oder wiederherstellst.",
            .aboutMadeBy: "Erstellt von Code&live",
            .aboutAccessibilityLabel: "Bedienungshilfen",
            .aboutGranted: "Gewährt",
            .aboutMissing: "Fehlt",
            .aboutExportDiagnostics: "Diagnose exportieren…",
            .aboutDiagnosticsRedacted: "Diagnosen sind bereinigt. Fenstertitel und Layoutnamen werden nicht exportiert.",
            .diagnosticsExported: "Diagnose exportiert",
            .exportDiagnostics: "Diagnose exportieren…",
            .newLayoutDefaultName: "Neues Layout",
            .createLayout: "Layout erstellen",
            .settingsMenuItem: "Einstellungen…",
            .quitPerch: "Perch beenden",
            .noWindowsSavedYet: "Noch keine Fenster gespeichert",
            .updateLayoutWindowsFormat: "„%@“ mit aktuellen Fenstern aktualisieren",
            .saveCurrentWindowsFormat: "Aktuelle Fenster in „%@“ speichern",
            .someShortcutsUnavailable: "Einige Tastenkürzel sind nicht verfügbar",
            .shortcutRejectedTooltipFormat: "macOS hat dieses Tastenkürzel mit Status %d abgelehnt. Es wird möglicherweise bereits vom System oder einer anderen App verwendet.",
            .resetAccessibilityPermission: "Bedienungshilfen-Berechtigung zurücksetzen…",
            .lastRestoreReport: "Letzter Wiederherstellungsbericht",
            .allWindowsRestored: "Alle Fenster wiederhergestellt",
            .appLabel: "App",
            .bundleIDLabel: "Bundle-ID",
            .windowLabel: "Fenster",
            .openedDuringRestore: "Perch hat diese App während der Wiederherstellung geöffnet.",
            .matchedByLabel: "Zugeordnet über",
            .reasonLabel: "Grund",
            .createdLayoutFormat: "%@ erstellt",
            .accessibilityGranted: "Bedienungshilfen-Berechtigung gewährt",
            .accessibilityPermissionPending: "Bedienungshilfen-Berechtigung ausstehend. Starte Perch neu, wenn es bereits erlaubt ist.",
            .accessibilityPermissionResetEnable: "Bedienungshilfen-Berechtigung zurückgesetzt. Erlaube Perch in den Systemeinstellungen.",
            .grantAccessibilityPermission: "Bedienungshilfen-Berechtigung gewähren…",
            .grantAccessibilityPermissionPending: "Bedienungshilfen-Berechtigung ausstehend…",
            .noWindowsSaved: "Keine Fenster gespeichert",
            .applicationNotInstalled: "Die Anwendung ist nicht installiert.",
            .applicationClosed: "Die Anwendung ist geschlossen.",
            .layoutNameCannotBeEmpty: "Der Layoutname darf nicht leer sein.",
            .slotNotFoundFormat: "Slot nicht gefunden: %@",
            .layoutNotFoundFormat: "Layout nicht gefunden: %@",
            .shortcutAlreadyUsedSaveFormat: "Das Tastenkürzel wird bereits zum Speichern von %@ verwendet.",
            .shortcutAlreadyUsedRestoreFormat: "Das Tastenkürzel wird bereits zum Wiederherstellen von %@ verwendet."
        ]
    ]

    private let translations: [AppLanguage: [LocalizationKey: String]]

    init(translations: [AppLanguage: [LocalizationKey: String]]) {
        self.translations = translations
    }

    func localizedString(for key: LocalizationKey, language: AppLanguage) -> String {
        if let value = translations[language]?[key] {
            return value
        }

        if let fallback = translations[.english]?[key] {
            #if DEBUG
            AppLog.app.warning("Missing localization key \(key.rawValue, privacy: .public) for \(language.rawValue, privacy: .public)")
            #endif
            return fallback
        }

        #if DEBUG
        AppLog.app.warning("Missing English localization key \(key.rawValue, privacy: .public)")
        #endif
        return key.rawValue
    }

    func hasTranslation(for key: LocalizationKey, language: AppLanguage) -> Bool {
        translations[language]?[key] != nil
    }
}
```

- [ ] **Step 5: Create `LocalizationManager.swift`**

```swift
import Foundation
import Observation

extension Notification.Name {
    static let perchLanguageDidChange = Notification.Name("PerchLanguageDidChange")
}

@MainActor
@Observable
final class LocalizationManager {
    static let shared = LocalizationManager()
    static let userDefaultsKey = "SelectedAppLanguage"

    var selectedLanguage: AppLanguage {
        didSet {
            guard oldValue != selectedLanguage else { return }
            userDefaults.set(selectedLanguage.rawValue, forKey: Self.userDefaultsKey)
            NotificationCenter.default.post(name: .perchLanguageDidChange, object: self)
        }
    }

    private let userDefaults: UserDefaults
    private let preferredLanguagesProvider: () -> [String]
    private let catalog: LocalizationCatalog

    init(
        userDefaults: UserDefaults = .standard,
        preferredLanguagesProvider: @escaping () -> [String] = { Locale.preferredLanguages },
        catalog: LocalizationCatalog = .default
    ) {
        self.userDefaults = userDefaults
        self.preferredLanguagesProvider = preferredLanguagesProvider
        self.catalog = catalog

        if
            let rawValue = userDefaults.string(forKey: Self.userDefaultsKey),
            let language = AppLanguage(rawValue: rawValue)
        {
            self.selectedLanguage = language
        } else {
            self.selectedLanguage = .system
        }
    }

    var effectiveLanguage: AppLanguage {
        AppLanguage.effectiveLanguage(
            selected: selectedLanguage,
            preferredLanguages: preferredLanguagesProvider()
        )
    }

    func text(_ key: LocalizationKey) -> String {
        catalog.localizedString(for: key, language: effectiveLanguage)
    }

    func format(_ key: LocalizationKey, _ arguments: CVarArg...) -> String {
        format(key, arguments: arguments)
    }

    func format(_ key: LocalizationKey, arguments: [CVarArg]) -> String {
        String(format: text(key), locale: Locale(identifier: effectiveLanguage.localeIdentifier), arguments: arguments)
    }

    func windowNoun(count: Int) -> String {
        switch effectiveLanguage {
        case .czech:
            if count == 1 { return "okno" }
            if (2...4).contains(count) { return "okna" }
            return "oken"
        case .slovak:
            if count == 1 { return "okno" }
            if (2...4).contains(count) { return "okná" }
            return "okien"
        case .spanish:
            return count == 1 ? "ventana" : "ventanas"
        case .german:
            return count == 1 ? "Fenster" : "Fenster"
        case .english, .system:
            return count == 1 ? "window" : "windows"
        }
    }

    func savedWindowCount(_ count: Int) -> String {
        switch effectiveLanguage {
        case .czech:
            return count == 1
                ? "Uloženo 1 okno"
                : "Uložena \(count) \(windowNoun(count: count))"
        case .slovak:
            return count == 1
                ? "Uložené 1 okno"
                : "Uložené \(count) \(windowNoun(count: count))"
        case .spanish:
            return "Guardadas \(count) \(windowNoun(count: count))"
        case .german:
            return "\(count) \(windowNoun(count: count)) gespeichert"
        case .english, .system:
            return "Saved \(count) \(windowNoun(count: count))"
        }
    }

    func restoredWindowCount(restored: Int, total: Int) -> String {
        switch effectiveLanguage {
        case .czech:
            return "Obnoveno \(restored)/\(total) \(windowNoun(count: total))"
        case .slovak:
            return "Obnovené \(restored)/\(total) \(windowNoun(count: total))"
        case .spanish:
            return "Restauradas \(restored)/\(total) \(windowNoun(count: total))"
        case .german:
            return "\(restored)/\(total) \(windowNoun(count: total)) wiederhergestellt"
        case .english, .system:
            return "Restored \(restored)/\(total) \(windowNoun(count: total))"
        }
    }

    func restoreSummary(succeeded: Int, total: Int, openedAppCount: Int) -> String {
        switch effectiveLanguage {
        case .czech:
            var parts = ["Obnoveno \(succeeded)/\(total)"]
            if openedAppCount == 1 {
                parts.append("otevřena 1 aplikace")
            } else if openedAppCount > 1 {
                parts.append("otevřeny \(openedAppCount) aplikace")
            }
            return parts.joined(separator: "; ")
        case .slovak:
            var parts = ["Obnovené \(succeeded)/\(total)"]
            if openedAppCount == 1 {
                parts.append("otvorená 1 aplikácia")
            } else if openedAppCount > 1 {
                parts.append("otvorené \(openedAppCount) aplikácie")
            }
            return parts.joined(separator: "; ")
        case .spanish:
            var parts = ["Restauradas \(succeeded)/\(total)"]
            if openedAppCount == 1 {
                parts.append("1 app abierta")
            } else if openedAppCount > 1 {
                parts.append("\(openedAppCount) apps abiertas")
            }
            return parts.joined(separator: "; ")
        case .german:
            var parts = ["\(succeeded)/\(total) wiederhergestellt"]
            if openedAppCount == 1 {
                parts.append("1 App geöffnet")
            } else if openedAppCount > 1 {
                parts.append("\(openedAppCount) Apps geöffnet")
            }
            return parts.joined(separator: "; ")
        case .english, .system:
            if openedAppCount == 1 {
                return "Restored \(succeeded)/\(total); opened 1 app"
            }
            if openedAppCount > 1 {
                return "Restored \(succeeded)/\(total); opened \(openedAppCount) apps"
            }
            return "Restored \(succeeded)/\(total) \(windowNoun(count: total))"
        }
    }
}

private extension AppLanguage {
    var localeIdentifier: String {
        switch self {
        case .system, .english: "en"
        case .czech: "cs"
        case .slovak: "sk"
        case .spanish: "es"
        case .german: "de"
        }
    }
}
```

- [ ] **Step 6: Create `L10n.swift`**

```swift
import Foundation

@MainActor
enum L10n {
    static var manager: LocalizationManager {
        LocalizationManager.shared
    }

    static func text(_ key: LocalizationKey) -> String {
        manager.text(key)
    }

    static func format(_ key: LocalizationKey, _ arguments: CVarArg...) -> String {
        manager.format(key, arguments: arguments)
    }

    static func savedWindowCount(_ count: Int) -> String {
        manager.savedWindowCount(count)
    }

    static func restoredWindowCount(restored: Int, total: Int) -> String {
        manager.restoredWindowCount(restored: restored, total: total)
    }

    static func restoreSummary(succeeded: Int, total: Int, openedAppCount: Int) -> String {
        manager.restoreSummary(succeeded: succeeded, total: total, openedAppCount: openedAppCount)
    }
}
```

- [ ] **Step 7: Regenerate project and run the focused tests**

Run:

```bash
xcodegen generate --spec project.yml
xcodebuild test -project Perch.xcodeproj -scheme PerchModelTests -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:PerchTests/LocalizationTests
```

Expected: PASS for all `LocalizationTests`.

- [ ] **Step 8: Commit core localization**

Run:

```bash
git status --short
git add project.yml Perch.xcodeproj/project.pbxproj Perch/Infrastructure/Localization PerchTests/LocalizationTests.swift
git commit -m "Add runtime localization core"
```

### Task 3: Add Language Picker to Settings

**Files:**
- Modify: `Perch/UI/Settings/SettingsModel.swift`
- Modify: `Perch/UI/Settings/GeneralSettingsTab.swift`
- Modify: `Perch/UI/SettingsView.swift`
- Modify: `Perch/UI/SettingsWindowController.swift`

- [ ] **Step 1: Wire localization into `SettingsModel`**

Add properties and update method:

```swift
var localization = LocalizationManager.shared

var selectedLanguage: AppLanguage {
    get { localization.selectedLanguage }
    set { localization.selectedLanguage = newValue }
}

var languageOptions: [AppLanguage] {
    AppLanguage.allCases
}
```

- [ ] **Step 2: Localize Settings tabs**

In `SettingsView`, add:

```swift
@State private var localization = LocalizationManager.shared
```

Change tab labels:

```swift
.tabItem { Label(localization.text(.generalTabTitle), systemImage: "gearshape") }
.tabItem { Label(localization.text(.layoutsTabTitle), systemImage: "rectangle.on.rectangle") }
.tabItem { Label(localization.text(.aboutTabTitle), systemImage: "info.circle") }
```

- [ ] **Step 3: Add the picker to `GeneralSettingsTab`**

Add local state:

```swift
@State private var localization = LocalizationManager.shared
```

Insert this section near the top of the form:

```swift
Section {
    Picker(localization.text(.languagePickerLabel), selection: $model.selectedLanguage) {
        ForEach(model.languageOptions) { language in
            Text(language.displayName).tag(language)
        }
    }
} header: {
    Text(localization.text(.languageSectionTitle))
}
```

Replace hardcoded strings in the tab:

```swift
Toggle(localization.text(.launchAtLogin), isOn: $model.launchAtLoginEnabled)
LabeledContent(localization.text(.launchAtLoginStatus), value: model.launchAtLoginStatus)
Text(localization.text(.startupSectionTitle))
Toggle(localization.text(.menuBarShowLabel), isOn: $model.showsMenuBarLabel)
Text(localization.text(.menuBarSectionTitle))
Text(localization.text(.menuBarFooter))
Toggle(localization.text(.openMissingAppsDuringRestore), isOn: $model.opensMissingApplicationsOnRestore)
Text(localization.text(.restoreSectionTitle))
Text(localization.text(.restoreSectionFooter))
```

- [ ] **Step 4: Localize the Settings window title**

In `SettingsWindowController.makeWindow()`, set:

```swift
window.title = L10n.text(.settingsWindowTitle)
```

In `show()`, refresh it before showing:

```swift
settingsWindow.title = L10n.text(.settingsWindowTitle)
```

- [ ] **Step 5: Build the app**

Run:

```bash
xcodebuild build -project Perch.xcodeproj -scheme Perch -destination 'platform=macOS' -derivedDataPath build/DerivedData
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit Settings picker**

Run:

```bash
git status --short
git add Perch/UI/Settings/SettingsModel.swift Perch/UI/Settings/GeneralSettingsTab.swift Perch/UI/SettingsView.swift Perch/UI/SettingsWindowController.swift
git commit -m "Add language picker to settings"
```

### Task 4: Localize Settings Detail Views

**Files:**
- Modify: `Perch/UI/Settings/AccessibilityBanner.swift`
- Modify: `Perch/UI/Settings/LayoutsSettingsTab.swift`
- Modify: `Perch/UI/Settings/AboutSettingsTab.swift`
- Modify: `Perch/UI/HotkeyRecorder.swift`

- [ ] **Step 1: Localize `AccessibilityBanner`**

Add:

```swift
@State private var localization = LocalizationManager.shared
```

Replace strings:

```swift
Text(model.hasRequestedAccessibilityPermission ? localization.text(.accessibilityBannerPendingTitle) : localization.text(.accessibilityBannerRequiredTitle))
Button(localization.text(.openSystemSettings)) { model.requestAccessibilityPermission() }
Button(localization.text(.refreshButton)) { model.refreshAccessibilityStatus() }
Button(localization.text(.resetPermissionButton)) { model.resetAccessibilityPermission() }
Button(localization.text(.restartPerch)) { ... }
```

Change `message`:

```swift
private var message: String {
    if model.hasRequestedAccessibilityPermission {
        return localization.text(.accessibilityBannerPendingMessage)
    }

    return localization.text(.accessibilityBannerRequiredMessage)
}
```

- [ ] **Step 2: Localize `LayoutsSettingsTab`**

Add:

```swift
@State private var localization = LocalizationManager.shared
```

Replace hardcoded UI strings with:

```swift
Text(localization.text(.noLayouts))
Text(localization.text(.layoutsSectionTitle))
TextField(localization.text(.newLayoutNamePlaceholder), text: $model.newLayoutName)
Button(localization.text(.addButton), action: createLayout)
Text(localization.text(.errorSectionTitle))
.alert(localization.text(.deleteLayoutTitle), isPresented: deletionBinding) { ... }
Button(localization.text(.cancelButton), role: .cancel) { pendingDeletion = nil }
Button(localization.text(.deleteButton), role: .destructive) { ... }
Text(localization.format(.deleteLayoutMessageFormat, pendingDeletion?.name ?? ""))
TextField(localization.text(.layoutNameField), text: nameBinding(for: layout))
Text(localization.format(.windowsAndShortcutFormat, layout.windows.count, localization.manager.windowNoun(count: layout.windows.count), model.effectiveHotkeyDisplay(for: layout)))
.help(localization.text(.recordRestoreShortcutHelp))
.help(localization.text(.clearCustomShortcutHelp))
.help(localization.text(.deleteLayoutHelp))
Text(localization.format(.restoreLayoutFormat, layout.name))
Button(localization.text(.cancelButton)) { recordingLayout = nil }
```

- [ ] **Step 3: Localize `AboutSettingsTab`**

Add:

```swift
@State private var localization = LocalizationManager.shared
```

Replace hardcoded strings:

```swift
Text(localization.format(.aboutVersionFormat, version))
Text(localization.text(.aboutDescriptionSummary))
Text(localization.text(.aboutDescriptionRestore))
Text(localization.text(.aboutDescriptionPrivacy))
Link(localization.text(.aboutMadeBy), destination: URL(string: "https://github.com/jurajkrivda/perch")!)
LabeledContent(localization.text(.aboutAccessibilityLabel)) { ... }
Text(model.isAccessibilityTrusted ? localization.text(.aboutGranted) : localization.text(.aboutMissing))
Button(localization.text(.openSystemSettings)) { model.requestAccessibilityPermission() }
Label(localization.text(.aboutExportDiagnostics), systemImage: "square.and.arrow.up")
Text(localization.text(.aboutDiagnosticsRedacted))
ToastWindow.show(localization.text(.diagnosticsExported))
```

- [ ] **Step 4: Localize `HotkeyRecorder`**

Initialize the label with:

```swift
private let textField = NSTextField(labelWithString: L10n.text(.hotkeyRecordPrompt))
```

Change the no-modifier message:

```swift
textField.stringValue = L10n.text(.hotkeyRequiresModifier)
```

- [ ] **Step 5: Build the app**

Run:

```bash
xcodebuild build -project Perch.xcodeproj -scheme Perch -destination 'platform=macOS' -derivedDataPath build/DerivedData
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit localized settings details**

Run:

```bash
git status --short
git add Perch/UI/Settings/AccessibilityBanner.swift Perch/UI/Settings/LayoutsSettingsTab.swift Perch/UI/Settings/AboutSettingsTab.swift Perch/UI/HotkeyRecorder.swift
git commit -m "Localize settings detail views"
```

### Task 5: Localize Menu Bar, Toasts, and User-Facing Operation Messages

**Files:**
- Modify: `Perch/Infrastructure/LaunchAtLogin.swift`
- Modify: `Perch/Core/SlotEngine.swift`
- Modify: `Perch/Core/WindowMover.swift`
- Modify: `Perch/Core/WindowSnapshotter.swift`
- Modify: `Perch/UI/MenuBarController.swift`
- Modify: `Perch/UI/ToastWindow.swift`
- Modify: `Perch/PerchApp.swift`

- [ ] **Step 1: Refresh menu when language changes**

In `MenuBarController`, add:

```swift
private var languageChangeObserver: NSObjectProtocol?
```

After `reloadSlots()` in `init(slotEngine:)`, add:

```swift
languageChangeObserver = NotificationCenter.default.addObserver(
    forName: .perchLanguageDidChange,
    object: nil,
    queue: .main
) { [weak self] _ in
    Task { @MainActor in
        self?.configureStatusItem()
        self?.rebuildMenu()
    }
}
```

Add:

```swift
deinit {
    if let languageChangeObserver {
        NotificationCenter.default.removeObserver(languageChangeObserver)
    }
}
```

- [ ] **Step 2: Localize menu titles and prompts**

Replace menu strings with:

```swift
NSMenuItem(title: L10n.text(.createLayout), action: #selector(createLayout), keyEquivalent: "")
NSMenuItem(title: L10n.text(.settingsMenuItem), action: #selector(openSettings), keyEquivalent: ",")
NSMenuItem(title: L10n.text(.quitPerch), action: #selector(quit), keyEquivalent: "q")
menu.addItem(.sectionHeader(title: L10n.text(.layoutsSectionTitle)))
NSMenuItem(title: L10n.text(.noLayoutsYet), action: nil, keyEquivalent: "")
emptyItem.toolTip = L10n.text(.noWindowsSavedYet)
let saveTitle = hasWindows
    ? L10n.format(.updateLayoutWindowsFormat, slot.name)
    : L10n.format(.saveCurrentWindowsFormat, slot.name)
let warningItem = NSMenuItem(title: L10n.text(.someShortcutsUnavailable), action: nil, keyEquivalent: "")
item.toolTip = L10n.format(.shortcutRejectedTooltipFormat, failure.status)
NSMenuItem(title: L10n.text(.restartPerch), action: #selector(restartPerch), keyEquivalent: "")
NSMenuItem(title: L10n.text(.resetAccessibilityPermission), action: #selector(resetAccessibilityPermission), keyEquivalent: "")
let reportItem = NSMenuItem(title: L10n.text(.lastRestoreReport), action: nil, keyEquivalent: "")
NSMenuItem(title: L10n.text(.allWindowsRestored), action: nil, keyEquivalent: "")
promptForLayoutName(title: L10n.text(.createLayout), defaultName: L10n.text(.newLayoutDefaultName))
alert.informativeText = L10n.text(.newLayoutNamePlaceholder)
alert.addButton(withTitle: L10n.text(.saveButton))
alert.addButton(withTitle: L10n.text(.cancelButton))
```

- [ ] **Step 3: Localize menu toasts and Accessibility menu titles**

Replace toast strings:

```swift
ToastWindow.show(L10n.text(.accessibilityGranted))
ToastWindow.show(L10n.text(.accessibilityPermissionPending))
ToastWindow.show(L10n.text(.accessibilityPermissionResetEnable))
ToastWindow.show(L10n.format(.createdLayoutFormat, layout.name))
```

Change `accessibilityMenuTitle(for:)`:

```swift
case .notRequested:
    return L10n.text(.grantAccessibilityPermission)
case .pending:
    return L10n.text(.grantAccessibilityPermissionPending)
```

- [ ] **Step 4: Localize report menu titles and tooltips**

Update `menuTooltip(for:)`:

```swift
var lines = [
    "\(L10n.text(.appLabel)): \(report.appName)",
    "\(L10n.text(.bundleIDLabel)): \(report.bundleIdentifier)",
    "\(L10n.text(.windowLabel)): \(report.windowTitle)"
]

if report.didLaunchApplication {
    lines.append(L10n.text(.openedDuringRestore))
}

if let matchReason = report.matchReason {
    lines.append("\(L10n.text(.matchedByLabel)): \(matchReason.userDescription)")
}

if let message = report.message, !message.isEmpty {
    lines.append("\(L10n.text(.reasonLabel)): \(message)")
}
```

Update `menuTitle(for:)`:

```swift
private func menuTitle(for report: RestoreWindowReport) -> String {
    let outcomeKey: LocalizationKey
    switch report.outcome {
    case .restored:
        outcomeKey = .menuOutcomeRestored
    case .launchedAndRestored:
        outcomeKey = .menuOutcomeOpenedAndRestored
    case .appNotInstalled:
        outcomeKey = .menuOutcomeNotInstalled
    case .launchFailed:
        outcomeKey = .menuOutcomeLaunchFailed
    case .appNotRunning:
        outcomeKey = .menuOutcomeClosed
    case .windowNotFound:
        outcomeKey = .menuOutcomeWindowNotFound
    case .ambiguousWindowMatch:
        outcomeKey = .menuOutcomeAmbiguousWindows
    case .frameWriteFailed:
        outcomeKey = .menuOutcomeMoveFailed
    case .skipped:
        outcomeKey = .menuOutcomeSkipped
    }

    return "\(report.appName): \(L10n.text(outcomeKey))"
}
```

- [ ] **Step 5: Localize ToastWindow count helpers**

Change:

```swift
static func showSavedWindowCount(_ count: Int, duration: TimeInterval = 1.8) {
    show(L10n.savedWindowCount(count), symbolName: Self.confirmationSymbol, duration: duration)
}

static func showRestoredWindowCount(_ restored: Int, total: Int, duration: TimeInterval = 1.8) {
    show(
        L10n.restoredWindowCount(restored: restored, total: total),
        symbolName: Self.confirmationSymbol,
        duration: duration
    )
}
```

- [ ] **Step 6: Localize launch-at-login status**

In `LaunchAtLogin.statusDescription`, replace returns:

```swift
case .enabled:
    return L10n.text(.launchStatusEnabled)
case .disabled:
    return L10n.text(.launchStatusDisabled)
case .requiresApproval:
    return L10n.text(.launchStatusRequiresApproval)
case .notRegistered:
    return L10n.text(.launchStatusUnavailable)
@unknown default:
    return L10n.text(.launchStatusUnknown)
```

- [ ] **Step 7: Localize core user-facing messages**

In `SlotOperationResult.restoreSummary`, replace the manual English composition with:

```swift
LocalizationManager.shared.restoreSummary(
    succeeded: succeeded,
    total: total,
    openedAppCount: openedAppCount
)
```

For user-facing errors and report messages, replace visible strings:

```swift
return L10n.text(.noWindowsSaved)
continuation.resume(returning: .failed(L10n.text(.applicationNotInstalled)))
message: L10n.text(.applicationNotInstalled)
message: L10n.text(.applicationClosed)
"Slot not found: \(slotID)" -> L10n.format(.slotNotFoundFormat, slotID)
"Layout name cannot be empty." -> L10n.text(.layoutNameCannotBeEmpty)
"Shortcut is already used to save \(conflict.layoutName)." -> L10n.format(.shortcutAlreadyUsedSaveFormat, conflict.layoutName)
"Shortcut is already used to restore \(conflict.layoutName)." -> L10n.format(.shortcutAlreadyUsedRestoreFormat, conflict.layoutName)
```

In `WindowMover` and `WindowSnapshotter`, localize only errors that bubble into UI/toasts:

```swift
"Accessibility permission is required to move windows." -> L10n.text(.accessibilityBannerRequiredMessage)
"Accessibility permission is required to capture windows." -> L10n.text(.accessibilityBannerRequiredMessage)
```

Leave logging-only strings unchanged.

- [ ] **Step 8: Rebuild menu after app initialization language is loaded**

In `PerchApp.swift`, no extra state is required if `LocalizationManager.shared` lazily reads `UserDefaults`. Confirm `MenuBarController` is created after `LocalizationManager.shared` is available by reading it once:

```swift
_ = LocalizationManager.shared
```

Place that before `MenuBarController(slotEngine:)` creation.

- [ ] **Step 9: Build and run tests**

Run:

```bash
xcodebuild test -project Perch.xcodeproj -scheme PerchModelTests -destination 'platform=macOS' -derivedDataPath build/DerivedData
xcodebuild build -project Perch.xcodeproj -scheme Perch -destination 'platform=macOS' -derivedDataPath build/DerivedData
```

Expected: tests pass and build succeeds.

- [ ] **Step 10: Commit menu and toast localization**

Run:

```bash
git status --short
git add Perch/Infrastructure/LaunchAtLogin.swift Perch/Core/SlotEngine.swift Perch/Core/WindowMover.swift Perch/Core/WindowSnapshotter.swift Perch/UI/MenuBarController.swift Perch/UI/ToastWindow.swift Perch/PerchApp.swift
git commit -m "Localize menu bar and operation messages"
```

### Task 6: Manual Runtime Verification

**Files:**
- No required source changes unless verification finds a defect.

- [ ] **Step 1: Launch the app**

Run:

```bash
./script/build_and_run.sh --verify
```

Expected: exit 0 and Perch is running.

- [ ] **Step 2: Verify Settings language switching**

Open Settings from the Perch menu. In General Settings, switch through:

```text
System
Čeština
Slovenčina
English
Español
Deutsch
```

Expected: visible labels in Settings change immediately after each selection without restarting Perch.

- [ ] **Step 3: Verify menu language switching**

After each language selection, open the menu bar menu again.

Expected: menu labels such as Settings, Quit Perch, Layouts, New Layout, Accessibility prompts, and Last Restore Report use the selected language.

- [ ] **Step 4: Verify toasts**

Save a layout in at least English and Czech.

Expected:

```text
English: Saved N window/windows
Czech: Uloženo 1 okno, Uložena 2 okna, or Uloženo N oken
```

- [ ] **Step 5: Run final verification**

Run:

```bash
xcodebuild test -project Perch.xcodeproj -scheme PerchModelTests -destination 'platform=macOS' -derivedDataPath build/DerivedData
xcodebuild build -project Perch.xcodeproj -scheme Perch -destination 'platform=macOS' -derivedDataPath build/DerivedData
git status --short
```

Expected: tests pass, build succeeds, and `git status --short` shows only intentional files or a clean tree after commits.

## Self-Review

- Spec coverage: The plan covers the language picker, system detection, English fallback, immediate SwiftUI redraw, AppKit menu rebuilds, UserDefaults persistence, unchanged layout data, translation coverage, and focused tests.
- Placeholder scan: The plan avoids deferred implementation markers and includes concrete file paths, commands, and Swift snippets for every code-changing task.
- Type consistency: `AppLanguage`, `LocalizationKey`, `LocalizationCatalog`, `LocalizationManager`, `L10n`, `SelectedAppLanguage`, and `.perchLanguageDidChange` are named consistently across tasks.
