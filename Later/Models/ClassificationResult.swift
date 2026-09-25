import Foundation

enum ImportantDateRole: String, Codable, Hashable {
    case event
    case expiration
    case deadline
    case reservation
    case delivery
    case travel
    case unspecified
}

/// Every value here is backed by characters present in OCR text. In particular,
/// `locations` never uses image recognition, asset metadata, or device location.
struct ExtractedFacts: Codable, Hashable {
    let dateTexts: [String]
    let timeTexts: [String]
    let locations: [String]
    let prices: [String]
    let discountTexts: [String]
    let couponCodes: [String]
    let primaryDateRole: ImportantDateRole?
    let primaryDate: Date?

    var hasOfferEvidence: Bool {
        !discountTexts.isEmpty || !couponCodes.isEmpty
    }
}

struct VisualLabel: Codable, Hashable, Identifiable {
    let identifier: String
    let confidence: Double

    var id: String { identifier }
}

struct CategoryClassificationScore: Codable, Hashable, Identifiable {
    let category: LaterCategory
    let ruleScore: Double
    let semanticScore: Double
    let finalScore: Double

    var id: LaterCategory { category }
}

struct ClassificationResult: Codable, Hashable {
    let category: LaterCategory
    let kind: LaterKind
    let kindConfidence: Double
    let confidence: Double
    let margin: Double
    let needsReview: Bool
    let semanticModelAvailable: Bool
    let scores: [CategoryClassificationScore]
    let facts: ExtractedFacts?
    let offerConfidence: Double?
    let visualLabels: [VisualLabel]?
    let visualModelAvailable: Bool?
    let usedVisualClassification: Bool?
    let screenDetection: ScreenDetection?

    init(
        category: LaterCategory,
        kind: LaterKind,
        kindConfidence: Double,
        confidence: Double,
        margin: Double,
        needsReview: Bool,
        semanticModelAvailable: Bool,
        scores: [CategoryClassificationScore],
        facts: ExtractedFacts? = nil,
        offerConfidence: Double? = nil,
        visualLabels: [VisualLabel]? = nil,
        visualModelAvailable: Bool? = nil,
        usedVisualClassification: Bool? = nil,
        screenDetection: ScreenDetection? = nil
    ) {
        self.category = category
        self.kind = kind
        self.kindConfidence = kindConfidence
        self.confidence = confidence
        self.margin = margin
        self.needsReview = needsReview
        self.semanticModelAvailable = semanticModelAvailable
        self.scores = scores
        self.facts = facts
        self.offerConfidence = offerConfidence
        self.visualLabels = visualLabels
        self.visualModelAvailable = visualModelAvailable
        self.usedVisualClassification = usedVisualClassification
        self.screenDetection = screenDetection
    }

    static let unavailable = ClassificationResult(
        category: .other,
        kind: .other,
        kindConfidence: 0,
        confidence: 0,
        margin: 0,
        needsReview: true,
        semanticModelAvailable: false,
        scores: []
    )
}
