import Foundation

struct ImportantFactExtractor {
    func extract(from text: String, prices: [String]) -> ExtractedFacts {
        let detectedDates = dateMatches(in: text)
        let dateTexts = detectedDates.map(\.text)
        let times = matches(
            in: text,
            pattern: #"(?i)\b(?:1[0-2]|0?[1-9])(?::[0-5]\d)?\s?(?:a\.?m\.?|p\.?m\.?)\b|\b(?:[01]?\d|2[0-3]):[0-5]\d\b"#
        )
        let distinctTimes = times.filter { time in
            !dateTexts.contains { $0.localizedCaseInsensitiveContains(time) }
        }
        let discounts = matches(
            in: text,
            pattern: #"(?i)\b\d{1,3}%\s*off\b|[$€£₹]\s?\d+(?:\.\d{1,2})?\s*off\b|\b(?:free delivery|free shipping|buy one get one|bogo)\b"#
        )
        let couponCodes = captureMatches(
            in: text,
            pattern: #"(?i)\b(?:coupon\s+code|promo\s+code|use\s+code|coupon(?!\s+code\b)|promo(?!\s+code\b))\s*[:#-]?\s*([A-Z0-9][A-Z0-9-]{3,19})\b"#,
            group: 1
        )

        return ExtractedFacts(
            dateTexts: unique(dateTexts),
            timeTexts: unique(distinctTimes),
            locations: textLocations(in: text),
            prices: unique(prices),
            discountTexts: unique(discounts),
            couponCodes: unique(couponCodes),
            primaryDateRole: dateTexts.isEmpty ? nil : dateRole(in: text),
            primaryDate: detectedDates.first?.date
        )
    }

    private func textLocations(in text: String) -> [String] {
        var locations = detectorMatches(in: text, types: .address)
        let labeledPattern = #"(?im)^\s*(?:location|venue|address|pickup(?: location)?)\s*[:\-]\s*(.{3,100})$"#
        locations.append(contentsOf: captureMatches(in: text, pattern: labeledPattern, group: 1))

        // Address-like text must contain a street number and suffix. This avoids
        // guessing a location from a landmark visible only in the image.
        locations.append(contentsOf: matches(
            in: text,
            pattern: #"(?im)\b\d{1,6}\s+[A-Z0-9][A-Z0-9 .'-]{2,60}\s(?:street|st\.?|avenue|ave\.?|road|rd\.?|boulevard|blvd\.?|drive|dr\.?|lane|ln\.?|highway|hwy\.?)\b[^\n]{0,50}"#
        ))
        return unique(locations.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    private func dateRole(in text: String) -> ImportantDateRole {
        let normalized = text.lowercased()
        if containsAny(["expires", "expiration", "valid until", "offer ends", "sale ends"], in: normalized) { return .expiration }
        if containsAny(["deadline", "due ", "submit by"], in: normalized) { return .deadline }
        if containsAny(["reservation", "reserved", "party of", "check-in"], in: normalized) { return .reservation }
        if containsAny(["delivery", "arrives", "estimated arrival"], in: normalized) { return .delivery }
        if containsAny(["flight", "depart", "arrival", "travel by"], in: normalized) { return .travel }
        if containsAny(["event", "concert", "showtime", "doors open", "starts at"], in: normalized) { return .event }
        return .unspecified
    }

    private func detectorMatches(in text: String, types: NSTextCheckingResult.CheckingType) -> [String] {
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { result in
            guard let swiftRange = Range(result.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private func dateMatches(in text: String) -> [(text: String, date: Date?)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { result in
            guard let swiftRange = Range(result.range, in: text) else { return nil }
            return (String(text[swiftRange]), result.date)
        }
    }

    private func matches(in text: String, pattern: String) -> [String] {
        captureMatches(in: text, pattern: pattern, group: 0)
    }

    private func captureMatches(in text: String, pattern: String, group: Int) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { result in
            guard result.numberOfRanges > group,
                  result.range(at: group).location != NSNotFound,
                  let swiftRange = Range(result.range(at: group), in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }

    private func containsAny(_ values: [String], in text: String) -> Bool {
        values.contains { text.contains($0) }
    }
}
