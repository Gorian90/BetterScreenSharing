import Foundation

/// Appens språk. Engelska är standard oavsett systemets språk.
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case english = "en"
    case swedish = "sv"

    var id: String { rawValue }

    /// Varje språk heter sitt eget namn, så att det går att hitta tillbaka även om man valt fel.
    var label: String {
        switch self {
        case .english: "English"
        case .swedish: "Svenska"
        }
    }
}

enum Lang {
    static let key = "language"

    /// Läses av texter överallt, även utanför huvudtråden (t.ex. den virtuella skärmens namn).
    /// Skrivs bara från AppState på huvudtråden.
    nonisolated(unsafe) static var current: AppLanguage =
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) ?? .english
}

/// Texten på det valda språket. Båda språken står bredvid varandra i koden, så att de inte glider isär
/// och appen klarar sig utan strängfiler i paketet.
func L(_ en: String, _ sv: String, in language: AppLanguage = Lang.current) -> String {
    language == .swedish ? sv : en
}

/// Standardtext som användaren kan skriva över. Vid språkbyte översätts den bara om den är orörd.
struct Phrase {
    let en: String
    let sv: String

    var text: String { L(en, sv) }
    func text(in language: AppLanguage) -> String { L(en, sv, in: language) }

    static let nothingShared = Phrase(en: "Nothing is being shared right now", sv: "Inget delas just nu")
    static let windowClosed = Phrase(en: "The window has been closed", sv: "Fönstret har stängts")
    static let backShortly = Phrase(en: "Back shortly", sv: "Strax tillbaka")
    static let breakMessage = Phrase(en: "Break – we'll be right back", sv: "Paus – vi fortsätter strax")
    static let welcomeBack = Phrase(en: "Welcome back", sv: "Välkomna tillbaka")
    static let resumeAt = Phrase(en: "We'll resume at", sv: "Vi fortsätter klockan")
}
