import Foundation

/// English source keys share Bundle.main's language selection with SwiftUI literals.
enum L10n {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }

    /// Keep system formatters in the app's selected language, including English fallback.
    static var locale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }
}
