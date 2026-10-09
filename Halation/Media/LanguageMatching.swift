import Foundation

enum LanguageMatching {
    /// Lowercase two-letter primary language (`"en-US"`, `"eng"` and `"en_GB"` all give `"en"`).
    static func primaryLanguage(_ identifier: String) -> String {
        let primary = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? ""
        guard primary.count == 3 else { return primary }
        return Locale.LanguageCode(primary).identifier(.alpha2) ?? primary
    }

    static func matches(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        return primaryLanguage(a) == primaryLanguage(b)
    }
}
