import Foundation

/// A language that jw.org publishes in. `code` is jw.org's own language code.
struct PubLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    let native: String
    let locale: String
    /// Labels the answers use for their extra lines, in the publication's language.
    let application: String
    let askYourself: String
    let source: String
    var id: String { code }

    static let all: [PubLanguage] = [
        PubLanguage(code: "E", name: "English", native: "English", locale: "en",
                    application: "Application", askYourself: "Ask yourself", source: "Source"),
        PubLanguage(code: "S", name: "Spanish", native: "Español", locale: "es",
                    application: "Aplicación", askYourself: "Pregúntese", source: "Fuente"),
        PubLanguage(code: "F", name: "French", native: "Français", locale: "fr",
                    application: "Application", askYourself: "Demandez-vous", source: "Source"),
        PubLanguage(code: "T", name: "Portuguese", native: "Português", locale: "pt",
                    application: "Aplicação", askYourself: "Pergunte-se", source: "Fonte"),
        PubLanguage(code: "X", name: "German", native: "Deutsch", locale: "de",
                    application: "Anwendung", askYourself: "Frag dich", source: "Quelle"),
        PubLanguage(code: "I", name: "Italian", native: "Italiano", locale: "it",
                    application: "Applicazione", askYourself: "Chiediti", source: "Fonte"),
    ]

    static func find(_ code: String) -> PubLanguage {
        all.first { $0.code == code } ?? all[0]
    }

    /// Every label prefix in every language, used to style answer lines.
    static var sourcePrefixes: [String] { all.map { $0.source + ":" } + ["Sources:", "Fuentes:"] }
    static var askPrefixes: [String] { all.map { $0.askYourself + ":" } + ["Pregúntate:"] }
    static var applicationPrefixes: [String] { all.map { $0.application + ":" } }
}

enum Prefs {
    enum Key {
        static let lang = "pubLanguage"
        static let textScale = "textScale"
        static let serif = "serifFont"
        static let margin = "sideMargin"
        /// The app's own language: "" follows the iPhone, otherwise "en", "es", "fr", "pt", "de", "it".
        static let appLang = "appLanguage"
    }

    /// Space on each side of the text, in points.
    static let defaultMargin = 16.0

    private static var d: UserDefaults { .standard }

    static var langCode: String { d.string(forKey: Key.lang) ?? "E" }
    static var language: PubLanguage { PubLanguage.find(langCode) }
}

/// The language of the app itself (menus, buttons, messages), separate from the publications' language.
enum AppLanguage {
    static let choices: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Español"), ("fr", "Français"), ("pt", "Português"), ("de", "Deutsch"), ("it", "Italiano"),
    ]

    /// The chosen language code, or the iPhone's language when Perla has a translation for it.
    static var code: String {
        let chosen = UserDefaults.standard.string(forKey: Prefs.Key.appLang) ?? ""
        if !chosen.isEmpty { return chosen }
        let preferred = Bundle.preferredLocalizations(from: choices.map(\.code), forPreferences: Locale.preferredLanguages)
        return preferred.first ?? "en"
    }

    static var locale: Locale { Locale(identifier: code) }

    /// The translations for the current language (English text is the key, so English needs none).
    static var bundle: Bundle {
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path) { return b }
        return Bundle.main
    }
}

/// Interface text in the app's language. The English text is the key.
func L(_ key: String) -> String {
    AppLanguage.bundle.localizedString(forKey: key, value: key, table: nil)
}

/// Interface text with values filled in: L("Imported %lld answers.", n).
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: AppLanguage.locale, arguments: args)
}
