import SwiftData
import UIKit

enum ScreenshotMatchKind: String {
    case duplicate
    case similar

    var displayName: String {
        switch self {
        case .duplicate: "Duplicate"
        case .similar: "Similar"
        }
    }
}

struct DuplicateScreenshotMatcher {
    func match(
        _ fingerprint: ScreenshotFingerprint,
        text: String,
        against candidate: LaterItem
    ) -> ScreenshotMatchKind? {
        match(
            exactHash: fingerprint.exactHash,
            perceptualHash: fingerprint.perceptualHash,
            text: text,
            pixelWidth: fingerprint.pixelWidth,
            pixelHeight: fingerprint.pixelHeight,
            against: candidate
        )
    }

    func match(
        exactHash: String,
        perceptualHash: String,
        text: String,
        pixelWidth: Int,
        pixelHeight: Int,
        against candidate: LaterItem
    ) -> ScreenshotMatchKind? {
        guard let candidateExactHash = candidate.imageContentHash,
              let candidatePerceptualHash = candidate.perceptualHash,
              let candidateWidth = candidate.sourcePixelWidth,
              let candidateHeight = candidate.sourcePixelHeight else { return nil }

        if exactHash == candidateExactHash { return .duplicate }

        let ratio = Double(pixelWidth) / Double(max(pixelHeight, 1))
        let candidateRatio = Double(candidateWidth) / Double(max(candidateHeight, 1))
        guard abs(ratio - candidateRatio) <= 0.02,
              let distance = hammingDistance(perceptualHash, candidatePerceptualHash) else {
            return nil
        }

        let textSimilarity = jaccardSimilarity(text, candidate.rawOCRText)
        let tokenCount = tokens(in: text).count
        let candidateTokenCount = tokens(in: candidate.rawOCRText).count

        if tokenCount >= 6, candidateTokenCount >= 6 {
            if distance <= 5 && textSimilarity >= 0.92 { return .duplicate }
            if distance <= 10 && textSimilarity >= 0.78 { return .similar }
        } else {
            // With little text, require an extremely close visual match.
            if distance <= 2 { return .duplicate }
            if distance <= 5 { return .similar }
        }
        return nil
    }

    private func hammingDistance(_ first: String, _ second: String) -> Int? {
        guard let firstValue = UInt64(first, radix: 16),
              let secondValue = UInt64(second, radix: 16) else { return nil }
        return (firstValue ^ secondValue).nonzeroBitCount
    }

    private func jaccardSimilarity(_ first: String, _ second: String) -> Double {
        let firstTokens = tokens(in: first)
        let secondTokens = tokens(in: second)
        let union = firstTokens.union(secondTokens)
        guard !union.isEmpty else { return 0 }
        return Double(firstTokens.intersection(secondTokens).count) / Double(union.count)
    }

    private func tokens(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 2 }
        )
    }
}

enum ScreenshotIngestionRoute {
    case share
    case photoLibrary
}

/// Share and Photos are two doors into the same screenshot, not two screenshots.
/// Before either route creates an item it asks whether the other route already
/// created one for these exact pixels, so the result is a single canonical item
/// that carries both identities instead of a pair grouped as duplicates.
@MainActor
struct CanonicalItemResolver {
    let context: ModelContext

    func canonicalItem(
        for fingerprint: ScreenshotFingerprint,
        arrivingFrom route: ScreenshotIngestionRoute
    ) throws -> LaterItem? {
        try context.fetch(FetchDescriptor<LaterItem>()).first { candidate in
            candidate.duplicateOfItemID == nil
                && isAwaiting(route, candidate)
                && isSameCapture(fingerprint, candidate)
        }
    }

    /// Only an item that is missing the identity this route supplies can adopt it.
    private func isAwaiting(_ route: ScreenshotIngestionRoute, _ item: LaterItem) -> Bool {
        switch route {
        case .photoLibrary:
            item.sharedImageFilename != nil && !item.hasPhotoLibraryAsset
        case .share:
            item.sharedImageFilename == nil && item.hasPhotoLibraryAsset
        }
    }

    /// Deliberately stricter than duplicate detection. A merge silently rewrites an
    /// existing item, so it must mean "these are literally the same capture".
    private func isSameCapture(
        _ fingerprint: ScreenshotFingerprint,
        _ candidate: LaterItem
    ) -> Bool {
        guard let candidateExact = candidate.imageContentHash else { return false }
        if fingerprint.exactHash == candidateExact { return true }

        // A transcoded share payload can decode to near-identical pixels. Require the
        // original dimensions to agree exactly and the perceptual hashes to be all
        // but identical before treating it as the same capture.
        guard let candidatePerceptual = candidate.perceptualHash,
              candidate.sourcePixelWidth == fingerprint.pixelWidth,
              candidate.sourcePixelHeight == fingerprint.pixelHeight,
              let first = UInt64(fingerprint.perceptualHash, radix: 16),
              let second = UInt64(candidatePerceptual, radix: 16) else { return false }
        return (first ^ second).nonzeroBitCount <= 2
    }
}

@MainActor
struct DuplicateScreenshotDetector {
    let context: ModelContext

    func analyze(item: LaterItem, image: UIImage, text: String) throws {
        guard let fingerprint = ImageFingerprintGenerator().fingerprint(image) else { return }
        try analyze(item: item, fingerprint: fingerprint, text: text)
    }

    func analyze(item: LaterItem, fingerprint: ScreenshotFingerprint, text: String) throws {
        item.imageContentHash = fingerprint.exactHash
        item.perceptualHash = fingerprint.perceptualHash
        item.sourcePixelWidth = fingerprint.pixelWidth
        item.sourcePixelHeight = fingerprint.pixelHeight

        // Preserve an existing relationship when a stale classification is refreshed.
        if item.duplicateOfItemID != nil {
            try context.save()
            return
        }

        let allItems = try context.fetch(FetchDescriptor<LaterItem>())
        if item.duplicateGroupID != nil {
            refreshSummary(for: item, among: allItems)
            try context.save()
            return
        }
        let matcher = DuplicateScreenshotMatcher()
        let candidates = allItems.filter {
            $0.id != item.id && $0.duplicateOfItemID == nil && $0.imageContentHash != nil
        }

        var bestMatch: (item: LaterItem, kind: ScreenshotMatchKind)?
        for candidate in candidates {
            guard let kind = matcher.match(
                fingerprint,
                text: text,
                against: candidate
            ) else { continue }
            bestMatch = (candidate, kind)
            if kind == .duplicate { break }
        }

        if let bestMatch {
            let groupID = bestMatch.item.duplicateGroupID ?? UUID()
            bestMatch.item.duplicateGroupID = groupID
            item.duplicateGroupID = groupID
            item.duplicateOfItemID = bestMatch.item.id
            item.duplicateMatchRaw = bestMatch.kind.rawValue
            refreshSummary(for: bestMatch.item, among: allItems)
        }
        try context.save()
    }

    private func refreshSummary(for primary: LaterItem, among items: [LaterItem]) {
        guard let groupID = primary.duplicateGroupID else { return }
        let copies = items.filter { $0.id != primary.id && $0.duplicateGroupID == groupID }
        primary.relatedCopyCount = copies.count
        primary.duplicateMatchRaw = copies.contains { $0.duplicateMatchRaw == ScreenshotMatchKind.duplicate.rawValue }
            ? ScreenshotMatchKind.duplicate.rawValue
            : ScreenshotMatchKind.similar.rawValue
    }
}
