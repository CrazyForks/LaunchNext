import Foundation

struct SearchMatch {
    enum Source: Int {
        case transliteration
        case original
    }

    let source: Source
    let score: Int
}

struct FuzzyMatcher {
    func score(query: String, entry: SearchIndexEntry) -> SearchMatch? {
        let normalizedQuery = SearchIndexEntry.normalize(query)
        guard !normalizedQuery.isEmpty else { return nil }

        if let originalScore = originalScore(query: normalizedQuery, entry: entry) {
            return SearchMatch(source: .original, score: originalScore)
        }

        guard normalizedQuery.unicodeScalars.allSatisfy({
            $0.isASCII && CharacterSet.alphanumerics.contains($0)
        }), let transliterationScore = transliterationScore(query: normalizedQuery, entry: entry) else {
            return nil
        }

        return SearchMatch(source: .transliteration, score: transliterationScore)
    }

    private func originalScore(query normalizedQuery: String, entry: SearchIndexEntry) -> Int? {
        if entry.normalizedName == normalizedQuery {
            return 1_000
        }

        if entry.normalizedName.hasPrefix(normalizedQuery) {
            return 700 - min(80, max(0, entry.normalizedName.count - normalizedQuery.count))
        }

        if let tokenIndex = entry.tokens.firstIndex(where: { $0.hasPrefix(normalizedQuery) }) {
            return 520 - min(tokenIndex * 15, 120)
        }

        if !entry.acronym.isEmpty, entry.acronym.hasPrefix(normalizedQuery) {
            return 470 - min(max(0, entry.acronym.count - normalizedQuery.count) * 10, 80)
        }

        if let subsequenceScore = subsequenceScore(query: normalizedQuery, target: entry.normalizedName) {
            return subsequenceScore
        }

        if entry.normalizedName.contains(normalizedQuery) {
            return 180
        }

        return nil
    }

    private func transliterationScore(query normalizedQuery: String,
                                      entry: SearchIndexEntry) -> Int? {
        guard let transliteratedName = entry.transliteratedName else { return nil }

        if transliteratedName == normalizedQuery {
            return 1_000
        }

        if transliteratedName.hasPrefix(normalizedQuery) {
            return 700 - min(80, max(0, transliteratedName.count - normalizedQuery.count))
        }

        if let tokenIndex = entry.transliteratedTokens.firstIndex(where: { $0.hasPrefix(normalizedQuery) }) {
            return 520 - min(tokenIndex * 15, 120)
        }

        if !entry.transliterationInitials.isEmpty,
           entry.transliterationInitials == normalizedQuery {
            return 500
        }

        if !entry.transliterationInitials.isEmpty,
           entry.transliterationInitials.hasPrefix(normalizedQuery) {
            return 470 - min(
                max(0, entry.transliterationInitials.count - normalizedQuery.count) * 10,
                80
            )
        }

        return nil
    }

    private func subsequenceScore(query: String, target: String) -> Int? {
        var positions: [Int] = []
        var searchStart = target.startIndex

        for character in query {
            guard let matchIndex = target[searchStart...].firstIndex(of: character) else {
                return nil
            }
            positions.append(target.distance(from: target.startIndex, to: matchIndex))
            searchStart = target.index(after: matchIndex)
        }

        guard let first = positions.first, let last = positions.last else { return nil }

        let span = last - first + 1
        let gaps = max(0, span - query.count)
        let adjacencyCount = zip(positions, positions.dropFirst()).reduce(0) { partial, pair in
            partial + (pair.1 == pair.0 + 1 ? 1 : 0)
        }
        let leadingBonus = max(0, 40 - first * 2)
        let compactnessBonus = max(0, 80 - gaps * 5)
        let adjacencyBonus = adjacencyCount * 12

        return 300 + leadingBonus + compactnessBonus + adjacencyBonus
    }
}
