import Photos
import SwiftData

@MainActor
struct ScreenshotRepository {
    let context: ModelContext

    func record(for asset: PHAsset) throws -> ScreenshotRecord {
        let identifier = asset.localIdentifier
        var descriptor = FetchDescriptor<ScreenshotRecord>(
            predicate: #Predicate { $0.assetIdentifier == identifier }
        )
        descriptor.fetchLimit = 1

        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        let record = ScreenshotRecord(
            assetIdentifier: identifier,
            screenshotDate: asset.creationDate ?? .now
        )
        context.insert(record)
        try context.save()
        return record
    }

    func successfullyProcessedIdentifiers() throws -> Set<String> {
        let records = try context.fetch(FetchDescriptor<ScreenshotRecord>())
        return Set(records.compactMap { record in
            record.resultingItemID == nil ? nil : record.assetIdentifier
        })
    }

    func upToDateProcessedIdentifiers() throws -> Set<String> {
        let records = try context.fetch(FetchDescriptor<ScreenshotRecord>())
        return Set(records.compactMap { record in
            guard record.resultingItemID != nil,
                  record.classifierVersion == ClassificationConfig.classifierVersion else {
                return nil
            }
            return record.assetIdentifier
        })
    }

    func saveOCR(_ text: String, for record: ScreenshotRecord) throws {
        record.OCRText = text
        record.processedAt = .now
        record.processingStatus = .completed
        record.failureReason = nil
        try context.save()
    }

    func saveOCR(_ document: OCRDocument, for record: ScreenshotRecord) throws {
        record.OCRText = document.text
        record.OCRLayoutJSON = try JSONEncoder().encode(document.blocks)
        record.processedAt = .now
        record.processingStatus = .completed
        record.failureReason = nil
        try context.save()
    }

    func savedOCRBlocks(for record: ScreenshotRecord) -> [OCRBlock] {
        guard let data = record.OCRLayoutJSON else { return [] }
        return (try? JSONDecoder().decode([OCRBlock].self, from: data)) ?? []
    }

    func saveClassification(_ result: ClassificationResult, for record: ScreenshotRecord) throws {
        record.predictedCategoryRaw = result.category.rawValue
        record.predictedKindRaw = result.kind.rawValue
        record.classificationConfidence = result.confidence
        record.classificationMargin = result.margin
        record.needsReview = result.needsReview
        record.classifierVersion = ClassificationConfig.classifierVersion
        record.classificationDebugJSON = try JSONEncoder().encode(result)
        try context.save()
    }

    func savedClassification(for record: ScreenshotRecord) -> ClassificationResult? {
        guard record.classifierVersion == ClassificationConfig.classifierVersion,
              let data = record.classificationDebugJSON else { return nil }
        return try? JSONDecoder().decode(ClassificationResult.self, from: data)
    }

    func saveFailure(_ error: Error, for record: ScreenshotRecord) throws {
        record.processedAt = .now
        record.processingStatus = .failed
        record.failureReason = String(describing: error)
        try context.save()
    }
}
