import Foundation
import SwiftData

@Model
final class LaterItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var subtitle: String?
    var categoryRaw: String
    var kindRaw: String?
    var confidence: Double
    var createdAt: Date
    var updatedAt: Date
    var screenshotAssetIdentifier: String?
    var rawOCRText: String
    var statusRaw: String
    var isUserCorrected: Bool
    var needsReview: Bool
    var detectedDate: Date?
    var detectedURL: String?
    var detectedPrice: Double?
    var detectedCurrency: String?
    var detectedLocation: String?
    var detectedDateText: String?
    var detectedTimeText: String?
    var couponCode: String?
    var discountText: String?
    var isOffer: Bool?
    var importantDateRoleRaw: String?
    var visualLabelsText: String?
    var isVisualOnly: Bool?
    var screenSurfaceRaw: String?
    var sourceAppRaw: String?
    var screenDetectionConfidence: Double?
    var screenDetectionEvidenceText: String?
    var metadataJSON: Data?
    var resurfacedCount: Int
    var lastResurfacedAt: Date?
    var snoozedUntil: Date?
    var completedAt: Date?
    var imageContentHash: String?
    var perceptualHash: String?
    var sourcePixelWidth: Int?
    var sourcePixelHeight: Int?
    var duplicateGroupID: UUID?
    var duplicateOfItemID: UUID?
    var duplicateMatchRaw: String?
    var relatedCopyCount: Int?

    var category: LaterCategory {
        get { LaterCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var kind: LaterKind {
        get { kindRaw.flatMap(LaterKind.init(rawValue:)) ?? .fallback(for: category) }
        set { kindRaw = newValue.rawValue }
    }

    var isCompleted: Bool { completedAt != nil }
    var isDuplicateCopy: Bool { duplicateOfItemID != nil }

    var importantDateRole: ImportantDateRole? {
        get { importantDateRoleRaw.flatMap(ImportantDateRole.init(rawValue:)) }
        set { importantDateRoleRaw = newValue?.rawValue }
    }

    var screenSurface: ScreenshotSurface {
        get { screenSurfaceRaw.flatMap(ScreenshotSurface.init(rawValue:)) ?? .unknown }
        set { screenSurfaceRaw = newValue.rawValue }
    }

    var sourceApp: ScreenshotSourceApp {
        get { sourceAppRaw.flatMap(ScreenshotSourceApp.init(rawValue:)) ?? .unknown }
        set { sourceAppRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        title: String,
        category: LaterCategory,
        kind: LaterKind,
        confidence: Double,
        createdAt: Date,
        screenshotAssetIdentifier: String,
        rawOCRText: String,
        needsReview: Bool
    ) {
        self.id = id
        self.title = title
        self.categoryRaw = category.rawValue
        self.kindRaw = kind.rawValue
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = .now
        self.screenshotAssetIdentifier = screenshotAssetIdentifier
        self.rawOCRText = rawOCRText
        self.statusRaw = "open"
        self.isUserCorrected = false
        self.needsReview = needsReview
        self.resurfacedCount = 0
    }
}
