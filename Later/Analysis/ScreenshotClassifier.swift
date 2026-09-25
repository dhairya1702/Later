import Foundation
@preconcurrency import NaturalLanguage
import UIKit

actor ScreenshotClassifier {
    static let shared = ScreenshotClassifier()

    private let featureExtractor = FeatureExtractor()
    private let confidenceRouter = ConfidenceRouter()
    private let screenSourceDetector = ScreenSourceDetector()
    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)

    func classify(
        text: String,
        image: UIImage? = nil,
        ocrBlocks: [OCRBlock] = []
    ) async -> ClassificationResult {
        let features = featureExtractor.extract(from: text)
        let screenDetection = screenSourceDetector.detect(text: text, blocks: ocrBlocks)
        let ruleScores = ruleScores(for: features)
        let semanticScores = semanticScores(for: features.chunks)
        let semanticModelAvailable = semanticScores != nil
        let textKindResult = classifyKind(features)
        let textCharacterCount = text.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .count
        let strongestTextRule = ruleScores.values.max() ?? 0
        let isTextSparse = textCharacterCount < 30
            || (textCharacterCount < 120 && strongestTextRule < 0.35)
        let shouldPreferVisual = screenDetection.surface == .unknown
            && isTextSparse
            && strongestTextRule < 0.5
            && textKindResult.confidence < 0.5
        let visual: VisualClassification?
        if shouldPreferVisual, let image {
            visual = await VisualImageClassifier.shared.classify(image)
        } else {
            visual = nil
        }
        let kindResult: (kind: LaterKind, confidence: Double)
        if screenDetection.surface != .unknown {
            kindResult = (
                kind: kind(for: screenDetection.surface),
                confidence: screenDetection.confidence
            )
        } else if let visual {
            kindResult = (kind: visual.kind, confidence: max(0.55, visual.confidence))
        } else {
            kindResult = textKindResult
        }

        let detectedCategory = category(
            for: screenDetection,
            features: features,
            ruleScores: ruleScores
        )

        let scores = LaterCategory.allCases.map { category in
            let rule = ruleScores[category, default: 0]
            let semantic = semanticScores?[category, default: 0] ?? 0
            let textFinal = semanticModelAvailable
                ? ClassificationConfig.ruleWeight * rule
                    + ClassificationConfig.semanticWeight * semantic
                : rule
            let visualAdjusted: Double
            if let visual, shouldPreferVisual {
                visualAdjusted = category == visual.category
                    ? max(textFinal, max(0.65, visual.confidence))
                    : textFinal * 0.25
            } else {
                visualAdjusted = textFinal
            }
            let final: Double
            if let detectedCategory {
                final = category == detectedCategory
                    ? max(visualAdjusted, screenDetection.confidence)
                    : visualAdjusted * 0.15
            } else {
                final = visualAdjusted
            }
            return CategoryClassificationScore(
                category: category,
                ruleScore: rule,
                semanticScore: semantic,
                finalScore: min(1, final)
            )
        }

        let hasAmbiguousEventDates = (kindResult.kind == .concert || kindResult.kind == .event)
            && Set(features.facts.dateTexts.map { $0.lowercased() }).count > 1
        let routedFacts: ExtractedFacts
        if hasAmbiguousEventDates {
            routedFacts = ExtractedFacts(
                dateTexts: features.facts.dateTexts,
                timeTexts: features.facts.timeTexts,
                locations: features.facts.locations,
                prices: features.facts.prices,
                discountTexts: features.facts.discountTexts,
                couponCodes: features.facts.couponCodes,
                primaryDateRole: nil,
                primaryDate: nil
            )
        } else {
            routedFacts = features.facts
        }

        return confidenceRouter.route(
            scores: scores,
            semanticModelAvailable: semanticModelAvailable,
            kind: kindResult.kind,
            kindConfidence: kindResult.confidence,
            facts: routedFacts,
            offerConfidence: adjustedOfferConfidence(
                for: features,
                detection: screenDetection
            ),
            visualLabels: visual?.labels,
            visualModelAvailable: image == nil ? nil : visual != nil,
            usedVisualClassification: visual != nil,
            screenDetection: screenDetection.surface == .unknown ? nil : screenDetection,
            forceAbstention: hasAmbiguousEventDates
        )
    }

    private func kind(for surface: ScreenshotSurface) -> LaterKind {
        switch surface {
        case .chat: .chat
        case .story: .story
        case .email: .email
        case .boardingPass: .boardingPass
        case .appStore: .app
        case .map: .map
        case .redditPost: .socialPost
        case .comments: .comments
        case .lockScreen: .lockScreen
        case .unknown: .other
        }
    }

    private func category(
        for detection: ScreenDetection,
        features: ScreenshotFeatures,
        ruleScores: [LaterCategory: Double]
    ) -> LaterCategory? {
        switch detection.surface {
        case .chat:
            if strongOfferEvidence(in: features) { return .offer }
            if ruleScores[.doItem, default: 0] >= 0.5 { return .doItem }
            return .remember
        case .story:
            return strongOfferEvidence(in: features) ? .offer : .remember
        case .email:
            if strongOfferEvidence(in: features) { return .offer }
            if ruleScores[.doItem, default: 0] >= 0.5 { return .doItem }
            return .remember
        case .boardingPass:
            return .go
        case .appStore:
            return .remember
        case .map:
            return .go
        case .redditPost:
            return strongOfferEvidence(in: features) ? .offer : .read
        case .comments:
            return strongOfferEvidence(in: features) ? .offer : .remember
        case .lockScreen:
            return .other
        case .unknown:
            return nil
        }
    }

    private func adjustedOfferConfidence(
        for features: ScreenshotFeatures,
        detection: ScreenDetection
    ) -> Double {
        let confidence = offerConfidence(for: features)
        switch detection.surface {
        case .chat, .story, .email, .redditPost, .comments:
            return strongOfferEvidence(in: features) ? confidence : min(confidence, 0.25)
        case .appStore, .map, .boardingPass, .lockScreen:
            return 0
        case .unknown:
            return confidence
        }
    }

    private func strongOfferEvidence(in features: ScreenshotFeatures) -> Bool {
        let hasCoupon = !features.facts.couponCodes.isEmpty
        let hasDiscount = !features.facts.discountTexts.isEmpty
        let hasExpiration = features.facts.primaryDateRole == .expiration
        let hasRedemptionLanguage = ["redeem", "claim offer", "use code", "promo code", "coupon code"]
            .contains(where: features.normalizedText.contains)
        return (hasCoupon && (hasDiscount || hasExpiration || hasRedemptionLanguage))
            || (hasDiscount && hasExpiration && hasRedemptionLanguage)
    }

    private func classifyKind(_ features: ScreenshotFeatures) -> (kind: LaterKind, confidence: Double) {
        let text = features.normalizedText
        var raw = Dictionary(uniqueKeysWithValues: LaterKind.allCases.map { ($0, 0.0) })

        addKindSignals([("concert", 6), ("featured concert", 6), ("symphony", 4), ("live music", 4), ("tour dates", 4), ("venue", 2)], to: .concert, text: text, raw: &raw)
        addKindSignals([("song", 4), ("album", 5), ("playlist", 5), ("spotify", 8), ("apple music", 8), ("soundcloud", 7), ("playing from", 6), ("now playing", 5), ("lyrics", 4), ("listen", 2), ("artist", 2)], to: .music, text: text, raw: &raw)
        addKindSignals([("add to cart", 6), ("buy now", 6), ("sponsored products", 5), ("shipping", 3), ("in stock", 4), ("size", 2), ("shop", 2), ("ikea", 8), ("product details", 5), ("product dimensions", 5), ("article number", 5), ("furniture", 4)], to: .shopping, text: text, raw: &raw)
        if containsProductNoun(in: text) { raw[.shopping, default: 0] += 5 }
        if !features.detectedPrices.isEmpty { raw[.shopping, default: 0] += 4 }

        addKindSignals([("restaurant", 6), ("menu", 5), ("reservations", 5), ("dish", 4), ("food", 4), ("cheeseburger", 4), ("recipe", 5), ("cuisine", 3)], to: .food, text: text, raw: &raw)
        addKindSignals([("movie", 6), ("film", 6), ("cinema", 4), ("runtime", 3), ("box office", 4)], to: .movie, text: text, raw: &raw)
        addKindSignals([("tv show", 6), ("television", 5), ("series", 5), ("season", 5), ("episode", 5), ("apple tv", 2), ("netflix", 2)], to: .show, text: text, raw: &raw)
        addKindSignals([("activity", 6), ("things to do", 5), ("hiking", 5), ("workout", 5), ("class", 3), ("experience", 3), ("trail", 4)], to: .activity, text: text, raw: &raw)
        addKindSignals([("deadline", 6), ("due", 5), ("submit", 5), ("reminder", 6), ("to-do", 6), ("task", 5), ("appointment", 4), ("meeting", 4)], to: .task, text: text, raw: &raw)
        addKindSignals([("book", 6), ("author", 4), ("chapter", 5), ("goodreads", 6), ("novel", 5)], to: .book, text: text, raw: &raw)
        addKindSignals([("article", 6), ("read more", 4), ("newsletter", 5), ("publication", 4), ("essay", 4)], to: .article, text: text, raw: &raw)
        addKindSignals([("directions", 5), ("national park", 6), ("museum", 5), ("hotel", 4), ("landmark", 5), ("destination", 5), ("visit", 2)], to: .place, text: text, raw: &raw)
        if features.containsAddressLanguage { raw[.place, default: 0] += 3 }
        addKindSignals([("event", 5), ("tickets", 3), ("admission", 3), ("rsvp", 4), ("festival", 5), ("conference", 5)], to: .event, text: text, raw: &raw)
        addKindSignals([("receipt", 6), ("invoice", 6), ("document", 5), ("confirmation number", 5), ("reference number", 5), ("tracking number", 5), ("instructions", 3)], to: .document, text: text, raw: &raw)
        addKindSignals([("coupon", 7), ("promo code", 7), ("offer", 4), ("redeem", 4), ("claim offer", 6)], to: .offer, text: text, raw: &raw)
        if features.facts.hasOfferEvidence { raw[.offer, default: 0] += 6 }

        // Concrete types should beat their generic parents when both are present.
        if raw[.concert, default: 0] > 0 { raw[.event, default: 0] *= 0.45 }
        if raw[.food, default: 0] > 0 { raw[.place, default: 0] *= 0.55 }

        guard let winner = raw.max(by: { $0.value < $1.value }), winner.value > 0 else {
            return (.other, 0)
        }
        return (winner.key, min(winner.value / 10, 1))
    }

    private func addKindSignals(
        _ signals: [(String, Double)],
        to kind: LaterKind,
        text: String,
        raw: inout [LaterKind: Double]
    ) {
        for (signal, weight) in signals where text.contains(signal) {
            raw[kind, default: 0] += weight
        }
    }

    private func ruleScores(for features: ScreenshotFeatures) -> [LaterCategory: Double] {
        var raw = Dictionary(uniqueKeysWithValues: LaterCategory.allCases.map { ($0, 0.0) })
        let text = features.normalizedText

        apply([
            ("season", 2), ("episode", 2), ("watch now", 3), ("netflix", 4),
            ("hulu", 4), ("imdb", 5), ("rotten tomatoes", 5), ("movie", 2),
            ("series", 2), ("tv show", 3), ("apple tv", 3), ("trailer", 2)
        ], to: .watch, text: text, raw: &raw)

        apply([
            ("spotify", 8), ("apple music", 8), ("soundcloud", 7),
            ("playing from", 6), ("now playing", 5), ("playlist", 5),
            ("album", 4), ("lyrics", 4), ("song", 3), ("artist", 2)
        ], to: .listen, text: text, raw: &raw)

        apply([
            ("add to cart", 5), ("buy now", 5), ("shop", 2), ("shipping", 2),
            ("size", 1), ("in stock", 3), ("sponsored products", 2), ("product", 1),
            ("ikea", 8), ("product details", 5), ("product dimensions", 5),
            ("article number", 5), ("furniture", 4)
        ], to: .buy, text: text, raw: &raw)
        if containsProductNoun(in: text) { raw[.buy, default: 0] += 5 }
        if !features.detectedPrices.isEmpty { raw[.buy, default: 0] += 3 }

        apply([
            ("restaurant", 4), ("menu", 4), ("reservations", 4), ("yelp", 5),
            ("opentable", 5), ("delivery", 2), ("order online", 3), ("dish", 2),
            ("cheeseburger", 2), ("cuisine", 2)
        ], to: .eat, text: text, raw: &raw)

        apply([
            ("directions", 3), ("hours", 1), ("tickets", 3), ("venue", 3),
            ("admission", 2), ("concert", 4), ("event", 2), ("museum", 3),
            ("attraction", 3), ("visit", 2)
        ], to: .go, text: text, raw: &raw)
        if features.containsAddressLanguage { raw[.go, default: 0] += 2 }

        apply([
            ("deadline", 5), ("due", 4), ("submit", 3), ("appointment", 4),
            ("meeting", 4), ("reminder", 5), ("rsvp", 3), ("application", 2)
        ], to: .doItem, text: text, raw: &raw)

        apply([
            ("author", 2), ("chapter", 3), ("book", 4), ("article", 3),
            ("read more", 2), ("goodreads", 5), ("publication", 2), ("newsletter", 2)
        ], to: .read, text: text, raw: &raw)

        apply([
            ("coupon", 7), ("promo code", 7), ("promotion", 4), ("special offer", 6),
            ("claim offer", 6), ("redeem", 4), ("valid until", 4), ("offer ends", 4)
        ], to: .offer, text: text, raw: &raw)
        if features.facts.hasOfferEvidence { raw[.offer, default: 0] += 6 }

        apply([
            ("receipt", 6), ("invoice", 6), ("document", 5),
            ("confirmation number", 5), ("reference number", 5),
            ("tracking number", 5), ("instructions", 3)
        ], to: .remember, text: text, raw: &raw)

        for domain in features.detectedDomains {
            switch domain {
            case "netflix", "hulu", "imdb", "rottentomatoes", "youtube": raw[.watch, default: 0] += 3
            case "spotify", "music.apple", "soundcloud": raw[.listen, default: 0] += 5
            case "amazon", "nike", "ikea": raw[.buy, default: 0] += 5
            case "yelp", "opentable", "doordash", "ubereats": raw[.eat, default: 0] += 3
            case "ticketmaster", "maps.google", "airbnb", "booking.com": raw[.go, default: 0] += 3
            case "goodreads": raw[.read, default: 0] += 3
            default: break
            }
        }

        return raw.mapValues { min($0 / 8, 1) }
    }

    private func offerConfidence(for features: ScreenshotFeatures) -> Double {
        var evidence = 0.0
        if !features.facts.discountTexts.isEmpty { evidence += 0.65 }
        if !features.facts.couponCodes.isEmpty { evidence += 0.30 }
        if features.normalizedText.contains("coupon") { evidence += 0.55 }
        if ["special offer", "claim offer", "offer ends", "promotion"].contains(where: features.normalizedText.contains) {
            evidence += 0.55
        }
        return min(evidence, 1)
    }

    private func semanticScores(for chunks: [String]) -> [LaterCategory: Double]? {
        guard let embedding else { return nil }
        var result: [LaterCategory: Double] = [:]

        for (category, phrases) in Self.prototypes {
            var best = 0.0
            for chunk in chunks.prefix(30) where chunk.count <= 600 {
                for phrase in phrases {
                    let distance = embedding.distance(
                        between: chunk,
                        and: phrase,
                        distanceType: .cosine
                    )
                    guard distance.isFinite else { continue }
                    best = max(best, max(0, min(1, 1 - distance)))
                }
            }
            result[category] = best
        }

        return result
    }

    private func apply(
        _ signals: [(String, Double)],
        to category: LaterCategory,
        text: String,
        raw: inout [LaterCategory: Double]
    ) {
        for (signal, weight) in signals where text.contains(signal) {
            raw[category, default: 0] += weight
        }
    }

    private func containsProductNoun(in text: String) -> Bool {
        let words = Set(text.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: [
            "desk", "table", "chair", "sofa", "couch", "shelf", "shelves",
            "cabinet", "dresser", "bed", "lamp", "rug"
        ])
    }

    private static let prototypes: [LaterCategory: [String]] = [
        .watch: [
            "a movie I want to watch", "a television show recommendation",
            "a film recommendation", "something to watch later"
        ],
        .listen: [
            "a song I want to listen to", "music playing in a streaming app",
            "an album or playlist to hear later", "a music recommendation"
        ],
        .eat: [
            "a restaurant recommendation", "a place to eat",
            "food I want to try", "a dish recommendation"
        ],
        .go: [
            "a place I want to visit", "an event I want to attend",
            "travel inspiration", "tickets for a concert"
        ],
        .buy: [
            "a product I want to buy", "online shopping", "something for sale"
        ],
        .read: [
            "a book I want to read", "an article to read later", "a reading recommendation"
        ],
        .doItem: [
            "a task I need to complete", "an upcoming deadline",
            "a meeting or appointment", "something I need to do"
        ],
        .remember: [
            "useful information to remember", "information I may need later",
            "a fact worth saving"
        ],
        .offer: [
            "a coupon or promotional offer", "a discount code to redeem",
            "a limited time deal", "money off a future order"
        ]
    ]
}
