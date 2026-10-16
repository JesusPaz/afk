import Foundation

/// Shared by SwiftUI, AppKit and model errors. Each device resolves its own language.
public enum L10n {
    public static func language(for preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: ["en", "es"], forPreferences: preferences).first ?? "en"
    }
    public static func text(_ key: String, language: String = language(for: Locale.preferredLanguages)) -> String {
        let supported = self.language(for: [language])
        guard let path = Bundle.module.path(forResource: supported, ofType: "lproj"), let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
    public static func serverError(_ code: String) -> String {
        let key = "server." + code
        let translated = text(key)
        return translated == key ? text("No se pudo conectar al servidor.") : translated
    }
    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
}
