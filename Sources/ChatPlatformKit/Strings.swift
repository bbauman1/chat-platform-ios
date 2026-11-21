#if canImport(UIKit)
import Foundation

/// The SDK's UI strings: English, Spanish and German, chosen by the app's
/// preferred languages unless a language is forced (tests, or apps whose UI
/// language differs from the device).
public struct ChatStrings: Sendable {
    let bundle: Bundle
    public let locale: Locale
    /// Languages to pick dashboard texts (title, empty state) in, best first:
    /// the forced language, or the user's preferred languages.
    let languages: [String]
    var overrides: [String: String] = [:]

    /// - Parameter language: `"en"`, `"es"` or `"de"`; nil follows the app.
    public init(language: String? = nil) {
        let module = Bundle.module
        let chosen = language
            ?? Bundle.preferredLocalizations(from: module.localizations, forPreferences: nil).first
            ?? "en"
        if let path = module.path(forResource: chosen, ofType: "lproj"), let bundle = Bundle(path: path) {
            self.bundle = bundle
        } else {
            self.bundle = module
        }
        locale = Locale(identifier: chosen)
        languages = language.map { [$0] } ?? (Locale.preferredLanguages + [chosen])
    }

    func callAsFunction(_ key: String) -> String {
        overrides[key] ?? bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    /// Replaces one string, already localized by the caller (the support team
    /// app names the customer instead of "Support").
    @_spi(AgentApp) public func replacing(_ key: String, with value: String) -> ChatStrings {
        var copy = self
        copy.overrides[key] = value
        return copy
    }
}
#endif
