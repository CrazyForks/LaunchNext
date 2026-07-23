import Foundation

struct SearchTransliteration {
    let normalizedName: String
    let tokens: [String]
    let initials: String
}

enum CJKTransliterator {
    private enum Language {
        case chinese
        case japanese
        case korean
    }

    private struct TranscribedToken {
        let original: String
        let normalized: String
    }

    static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            isHan(scalar) || isKana(scalar) || isHangul(scalar)
        }
    }

    static func transliteration(for value: String) -> SearchTransliteration? {
        guard let (language, localeIdentifier) = languageAndLocale(for: value) else {
            return nil
        }

        let transcribedTokens = tokens(for: value, localeIdentifier: localeIdentifier)
        guard !transcribedTokens.isEmpty else {
            return fallbackTransliteration(for: value, language: language)
        }

        let normalizedTokens = transcribedTokens.map(\.normalized).filter { !$0.isEmpty }
        let normalizedName = normalizedTokens.joined()
        guard !normalizedName.isEmpty else { return nil }

        let initials: String
        if language == .chinese {
            initials = transcribedTokens
                .map { chineseInitials(original: $0.original, contextualTranscription: $0.normalized) }
                .joined()
        } else {
            initials = ""
        }

        return SearchTransliteration(normalizedName: normalizedName,
                                     tokens: normalizedTokens,
                                     initials: initials)
    }

    private static func languageAndLocale(for value: String) -> (Language, String)? {
        let scalars = value.unicodeScalars
        if scalars.contains(where: isKana) {
            return (.japanese, "ja_JP")
        }
        if scalars.contains(where: isHangul) {
            return (.korean, "ko_KR")
        }
        guard scalars.contains(where: isHan) else { return nil }

        let range = CFRange(location: 0, length: (value as NSString).length)
        let detected = CFStringTokenizerCopyBestStringLanguage(value as CFString, range)
            .map { String(describing: $0) }

        if let detected {
            if detected.hasPrefix("ja") {
                return (.japanese, detected)
            }
            if detected.hasPrefix("ko") {
                return (.korean, detected)
            }
            if detected.hasPrefix("zh") {
                return (.chinese, detected)
            }
        }

        let currentLanguage = Locale.current.language.languageCode?.identifier
        if currentLanguage == "ja" {
            return (.japanese, "ja_JP")
        }
        if currentLanguage == "ko" {
            return (.korean, "ko_KR")
        }
        return (.chinese, "zh_CN")
    }

    private static func tokens(for value: String, localeIdentifier: String) -> [TranscribedToken] {
        let length = (value as NSString).length
        guard length > 0 else { return [] }

        let localeID = CFLocaleIdentifier(rawValue: localeIdentifier as CFString)
        guard let locale = CFLocaleCreate(kCFAllocatorDefault, localeID),
              let tokenizer = CFStringTokenizerCreate(
                kCFAllocatorDefault,
                value as CFString,
                CFRange(location: 0, length: length),
                kCFStringTokenizerUnitWord | kCFStringTokenizerAttributeLatinTranscription,
                locale
              ) else {
            return []
        }

        var result: [TranscribedToken] = []
        let source = value as NSString

        while true {
            let tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
            guard tokenType.rawValue != 0 else { break }

            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard tokenRange.location != kCFNotFound,
                  tokenRange.length > 0,
                  tokenRange.location + tokenRange.length <= length else {
                continue
            }

            let original = source.substring(
                with: NSRange(location: tokenRange.location, length: tokenRange.length)
            )
            let attribute = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer,
                kCFStringTokenizerAttributeLatinTranscription
            )
            let transcription = attribute.map { String(describing: $0) } ?? original
            let normalized = SearchIndexEntry.normalize(transcription)
            guard !normalized.isEmpty else { continue }

            result.append(TranscribedToken(original: original, normalized: normalized))
        }

        return result
    }

    private static func fallbackTransliteration(for value: String,
                                                language: Language) -> SearchTransliteration? {
        guard let transcription = value.applyingTransform(.toLatin, reverse: false) else {
            return nil
        }
        let normalizedName = SearchIndexEntry.normalize(transcription)
        guard !normalizedName.isEmpty else { return nil }

        let initials: String
        if language == .chinese {
            initials = fallbackSyllables(for: value).compactMap(\.first).map(String.init).joined()
        } else {
            initials = ""
        }

        return SearchTransliteration(normalizedName: normalizedName,
                                     tokens: [normalizedName],
                                     initials: initials)
    }

    private static func chineseInitials(original: String,
                                        contextualTranscription: String) -> String {
        let fallback = fallbackSyllables(for: original)
        guard !fallback.isEmpty else { return "" }

        let contextualSyllables = align(contextualTranscription, with: fallback) ?? fallback
        return contextualSyllables.compactMap(\.first).map(String.init).joined()
    }

    private static func fallbackSyllables(for value: String) -> [String] {
        value.compactMap { character in
            let component = String(character)
            let rawTranscription: String
            if component.unicodeScalars.contains(where: isHan) {
                rawTranscription = component.applyingTransform(.mandarinToLatin, reverse: false) ?? component
            } else {
                rawTranscription = component
            }
            let normalized = SearchIndexEntry.normalize(rawTranscription)
            return normalized.isEmpty ? nil : normalized
        }
    }

    private static func align(_ contextual: String, with hints: [String]) -> [String]? {
        let target = Array(contextual)
        let hintCount = hints.count
        guard hintCount > 0, target.count >= hintCount else { return nil }

        let unreachable = Int.max / 4
        var costs = Array(
            repeating: Array(repeating: unreachable, count: target.count + 1),
            count: hintCount + 1
        )
        var previous = Array(
            repeating: Array(repeating: -1, count: target.count + 1),
            count: hintCount + 1
        )
        costs[0][0] = 0

        for hintIndex in 0..<hintCount {
            for start in 0...target.count where costs[hintIndex][start] < unreachable {
                let remainingHints = hintCount - hintIndex - 1
                let maximumEnd = target.count - remainingHints
                guard start + 1 <= maximumEnd else { continue }

                for end in (start + 1)...maximumEnd {
                    let segment = String(target[start..<end])
                    let hint = hints[hintIndex]
                    let editCost = editDistance(segment, hint)
                    let lengthCost = abs(segment.count - hint.count)
                    let candidateCost = costs[hintIndex][start] + editCost * 10 + lengthCost

                    if candidateCost < costs[hintIndex + 1][end] {
                        costs[hintIndex + 1][end] = candidateCost
                        previous[hintIndex + 1][end] = start
                    }
                }
            }
        }

        guard costs[hintCount][target.count] < unreachable else { return nil }

        var result = Array(repeating: "", count: hintCount)
        var end = target.count
        for hintIndex in stride(from: hintCount, through: 1, by: -1) {
            let start = previous[hintIndex][end]
            guard start >= 0 else { return nil }
            result[hintIndex - 1] = String(target[start..<end])
            end = start
        }
        return end == 0 ? result : nil
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1

            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                current[rightIndex + 1] = min(substitution, insertion, deletion)
            }
            previous = current
        }
        return previous[right.count]
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2FA1F,
             0x30000...0x323AF:
            return true
        default:
            return false
        }
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,
             0x31F0...0x31FF,
             0x1B000...0x1B16F:
            return true
        default:
            return false
        }
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF,
             0x3130...0x318F,
             0xA960...0xA97F,
             0xAC00...0xD7AF,
             0xD7B0...0xD7FF:
            return true
        default:
            return false
        }
    }
}
