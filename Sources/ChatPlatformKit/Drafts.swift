#if canImport(UIKit)
import Foundation

/// Unsent input text, kept per conversation across launches.
struct DraftStore {
    var defaults: UserDefaults = .standard
    var key: String

    func load() -> String { defaults.string(forKey: key) ?? "" }

    func save(_ text: String) {
        if text.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(text, forKey: key) }
    }
}
#endif
