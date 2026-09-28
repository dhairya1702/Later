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
    var keepFromCleanup: Bool?

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

/// One policy shared by scheduled reminders, immediate reminders and cleanup UI.
enum ItemCleanupReason: Hashable {
    case expired
    case datePassed
    case old

    var displayName: String {
        switch self {
        case .expired: "Expired"
        case .datePassed: "Date passed"
        case .old: "6+ months ago"
        }
    }
}

struct ItemRelevancePolicy {
    var calendar: Calendar = .current

    func meaningfulDate(for item: LaterItem) -> Date? {
        guard item.meaningfulDateRole != nil, !item.needsReview else { return nil }
        return item.detectedDate ?? Self.explicitDate(item.detectedDateText, time: item.detectedTimeText)
    }

    // Never let NSDataDetector silently turn a yearless or relative date into a
    // future date based on the day an old screenshot happens to be imported.
    static func explicitDate(_ text: String?, time: String? = nil) -> Date? {
        guard let text,
              text.range(of: #"\b(?:19|20)\d{2}\b"#, options: .regularExpression) != nil,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        else { return nil }
        let input = [text, time].compactMap { $0 }.joined(separator: " ")
        let matches = detector.matches(in: input, range: NSRange(input.startIndex..., in: input))
        guard matches.count == 1 else { return nil }
        return matches.first?.date
    }

    func hasPassed(_ item: LaterItem, at date: Date) -> Bool {
        guard let relevantDate = meaningfulDate(for: item),
              let role = item.meaningfulDateRole else { return false }
        // Date-only items remain relevant through the whole local calendar day.
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: relevantDate))!
        let cutoff: Date
        switch role {
        case .delivery: cutoff = calendar.date(byAdding: .day, value: 7, to: endOfDay)!
        case .event, .reservation, .travel: cutoff = endOfDay
        case .expiration, .deadline:
            cutoff = item.detectedTimeText == nil ? endOfDay : relevantDate
        case .unspecified: return false
        }
        return date >= cutoff
    }

    func allowsReminder(_ item: LaterItem, at date: Date) -> Bool {
        guard !item.isCompleted, !item.isDuplicateCopy, item.screenSurface != .lockScreen,
              item.statusRaw != "archived", !hasPassed(item, at: date),
              item.snoozedUntil == nil || item.snoozedUntil! <= date else { return false }
        if meaningfulDate(for: item) != nil { return true }
        return date < calendar.date(byAdding: .day, value: 90, to: item.createdAt)!
    }

    func cleanupReason(for item: LaterItem, at date: Date = .now) -> ItemCleanupReason? {
        guard !item.isCompleted, !item.isDuplicateCopy, item.statusRaw != "archived",
              item.keepFromCleanup != true, !item.needsReview,
              item.snoozedUntil == nil || item.snoozedUntil! <= date else { return nil }
        // Lasting images and records should not receive deletion suggestions.
        let protectedKinds: Set<LaterKind> = [.photo, .meme, .recipe, .style, .home,
            .product, .book, .movie, .show, .music, .article, .document, .information]
        guard item.category != .photo, item.category != .inspire,
              !protectedKinds.contains(item.kind) else { return nil }
        if hasPassed(item, at: date) {
            return item.meaningfulDateRole == .expiration ? .expired : .datePassed
        }
        if let relevantDate = meaningfulDate(for: item), relevantDate >= date { return nil }
        let temporaryKinds: Set<LaterKind> = [.offer, .event, .concert, .boardingPass, .shopping, .task]
        guard temporaryKinds.contains(item.kind),
              date >= calendar.date(byAdding: .day, value: 180, to: item.createdAt)! else { return nil }
        return .old
    }
}
