import Foundation
import SwiftData

enum ProcessingStatus: String, Codable {
    case pending
    case loadingImage
    case OCR
    case completed
    case failed
}

@Model
final class ScreenshotRecord {
    @Attribute(.unique) var assetIdentifier: String
    var screenshotDate: Date
    var discoveredAt: Date
    var processedAt: Date?
    var processingStatusRaw: String
    var OCRText: String?
    var OCRLayoutJSON: Data?
    var classifierVersion: Int
    var failureReason: String?
    var resultingItemID: UUID?
    var predictedCategoryRaw: String?
    var predictedKindRaw: String?
    var classificationConfidence: Double?
    var classificationMargin: Double?
    var needsReview: Bool?
    var classificationDebugJSON: Data?

    var processingStatus: ProcessingStatus {
        get { ProcessingStatus(rawValue: processingStatusRaw) ?? .pending }
        set { processingStatusRaw = newValue.rawValue }
    }

    init(
        assetIdentifier: String,
        screenshotDate: Date,
        discoveredAt: Date = .now,
        processingStatus: ProcessingStatus = .pending
    ) {
        self.assetIdentifier = assetIdentifier
        self.screenshotDate = screenshotDate
        self.discoveredAt = discoveredAt
        self.processingStatusRaw = processingStatus.rawValue
        self.classifierVersion = 0
    }
}
