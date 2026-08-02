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
        String(
            format: text(key),
            locale: Locale(identifier: effectiveLanguage.localeIdentifier),
            arguments: arguments
        )
    }

    // Count-based messages use explicit per-language forms because Czech and
    // Slovak inflect both the noun and the verb by count (1 / 2-4 / 5+).

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
            return "Fenster"
        case .english, .system:
            return count == 1 ? "window" : "windows"
        }
    }

    func savedWindowCount(_ count: Int) -> String {
        switch effectiveLanguage {
        case .czech:
            if count == 1 { return "Uloženo 1 okno" }
            if (2...4).contains(count) { return "Uložena \(count) okna" }
            return "Uloženo \(count) oken"
        case .slovak:
            if count == 1 { return "Uložené 1 okno" }
            if (2...4).contains(count) { return "Uložené \(count) okná" }
            return "Uložených \(count) okien"
        case .spanish:
            return count == 1 ? "Guardada 1 ventana" : "Guardadas \(count) ventanas"
        case .german:
            return "\(count) Fenster gespeichert"
        case .english, .system:
            return count == 1 ? "Saved 1 window" : "Saved \(count) windows"
        }
    }

    func restoreSummary(succeeded: Int, total: Int, openedAppCount: Int) -> String {
        switch effectiveLanguage {
        case .czech:
            var parts = ["Obnoveno \(succeeded)/\(total)"]
            if openedAppCount == 1 {
                parts.append("otevřena 1 aplikace")
            } else if (2...4).contains(openedAppCount) {
                parts.append("otevřeny \(openedAppCount) aplikace")
            } else if openedAppCount > 0 {
                parts.append("otevřeno \(openedAppCount) aplikací")
            }
            return parts.joined(separator: "; ")
        case .slovak:
            var parts = ["Obnovené \(succeeded)/\(total)"]
            if openedAppCount == 1 {
                parts.append("otvorená 1 aplikácia")
            } else if (2...4).contains(openedAppCount) {
                parts.append("otvorené \(openedAppCount) aplikácie")
            } else if openedAppCount > 0 {
                parts.append("otvorených \(openedAppCount) aplikácií")
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
