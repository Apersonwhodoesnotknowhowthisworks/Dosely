import Foundation

enum OpenFDAContentParser {

    struct ParsedDynamicContent: Equatable {
        let whatItDoes: String?
        let howToTake: String?
        let commonSideEffects: [String]
        let warnings: [String]
        /// Field-keyed verbatim text for any field the parser could not
        /// structure cleanly. Surfaced behind a "Show full FDA text"
        /// disclosure group rather than rendered inline.
        let rawFallback: [String: String]
    }

    // MARK: - Public API

    /// Splits a raw FDA-label string into a clean list of items, trying
    /// strategies in priority order: line-prefixed bullets, numbered lists,
    /// semicolon-separated phrases, then comma-separated phrases that follow
    /// a list-introducer like "include", "such as", "are", "consist of".
    /// Returns `[]` if nothing list-shaped is detected.
    static func parseBulletList(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let strategies: [(String) -> [String]?] = [
            tryLineBullets,
            tryNumberedList,
            trySemicolonList,
            tryIntroducerCommaList
        ]
        for strategy in strategies {
            if let candidates = strategy(trimmed) {
                let cleaned = candidates.compactMap(cleanItem)
                if cleaned.count >= 2 { return cleaned }
            }
        }
        return []
    }

    /// Returns the first sentence of `raw`, respecting common abbreviations
    /// (e.g., i.e., Dr., Mrs.) and truncating at a word boundary if the
    /// sentence exceeds `max` characters.
    static func summarizeFirstSentence(_ raw: String, max: Int = 220) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var sentenceEnd: String.Index?
        var i = trimmed.startIndex
        while i < trimmed.endIndex {
            if trimmed[i] == "." {
                let next = trimmed.index(after: i)
                if next < trimmed.endIndex, trimmed[next] == " " {
                    let wordStart = trimmed[..<i]
                        .lastIndex(where: { $0.isWhitespace })
                        .map { trimmed.index(after: $0) } ?? trimmed.startIndex
                    let wordPlusDot = String(trimmed[wordStart...i])
                    if abbreviations.contains(wordPlusDot.lowercased()) {
                        i = trimmed.index(after: next)
                        continue
                    }
                    sentenceEnd = i
                    break
                }
            }
            i = trimmed.index(after: i)
        }

        let sentence: String
        if let end = sentenceEnd {
            sentence = String(trimmed[...end])
        } else {
            sentence = trimmed
        }

        if sentence.count <= max { return sentence }

        let truncated = String(sentence.prefix(max))
        if let lastSpace = truncated.lastIndex(of: " ") {
            var head = String(truncated[..<lastSpace])
            while let last = head.last, ".,;:".contains(last) {
                head.removeLast()
            }
            return head + "…"
        }
        return String(truncated.prefix(max - 1)) + "…"
    }

    /// Parses an `OpenFDADrug` into the structured shape that the dynamic
    /// branch of `MedicationDetailView` renders. Falls back to a single-item
    /// list (the first sentence) for fields where list-detection fails — and
    /// in that case stashes the verbatim text in `rawFallback` so the UI can
    /// expose it via a "Show full FDA text" disclosure.
    static func parse(_ drug: OpenFDADrug) -> ParsedDynamicContent {
        var rawFallback: [String: String] = [:]

        let whatItDoes: String? = {
            guard let raw = drug.indications,
                  !raw.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            let summary = summarizeFirstSentence(raw)
            return summary.isEmpty ? nil : summary
        }()

        let howToTake: String? = {
            guard let raw = drug.dosageAndAdministration,
                  !raw.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            let (stripped, didStrip) = stripTakeItNow(raw)
            let firstParagraph = stripped
                .components(separatedBy: CharacterSet.newlines)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                ?? stripped
            let summary = summarizeFirstSentence(firstParagraph)
            guard !summary.isEmpty else { return nil }
            return didStrip
                ? "\(summary) Always follow your doctor's instructions."
                : summary
        }()

        var commonSideEffects = parseBulletList(drug.adverseReactions ?? "")
        if commonSideEffects.isEmpty,
           let raw = drug.adverseReactions,
           !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let summary = summarizeFirstSentence(raw)
            if !summary.isEmpty {
                commonSideEffects = [summary]
                rawFallback["Side effects"] = raw
            }
        }

        var warnings = parseBulletList(drug.warnings ?? "")
        if warnings.isEmpty,
           let raw = drug.warnings,
           !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let summary = summarizeFirstSentence(raw)
            if !summary.isEmpty {
                warnings = [summary]
                rawFallback["Warnings"] = raw
            }
        }

        return ParsedDynamicContent(
            whatItDoes: whatItDoes,
            howToTake: howToTake,
            commonSideEffects: commonSideEffects,
            warnings: warnings,
            rawFallback: rawFallback
        )
    }

    // MARK: - Strategy: line-prefixed bullets

    private static let unambiguousBullets: Set<Character> = ["•", "·", "▪"]

    private static func tryLineBullets(_ raw: String) -> [String]? {
        let lines = raw.components(separatedBy: .newlines)
        let bulletLines: [String] = lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first else { return nil }
            if unambiguousBullets.contains(first) {
                return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            // Asterisk and hyphen are only treated as bullet markers when
            // followed by whitespace, to avoid eating real punctuation
            // (hyphenated phrases, asterisked footnote refs, etc.).
            if first == "*" || first == "-", trimmed.count >= 2 {
                let second = trimmed[trimmed.index(after: trimmed.startIndex)]
                if second.isWhitespace {
                    return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }
        return bulletLines.count >= 2 ? bulletLines : nil
    }

    // MARK: - Strategy: numbered lists

    private static let numberedListPattern = #"(?:^|\s)(?:\(\d+\)|\d+[.)])\s+"#

    private static func tryNumberedList(_ raw: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: numberedListPattern) else { return nil }
        let nsString = raw as NSString
        let range = NSRange(location: 0, length: nsString.length)
        let matches = regex.matches(in: raw, range: range)
        guard matches.count >= 2 else { return nil }

        var items: [String] = []
        for (i, match) in matches.enumerated() {
            let itemStart = match.range.upperBound
            let itemEnd = i + 1 < matches.count
                ? matches[i + 1].range.lowerBound
                : nsString.length
            guard itemEnd > itemStart else { continue }
            let item = nsString.substring(with: NSRange(location: itemStart, length: itemEnd - itemStart))
            items.append(item.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return items.isEmpty ? nil : items
    }

    // MARK: - Strategy: semicolon-separated phrases

    private static func trySemicolonList(_ raw: String) -> [String]? {
        let parts = raw
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.count >= 2 ? parts : nil
    }

    // MARK: - Strategy: introducer + comma list

    private static let introducerPattern =
        #"\b(?:includes?|such as|may include|are|consist[s]? of)\s+([^.]+?)(?:\.|$)"#

    private static func tryIntroducerCommaList(_ raw: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: introducerPattern,
                                                   options: .caseInsensitive) else { return nil }
        let nsString = raw as NSString
        let nsRange = NSRange(location: 0, length: nsString.length)
        for match in regex.matches(in: raw, range: nsRange) {
            guard match.numberOfRanges >= 2 else { continue }
            let listRange = match.range(at: 1)
            guard listRange.location != NSNotFound else { continue }
            let listText = nsString.substring(with: listRange)
            var items = listText
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            items = items.map(stripLeadingConnector)
            // Drop trailing non-restrictive clauses like "were reported" that
            // were comma-attached to the list. "such as A, B, C, were reported."
            // → ["A", "B", "C"].
            items = items.filter { item in
                let firstWord = item.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
                return !nonItemPrefixes.contains(firstWord)
            }
            if items.count >= 2 { return items }
        }
        return nil
    }

    private static let nonItemPrefixes: Set<String> = [
        "were", "was", "is", "are", "have", "has",
        "may", "can", "should", "must", "will", "do", "does"
    ]

    private static func stripLeadingConnector(_ s: String) -> String {
        let lower = s.lowercased()
        for connector in ["and ", "or "] {
            if lower.hasPrefix(connector) {
                return String(s.dropFirst(connector.count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }

    // MARK: - Item cleanup

    private static func cleanItem(_ s: String) -> String? {
        var trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, ".,;:".contains(last) {
            trimmed.removeLast()
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.count <= 140 else { return nil }
        return trimmed
    }

    // MARK: - Take-it-now sanitiser (B.1 S2)

    private static let takeItNowPattern = #"(take it now|take immediately)"#

    private static func stripTakeItNow(_ raw: String) -> (String, Bool) {
        guard let regex = try? NSRegularExpression(pattern: takeItNowPattern,
                                                   options: .caseInsensitive) else {
            return (raw, false)
        }
        let nsRange = NSRange(raw.startIndex..., in: raw)
        let count = regex.numberOfMatches(in: raw, range: nsRange)
        guard count > 0 else { return (raw, false) }
        let stripped = regex.stringByReplacingMatches(in: raw, range: nsRange, withTemplate: "")
        return (stripped.trimmingCharacters(in: .whitespacesAndNewlines), true)
    }

    // MARK: - Abbreviations honoured during sentence detection

    private static let abbreviations: Set<String> = [
        "e.g.", "i.e.", "dr.", "mr.", "mrs.", "ms.", "vs.", "etc.",
        "inc.", "ltd.", "jr.", "sr.", "st.", "approx.", "fig.",
        "no.", "vol.", "p.", "pp."
    ]
}
