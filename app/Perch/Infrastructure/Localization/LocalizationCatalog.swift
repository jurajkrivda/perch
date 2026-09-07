import Foundation

struct LocalizationCatalog: Sendable {
    static let `default` = LocalizationCatalog(translations: defaultTranslations)

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

    // Dictionaries follow the LocalizationKey declaration order; the completeness
    // test fails the build when any language misses any key.
    private static let defaultTranslations: [AppLanguage: [LocalizationKey: String]] = [
        .english: english,
        .czech: czech,
        .slovak: slovak,
        .spanish: spanish,
        .german: german
    ]
}
