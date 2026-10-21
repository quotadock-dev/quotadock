import Foundation

enum DockLanguage: String, CaseIterable, Identifiable {
    case system, en, ko
    var id: String { rawValue }
}

/// Only a language code is shared with extensions; never identity or credentials.
enum DockL10n {
    static let languageKey = "interfaceLanguage"
    static var preferences: UserDefaults {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AppGroup") as? String,
              let shared = UserDefaults(suiteName: group) else { return .standard }
        return shared
    }

    static func selection(in defaults: UserDefaults = preferences) -> DockLanguage {
        DockLanguage(rawValue: defaults.string(forKey: languageKey) ?? "") ?? .system
    }

    static func resolved(_ selection: DockLanguage, preferred: [String] = Locale.preferredLanguages) -> String {
        if selection != .system { return selection.rawValue }
        for language in preferred {
            let base = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
            if base == "ko" { return "ko" }
            if base == "en" { return "en" }
        }
        return "en"
    }

    static var language: String { resolved(selection()) }
    static var locale: Locale { Locale(identifier: language) }

    static func save(_ selection: DockLanguage, in defaults: UserDefaults = preferences) {
        defaults.set(selection.rawValue, forKey: languageKey)
    }

    static func text(_ key: String, table: String = "Localizable", language: String? = nil) -> String {
        let code = language == "ko" ? "ko" : language == "en" ? "en" : self.language
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: table)
    }

    static func format(_ key: String, _ arguments: CVarArg..., table: String = "Localizable") -> String {
        String(format: text(key, table: table), locale: locale, arguments: arguments)
    }

    static func date(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }
}
