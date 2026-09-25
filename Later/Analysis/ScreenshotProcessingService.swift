import Foundation
import Photos
import SwiftData
import UIKit

@MainActor
struct ScreenshotProcessingService {
    let context: ModelContext

    func process(_ asset: PHAsset) async {
        guard !Task.isCancelled else { return }
        let items = ItemRepository(context: context)
        let screenshots = ScreenshotRepository(context: context)

        do {
            let record = try screenshots.record(for: asset)
            record.processingStatus = .loadingImage
            try context.save()
            let image = try await loadAnalysisImage(for: asset)
            try Task.checkCancellation()

            let classification: ClassificationResult
            let visibleText: String
            if let saved = screenshots.savedClassification(for: record) {
                classification = saved
                visibleText = record.OCRText ?? ""
            } else {
                let analysis = try await VisionBridgeClient().analyze(image)
                classification = analysis.classification
                visibleText = analysis.visibleText
                try screenshots.saveOCR(visibleText, for: record)
                try screenshots.saveClassification(classification, for: record)
            }

            let fingerprint = try await fingerprint(for: asset, fallback: image)
            let resolution = try items.resolve(
                for: asset,
                text: visibleText,
                classification: classification,
                fingerprint: fingerprint
            )
            let item = resolution.item

            if let fingerprint {
                try DuplicateScreenshotDetector(context: context).analyze(
                    item: item,
                    fingerprint: fingerprint,
                    text: visibleText
                )
            }
            record.resultingItemID = item.id
            try context.save()

            // A merged item was already announced by the share extension.
            await NotificationManager.shared.handleProcessed(
                item: item,
                captureDate: asset.creationDate ?? .now,
                isNew: resolution.isNew
            )
        } catch {
            if let record = try? screenshots.record(for: asset) {
                try? screenshots.saveFailure(error, for: record)
            }
        }
    }

    private func fingerprint(
        for asset: PHAsset,
        fallback image: UIImage
    ) async throws -> ScreenshotFingerprint? {
        let generator = ImageFingerprintGenerator()
        guard let data = try? await ImageLoader().originalData(for: asset),
              let fingerprint = generator.fingerprint(data: data) else {
            return generator.fingerprint(image)
        }
        return fingerprint
    }

    private func loadAnalysisImage(for asset: PHAsset) async throws -> UIImage {
        let maxDimension: CGFloat = 1800
        let scale = min(maxDimension / CGFloat(max(asset.pixelWidth, asset.pixelHeight)), 1)
        return try await ImageLoader().image(
            for: asset,
            targetSize: CGSize(
                width: CGFloat(asset.pixelWidth) * scale,
                height: CGFloat(asset.pixelHeight) * scale
            )
        )
    }
}

extension VisionAnalysis {
    var classification: ClassificationResult {
        let mappedCategory = LaterCategory(rawValue: category) ?? .other
        let mappedKind = LaterKind(rawValue: kind) ?? .fallback(for: mappedCategory)
        let mappedSurface = ScreenshotSurface(rawValue: surface) ?? .unknown
        let mappedSourceApp = ScreenshotSourceApp(rawValue: sourceApp) ?? .unknown
        let extractedFacts = ExtractedFacts(
            dateTexts: facts.dateText.map { [$0] } ?? [],
            timeTexts: facts.timeText.map { [$0] } ?? [],
            locations: facts.location.map { [$0] } ?? [],
            prices: facts.priceText.map { [$0] } ?? [],
            discountTexts: facts.discountText.map { [$0] } ?? [],
            couponCodes: facts.couponCode.map { [$0] } ?? [],
            primaryDateRole: facts.dateRole.flatMap(ImportantDateRole.init(rawValue:)),
            primaryDate: nil
        )
        let scores = LaterCategory.allCases.map {
            CategoryClassificationScore(
                category: $0,
                ruleScore: 0,
                semanticScore: 0,
                finalScore: $0 == mappedCategory ? confidence : 0
            )
        }.sorted { $0.finalScore > $1.finalScore }
        let detection: ScreenDetection? = mappedSurface == .unknown && mappedSourceApp == .unknown
            ? nil
            : ScreenDetection(
                surface: mappedSurface,
                sourceApp: mappedSourceApp,
                confidence: confidence,
                evidence: evidence
            )
        let mappedEntities = (actionableEntities ?? []).compactMap { entity -> ActionableEntity? in
            guard let type = ActionableEntityType(rawValue: entity.type) else { return nil }
            return ActionableEntity(
                type: type,
                value: entity.value,
                confidence: entity.confidence,
                evidence: entity.evidence
            )
        }
        let mappedMedia = media.flatMap { media -> DetectedMedia? in
            guard let type = DetectedMediaType(rawValue: media.type),
                  let source = MediaSourceService(rawValue: media.sourceService) else { return nil }
            return DetectedMedia(
                type: type,
                title: media.title,
                creator: media.creator,
                sourceService: source,
                confidence: media.confidence,
                evidence: media.evidence
            )
        }
        let mappedProduct = productDetails.map {
            DetectedProductDetails(
                name: $0.name,
                brand: $0.brand,
                model: $0.model,
                variant: $0.variant,
                currentPrice: $0.currentPrice,
                originalPrice: $0.originalPrice,
                discount: $0.discount,
                seller: $0.seller,
                condition: $0.condition,
                negotiable: $0.negotiable,
                rating: $0.rating,
                reviewCount: $0.reviewCount,
                delivery: $0.delivery,
                availability: $0.availability,
                fulfillment: $0.fulfillment,
                location: $0.location,
                confidence: $0.confidence,
                evidence: $0.evidence
            )
        }

        return ClassificationResult(
            suggestedTitle: title,
            summary: summary,
            suggestedAction: suggestedAction,
            category: mappedCategory,
            kind: mappedKind,
            kindConfidence: confidence,
            confidence: confidence,
            margin: confidence,
            needsReview: needsReview,
            semanticModelAvailable: true,
            scores: scores,
            facts: extractedFacts,
            offerConfidence: mappedCategory == .offer ? confidence : 0,
            visualModelAvailable: true,
            usedVisualClassification: true,
            screenDetection: detection,
            actionableEntities: mappedEntities,
            detectedMedia: mappedMedia,
            productDetails: mappedProduct
        )
    }

}
