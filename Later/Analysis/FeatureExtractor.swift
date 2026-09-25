import Foundation

struct ScreenshotFeatures {
    let normalizedText: String
    let chunks: [String]
    let detectedPrices: [String]
    let detectedDomains: [String]
    let containsDateLanguage: Bool
    let containsAddressLanguage: Bool
    let facts: ExtractedFacts
}

struct FeatureExtractor {
    private let normalizer = TextNormalizer()

    func extract(from text: String) -> ScreenshotFeatures {
        let normalized = normalizer.normalize(text)
        let prices = matches(
            in: text,
            pattern: #"(?i)(?:[$€£₹]\s?\d[\d,]*(?:\.\d{1,2})?|(?:USD|EUR|GBP|INR)\s?\d[\d,]*(?:\.\d{1,2})?)"#
        )
        return ScreenshotFeatures(
            normalizedText: normalized,
            chunks: normalizer.meaningfulChunks(from: text),
            detectedPrices: prices,
            detectedDomains: knownDomains.filter { normalized.contains($0) },
            containsDateLanguage: containsAny(
                ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april", "may ", "june", "july", "august", "september", "october", "november", "december", "tomorrow", "deadline", "due "],
                in: normalized
            ),
            containsAddressLanguage: containsAny(
                ["street", " st ", "avenue", " ave ", "road", " rd ", "boulevard", " blvd", "located at", "directions"],
                in: normalized
            ),
            facts: ImportantFactExtractor().extract(from: text, prices: prices)
        )
    }

    private let knownDomains = [
        "amazon", "nike", "ikea", "netflix", "hulu", "imdb", "rottentomatoes",
        "goodreads", "ticketmaster", "opentable", "yelp", "maps.google",
        "airbnb", "booking.com", "youtube", "doordash", "ubereats",
        "spotify", "music.apple", "soundcloud"
    ]

    private func containsAny(_ values: [String], in text: String) -> Bool {
        values.contains { text.contains($0) }
    }

    private func matches(in text: String, pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap {
            guard let swiftRange = Range($0.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }
}
