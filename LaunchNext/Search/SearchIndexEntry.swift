import Foundation

struct SearchIndexEntry {
    let displayName: String
    let normalizedName: String
    let tokens: [String]
    let acronym: String
    let transliteratedName: String?
    let transliteratedTokens: [String]
    let transliterationInitials: String
    let isTransliterationPrepared: Bool

    init(displayName: String, prepareTransliteration: Bool = false) {
        self.displayName = displayName
        self.normalizedName = Self.normalize(displayName)
        self.tokens = Self.tokenize(displayName)
        self.acronym = tokens.compactMap(\.first).map(String.init).joined()

        if prepareTransliteration {
            let transliteration = CJKTransliterator.transliteration(for: displayName)
            self.transliteratedName = transliteration?.normalizedName
            self.transliteratedTokens = transliteration?.tokens ?? []
            self.transliterationInitials = transliteration?.initials ?? ""
            self.isTransliterationPrepared = true
        } else {
            self.transliteratedName = nil
            self.transliteratedTokens = []
            self.transliterationInitials = ""
            self.isTransliterationPrepared = !CJKTransliterator.containsCJK(displayName)
        }
    }

    func preparingTransliteration() -> SearchIndexEntry {
        guard !isTransliterationPrepared else { return self }
        return SearchIndexEntry(displayName: displayName, prepareTransliteration: true)
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined()
    }

    static func tokenize(_ value: String) -> [String] {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }
}
