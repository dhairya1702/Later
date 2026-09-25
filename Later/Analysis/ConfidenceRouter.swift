import Foundation

struct ClassificationConfig {
    static let automaticThreshold = 0.82
    static let reviewThreshold = 0.60
    static let automaticMargin = 0.18
    static let minimumKindConfidence = 0.60
    static let ruleWeight = 0.65
    static let semanticWeight = 0.35
    static let classifierVersion = 13
}

struct ConfidenceRouter {
    func route(
        scores: [CategoryClassificationScore],
        semanticModelAvailable: Bool = true,
        kind: LaterKind = .other,
        kindConfidence: Double = 0,
        facts: ExtractedFacts? = nil,
        offerConfidence: Double? = nil,
        visualLabels: [VisualLabel]? = nil,
        visualModelAvailable: Bool? = nil,
        usedVisualClassification: Bool? = nil,
        screenDetection: ScreenDetection? = nil,
        forceAbstention: Bool = false
    ) -> ClassificationResult {
        let ranked = scores.sorted { $0.finalScore > $1.finalScore }
        guard let winner = ranked.first, winner.finalScore > 0 else {
            return .unavailable
        }

        let runnerUp = ranked.dropFirst().first?.finalScore ?? 0
        let margin = max(0, winner.finalScore - runnerUp)
        let isAutomatic = !forceAbstention
            && winner.finalScore >= ClassificationConfig.automaticThreshold
            && margin >= ClassificationConfig.automaticMargin
        let assignedCategory = isAutomatic ? winner.category : LaterCategory.other
        let needsReview = !isAutomatic

        let resolvedKind: LaterKind
        if kind != .other && kindConfidence >= ClassificationConfig.minimumKindConfidence {
            resolvedKind = kind
        } else if isAutomatic {
            resolvedKind = LaterKind.fallback(for: winner.category)
        } else {
            resolvedKind = .other
        }

        return ClassificationResult(
            category: assignedCategory,
            kind: resolvedKind,
            kindConfidence: kindConfidence,
            confidence: winner.finalScore,
            margin: margin,
            needsReview: needsReview,
            semanticModelAvailable: semanticModelAvailable,
            scores: ranked,
            facts: facts,
            offerConfidence: offerConfidence,
            visualLabels: visualLabels,
            visualModelAvailable: visualModelAvailable,
            usedVisualClassification: usedVisualClassification,
            screenDetection: screenDetection
        )
    }
}
