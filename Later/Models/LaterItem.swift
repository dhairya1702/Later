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
    var sharedImageFilename: String?
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
    var actionableEntitiesJSON: Data?
    var detectedMediaJSON: Data?
    var productDetailsJSON: Data?
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

    /// Marks an item that only exists because it was shared. It is replaced by the
    /// real Photos local identifier as soon as discovery recognises the same pixels.
    static let sharedIdentifierPrefix = "shared:"

    static func sharedIdentifier(for recordID: UUID) -> String {
        "\(sharedIdentifierPrefix)\(recordID.uuidString)"
    }

    var isCompleted: Bool { completedAt != nil }
    var isDuplicateCopy: Bool { duplicateOfItemID != nil }

    var hasPhotoLibraryAsset: Bool {
        guard let screenshotAssetIdentifier else { return false }
        return !screenshotAssetIdentifier.hasPrefix(Self.sharedIdentifierPrefix)
    }

    var photoLibraryAssetIdentifier: String? {
        hasPhotoLibraryAsset ? screenshotAssetIdentifier : nil
    }

    var actionableEntities: [ActionableEntity] {
        guard let actionableEntitiesJSON else { return [] }
        return (try? JSONDecoder().decode([ActionableEntity].self, from: actionableEntitiesJSON)) ?? []
    }

    var detectedMedia: DetectedMedia? {
        guard let detectedMediaJSON else { return nil }
        return try? JSONDecoder().decode(DetectedMedia.self, from: detectedMediaJSON)
    }

    var productDetails: DetectedProductDetails? {
        guard let productDetailsJSON else { return nil }
        return try? JSONDecoder().decode(DetectedProductDetails.self, from: productDetailsJSON)
    }

    var importantDateRole: ImportantDateRole? {
        get { importantDateRoleRaw.flatMap(ImportantDateRole.init(rawValue:)) }
        set { importantDateRoleRaw = newValue?.rawValue }
    }

    var meaningfulDateRole: ImportantDateRole? {
        guard let role = importantDateRole, role != .unspecified else { return nil }
        let chromeHeavyKinds: Set<LaterKind> = [.chat, .story, .comments, .lockScreen]
        let chromeHeavySurfaces: Set<ScreenshotSurface> = [.chat, .story, .comments, .lockScreen]
        if chromeHeavyKinds.contains(kind) || chromeHeavySurfaces.contains(screenSurface) {
            // Older analyses inferred roles from category alone, so timestamps on
            // these surfaces cannot be distinguished from app chrome reliably.
            return nil
        }
        return role
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
