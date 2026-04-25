import Foundation

enum FieldConfidence: Equatable {
    case high      // ≥ 0.8
    case medium    // 0.5 ..< 0.8
    case low       // < 0.5 or no match

    static func from(_ raw: Float) -> FieldConfidence {
        if raw >= 0.8 { return .high }
        if raw >= 0.5 { return .medium }
        return .low
    }
}

struct ParsedField<T: Equatable>: Equatable {
    let value: T?
    let confidence: FieldConfidence

    static var empty: ParsedField<T> { ParsedField(value: nil, confidence: .low) }
}

struct ParsedPrescription: Equatable {
    var name:         ParsedField<String>
    var dose:         ParsedField<String>      // e.g. "10mg"
    var frequency:    ParsedField<String>      // human readable
    var foodRule:     ParsedField<String>      // "with" / "without" / "either"
    var quantity:     ParsedField<Int>
    var pillsPerDose: ParsedField<Int>
    var rawLines:     [RecognizedTextLine]

    /// True when the parser found nothing useful — used to route to manual entry.
    var allFieldsLow: Bool {
        name.confidence == .low &&
        dose.confidence == .low &&
        frequency.confidence == .low &&
        foodRule.confidence == .low &&
        quantity.confidence == .low &&
        pillsPerDose.confidence == .low
    }

    static var empty: ParsedPrescription {
        ParsedPrescription(
            name: .empty, dose: .empty, frequency: .empty,
            foodRule: .empty, quantity: .empty, pillsPerDose: .empty,
            rawLines: []
        )
    }
}

enum PrescriptionParser {

    static func parse(_ lines: [RecognizedTextLine]) -> ParsedPrescription {
        let aggregated = lines.map(\.text).joined(separator: "\n")

        return ParsedPrescription(
            name:         parseName(lines: lines),
            dose:         parseDose(text: aggregated, lines: lines),
            frequency:    parseFrequency(text: aggregated, lines: lines),
            foodRule:     parseFoodRule(text: aggregated),
            quantity:     parseQuantity(text: aggregated, lines: lines),
            pillsPerDose: parsePillsPerDose(text: aggregated),
            rawLines:     lines
        )
    }

    // MARK: - Name

    /// Words that signal a line is the pharmacy / clinic banner, not the
    /// medication name. We strip these out before picking the topmost line.
    private static let nonMedicationKeywords: [String] = [
        "pharmacy", "drugstore", "drug store", "apothecary",
        "clinic", "hospital", "health", "medical center",
        "rx number", "refills"
    ]

    private static func parseName(lines: [RecognizedTextLine]) -> ParsedField<String> {
        let doseRegex = try? NSRegularExpression(pattern: dosePattern, options: .caseInsensitive)
        let candidates = lines.filter { line in
            guard line.confidence > 0.3 else { return false }
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3 else { return false }
            // Require at least 3 alphabetic characters so we skip pure numbers.
            let alphaCount = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            guard alphaCount >= 3 else { return false }
            // Skip lines that are essentially a dose pattern.
            if let doseRegex,
               doseRegex.firstMatch(in: trimmed,
                                    options: [],
                                    range: NSRange(trimmed.startIndex..., in: trimmed)) != nil,
               trimmed.count <= 12 {
                return false
            }
            // Skip instruction prefixes.
            let lower = trimmed.lowercased()
            if lower.hasPrefix("take ") || lower.hasPrefix("use ") { return false }
            // Skip pharmacy / clinic banners.
            if nonMedicationKeywords.contains(where: { lower.contains($0) }) {
                return false
            }
            return true
        }
        guard let topMost = candidates.max(by: { $0.boundingBox.maxY < $1.boundingBox.maxY }) else {
            return .empty
        }
        let cleaned = cleanupName(topMost.text)
        guard !cleaned.isEmpty else { return .empty }
        return ParsedField(value: cleaned, confidence: FieldConfidence.from(topMost.confidence))
    }

    private static func cleanupName(_ s: String) -> String {
        let firstLine = s
            .components(separatedBy: .newlines)
            .first ?? s
        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Dose

    private static let dosePattern =
        #"\b(\d+(?:\.\d+)?)\s*(mg|mcg|g|ml|iu|units?)\b"#

    private static func parseDose(text: String, lines: [RecognizedTextLine]) -> ParsedField<String> {
        guard let regex = try? NSRegularExpression(pattern: dosePattern, options: .caseInsensitive) else {
            return .empty
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges >= 3 else { return .empty }
        let nsString = text as NSString
        let number = nsString.substring(with: match.range(at: 1))
        let unit   = nsString.substring(with: match.range(at: 2)).lowercased()
        let dose = "\(number)\(unit)"

        let containingConfidence = bestConfidence(in: lines, matching: regex) ?? 0.65
        return ParsedField(value: dose, confidence: FieldConfidence.from(containingConfidence))
    }

    // MARK: - Frequency

    private struct FrequencyMapping {
        let regex: NSRegularExpression?
        let label: String
        init(_ pattern: String, _ label: String) {
            self.regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            self.label = label
        }
    }

    /// Order matters — more specific patterns first. `(?:day|daily)` matches
    /// both "twice a day" and "twice daily" without falling through to the
    /// loose `\bdaily\b` alternative below.
    private static let frequencyMappings: [FrequencyMapping] = [
        FrequencyMapping(#"\btwice (?:a |per )?(?:day|daily)\b|\btwo times (?:a |per )?(?:day|daily)\b|\bbid\b|\b2 times (?:a |per )?(?:day|daily)\b"#, "Twice daily"),
        FrequencyMapping(#"\bthree times (?:a |per )?(?:day|daily)\b|\btid\b|\b3 times (?:a |per )?(?:day|daily)\b"#, "3 times daily"),
        FrequencyMapping(#"\bfour times (?:a |per )?(?:day|daily)\b|\bqid\b|\b4 times (?:a |per )?(?:day|daily)\b"#, "4 times daily"),
        FrequencyMapping(#"\bevery\s+(\d+)\s+hours?\b"#, "Every {n} hours"),
        FrequencyMapping(#"\bonce (?:a |per )?(?:day|daily)\b|\bevery day\b|\bqd\b|\bdaily\b"#, "Once daily"),
        FrequencyMapping(#"\bas needed\b|\bprn\b"#, "As needed"),
        FrequencyMapping(#"\bat bedtime\b|\bqhs\b"#, "At bedtime")
    ]

    private static func parseFrequency(text: String, lines: [RecognizedTextLine]) -> ParsedField<String> {
        for mapping in frequencyMappings {
            guard let regex = mapping.regex else { continue }
            let nsRange = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else { continue }

            var value = mapping.label
            if value.contains("{n}"), match.numberOfRanges >= 2 {
                let n = (text as NSString).substring(with: match.range(at: 1))
                value = value.replacingOccurrences(of: "{n}", with: n)
            }
            let conf = bestConfidence(in: lines, matching: regex) ?? 0.65
            return ParsedField(value: value, confidence: FieldConfidence.from(conf))
        }
        return .empty
    }

    // MARK: - Food rule

    private static func parseFoodRule(text: String) -> ParsedField<String> {
        let lower = text.lowercased()
        if lower.contains("without food") ||
           lower.contains("on an empty stomach") ||
           lower.contains("empty stomach") {
            return ParsedField(value: "without", confidence: .high)
        }
        if lower.contains("with food") || lower.contains("with meals") || lower.contains("with a meal") {
            return ParsedField(value: "with", confidence: .high)
        }
        return .empty
    }

    // MARK: - Quantity

    /// Prefer an explicit "Quantity:"/"Qty"/"#" label. Fall back to a bare
    /// "<number> tablets" only when the number has at least 2 digits and
    /// isn't preceded by the verb "take" — otherwise instructions like
    /// "Take 1 tablet" hijack the quantity field (B.1 S2: don't guess).
    private static let quantityLabelPattern =
        #"(?:quantity|qty|#)\s*:?\s*(\d+)\b"#
    private static let quantityCountPattern =
        #"(?<!take\s)\b(\d{2,})\s*(?:tablet|capsule|pill|tab|cap)s?\b"#

    private static func parseQuantity(text: String, lines: [RecognizedTextLine]) -> ParsedField<Int> {
        if let labelRegex = try? NSRegularExpression(pattern: quantityLabelPattern,
                                                     options: .caseInsensitive),
           let result = matchedInt(in: text,
                                   regex: labelRegex,
                                   group: 1,
                                   range: 1...999,
                                   lines: lines) {
            return result
        }
        if let countRegex = try? NSRegularExpression(pattern: quantityCountPattern,
                                                     options: .caseInsensitive),
           let result = matchedInt(in: text,
                                   regex: countRegex,
                                   group: 1,
                                   range: 5...999,
                                   lines: lines) {
            return result
        }
        return .empty
    }

    private static func matchedInt(in text: String,
                                   regex: NSRegularExpression,
                                   group: Int,
                                   range: ClosedRange<Int>,
                                   lines: [RecognizedTextLine]) -> ParsedField<Int>? {
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges > group else { return nil }
        let nsString = text as NSString
        let captured = nsString.substring(with: match.range(at: group))
        guard let n = Int(captured), range.contains(n) else { return nil }
        let conf = bestConfidence(in: lines, matching: regex) ?? 0.65
        return ParsedField(value: n, confidence: FieldConfidence.from(conf))
    }

    // MARK: - Pills per dose

    private static let pillsPerDosePattern =
        #"\btake\s+(\d+)\s*(?:tablet|capsule|pill|tab|cap)s?\b"#

    private static func parsePillsPerDose(text: String) -> ParsedField<Int> {
        guard let regex = try? NSRegularExpression(pattern: pillsPerDosePattern,
                                                   options: .caseInsensitive) else {
            return .empty
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges >= 2 else { return .empty }
        let n = (text as NSString).substring(with: match.range(at: 1))
        guard let pills = Int(n), (1...10).contains(pills) else { return .empty }
        // The instruction "Take N tablet(s)" is unambiguous when matched, so
        // we trust this field at high confidence.
        return ParsedField(value: pills, confidence: .high)
    }

    // MARK: - Helpers

    private static func bestConfidence(in lines: [RecognizedTextLine],
                                       matching regex: NSRegularExpression) -> Float? {
        let containing = lines.filter { line in
            let nsRange = NSRange(line.text.startIndex..., in: line.text)
            return regex.firstMatch(in: line.text, options: [], range: nsRange) != nil
        }
        return containing.map(\.confidence).max()
    }
}
