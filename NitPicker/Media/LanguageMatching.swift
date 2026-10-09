import Foundation

enum LanguageMatching {
    private static let bibliographic: [String: String] = [
        "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "chi": "zh", "cze": "cs", "dut": "nl", "fre": "fr", "geo": "ka", "ger": "de",
        "gre": "el", "ice": "is", "mac": "mk", "mao": "mi", "may": "ms", "per": "fa", "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy",
    ]

    /// Lowercase two-letter primary language (`"en-US"`, `"eng"` and `"en_GB"` all give `"en"`).
    static func primaryLanguage(_ identifier: String) -> String {
        let primary = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? ""
        guard primary.count == 3 else { return primary }
        // Matroska and AVI files often use ISO 639-2/B ("fre", "ger", "chi"), which Foundation doesn't know.
        return bibliographic[primary] ?? Locale.LanguageCode(primary).identifier(.alpha2) ?? primary
    }

    static func matches(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        return primaryLanguage(a) == primaryLanguage(b)
    }
}
