import CryptoKit
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

struct ScreenshotFingerprint {
    let exactHash: String
    let perceptualHash: String
    let pixelWidth: Int
    let pixelHeight: Int
}

struct DuplicateScreenshotMatcher {
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

struct ImageFingerprintGenerator {
    func fingerprint(_ image: UIImage) -> ScreenshotFingerprint? {
        guard let exactBytes = normalizedRGBA(image, width: 64, height: 64),
              let grayscale = normalizedGrayscale(image, width: 9, height: 8) else {
            return nil
        }

        var differenceHash: UInt64 = 0
        for row in 0..<8 {
            for column in 0..<8 {
                differenceHash <<= 1
                let left = grayscale[row * 9 + column]
                let right = grayscale[row * 9 + column + 1]
                if left > right { differenceHash |= 1 }
            }
        }

        return ScreenshotFingerprint(
            exactHash: SHA256.hash(data: Data(exactBytes)).map { String(format: "%02x", $0) }.joined(),
            perceptualHash: String(format: "%016llx", differenceHash),
            pixelWidth: Int(image.size.width * image.scale),
            pixelHeight: Int(image.size.height * image.scale)
        )
    }

    private func normalizedRGBA(_ image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    private func normalizedGrayscale(_ image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }
}

@MainActor
struct DuplicateScreenshotDetector {
    let context: ModelContext

    func analyze(item: LaterItem, image: UIImage, text: String) throws {
        guard let fingerprint = ImageFingerprintGenerator().fingerprint(image) else { return }
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
                exactHash: fingerprint.exactHash,
                perceptualHash: fingerprint.perceptualHash,
                text: text,
                pixelWidth: fingerprint.pixelWidth,
                pixelHeight: fingerprint.pixelHeight,
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
