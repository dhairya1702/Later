import Photos
import SwiftData

@MainActor
struct ItemRepository {
    let context: ModelContext

    func item(for assetIdentifier: String) throws -> LaterItem? {
        var descriptor = FetchDescriptor<LaterItem>(
            predicate: #Predicate { $0.screenshotAssetIdentifier == assetIdentifier }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func createIfNeeded(
        for asset: PHAsset,
        text: String,
        classification: ClassificationResult
    ) throws -> LaterItem {
        if let existing = try item(for: asset.localIdentifier) {
            if !existing.isUserCorrected {
                existing.title = TitleExtractor().extract(
                    from: text,
                    category: classification.category,
                    screenDetection: classification.screenDetection
                )
                existing.category = classification.category
                existing.kind = classification.kind
                existing.confidence = classification.confidence
                existing.needsReview = classification.needsReview
                existing.updatedAt = .now
            }
            applyMetadata(classification, to: existing)
            try context.save()
            return existing
        }

        let item = LaterItem(
            title: TitleExtractor().extract(
                from: text,
                category: classification.category,
                screenDetection: classification.screenDetection
            ),
            category: classification.category,
            kind: classification.kind,
            confidence: classification.confidence,
            createdAt: asset.creationDate ?? .now,
            screenshotAssetIdentifier: asset.localIdentifier,
            rawOCRText: text,
            needsReview: classification.needsReview
        )
        applyMetadata(classification, to: item)
        context.insert(item)
        try context.save()
        return item
    }

    private func applyMetadata(_ classification: ClassificationResult, to item: LaterItem) {
        item.visualLabelsText = classification.visualLabels?
            .prefix(5)
            .map(\.identifier)
            .joined(separator: ", ")
        item.isVisualOnly = classification.usedVisualClassification
        item.screenSurfaceRaw = classification.screenDetection?.surface.rawValue
        item.sourceAppRaw = classification.screenDetection?.sourceApp.rawValue
        item.screenDetectionConfidence = classification.screenDetection?.confidence
        item.screenDetectionEvidenceText = classification.screenDetection?.evidence.joined(separator: ", ")
        item.isOffer = classification.category == .offer || (classification.offerConfidence ?? 0) >= 0.5

        guard let facts = classification.facts else { return }
        item.detectedDate = facts.primaryDate
        let hasAmbiguousDates = facts.primaryDate == nil
            && facts.primaryDateRole == nil
            && facts.dateTexts.count > 1
        item.detectedDateText = hasAmbiguousDates ? nil : facts.dateTexts.first
        item.detectedTimeText = hasAmbiguousDates ? nil : facts.timeTexts.first
        item.detectedLocation = facts.locations.first
        item.couponCode = facts.couponCodes.first
        item.discountText = facts.discountTexts.first
        item.importantDateRole = facts.primaryDateRole
        item.metadataJSON = try? JSONEncoder().encode(facts)

        if let price = facts.prices.first {
            item.detectedPrice = numericPrice(from: price)
            item.detectedCurrency = currency(from: price)
        }
    }

    private func numericPrice(from text: String) -> Double? {
        let cleaned = text.replacingOccurrences(
            of: #"[^0-9.]"#,
            with: "",
            options: .regularExpression
        )
        return Double(cleaned)
    }

    private func currency(from text: String) -> String? {
        let uppercased = text.uppercased()
        if uppercased.contains("$") || uppercased.contains("USD") { return "USD" }
        if uppercased.contains("€") || uppercased.contains("EUR") { return "EUR" }
        if uppercased.contains("£") || uppercased.contains("GBP") { return "GBP" }
        if uppercased.contains("₹") || uppercased.contains("INR") { return "INR" }
        return nil
    }
}
