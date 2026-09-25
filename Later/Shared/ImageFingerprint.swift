import CryptoKit
import ImageIO
import UIKit

/// A stable identity for a screenshot's pixels. Both ingestion routes — the share
/// extension and Photos discovery — produce this before anything is persisted, so
/// the same screenshot arriving twice resolves to one canonical item.
struct ScreenshotFingerprint: Codable, Hashable {
    let exactHash: String
    let perceptualHash: String
    let pixelWidth: Int
    let pixelHeight: Int
}

struct ImageFingerprintGenerator {
    /// The size every image is resampled to before hashing. Fingerprinting the
    /// encoded file through ImageIO at a fixed size is deterministic, so the share
    /// extension and Photos discovery derive byte-identical hashes from the same
    /// original file even though they work with differently sized working copies.
    private static let normalizationSize = 1024

    func fingerprint(data: Data) -> ScreenshotFingerprint? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.normalizationSize
        ] as CFDictionary) else { return nil }

        return fingerprint(
            cgImage: thumbnail,
            pixelWidth: properties?[kCGImagePropertyPixelWidth] as? Int ?? thumbnail.width,
            pixelHeight: properties?[kCGImagePropertyPixelHeight] as? Int ?? thumbnail.height
        )
    }

    func fingerprint(_ image: UIImage) -> ScreenshotFingerprint? {
        guard let cgImage = image.cgImage else { return nil }
        return fingerprint(
            cgImage: cgImage,
            pixelWidth: Int(image.size.width * image.scale),
            pixelHeight: Int(image.size.height * image.scale)
        )
    }

    private func fingerprint(
        cgImage: CGImage,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> ScreenshotFingerprint? {
        guard let exactBytes = normalizedRGBA(cgImage, width: 64, height: 64),
              let grayscale = normalizedGrayscale(cgImage, width: 9, height: 8) else {
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
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    private func normalizedRGBA(_ cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
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

    private func normalizedGrayscale(_ cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
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
