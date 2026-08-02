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

    /// Each language names itself so the picker stays readable in any UI language.
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
