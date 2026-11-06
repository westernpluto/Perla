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
    }

    /// Space on each side of the text, in points.
    static let defaultMargin = 16.0

    private static var d: UserDefaults { .standard }

    static var langCode: String { d.string(forKey: Key.lang) ?? "E" }
    static var language: PubLanguage { PubLanguage.find(langCode) }
}
