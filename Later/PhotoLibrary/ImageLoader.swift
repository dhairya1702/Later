import Photos
import UIKit

enum ImageLoadingError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "The screenshot could not be loaded. It may no longer be available."
    }
}

struct ImageLoader {
    private let manager = PHCachingImageManager.default()

    /// The untouched file bytes. Fingerprinting these — rather than the resized
    /// working copy used for analysis — is what lets Photos discovery recognise a
    /// screenshot the share extension already fingerprinted from the same file.
    func originalData(for asset: PHAsset) async throws -> Data {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, info in
                if let data {
                    continuation.resume(returning: data)
                } else if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: ImageLoadingError.unavailable)
                }
            }
        }
    }

    func image(
        for asset: PHAsset,
        targetSize: CGSize,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .highQualityFormat
    ) async throws -> UIImage {
        let options = PHImageRequestOptions()
        options.deliveryMode = deliveryMode
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                guard !didResume else { return }

                if let error = info?[PHImageErrorKey] as? Error {
                    didResume = true
                    continuation.resume(throwing: error)
                } else if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    didResume = true
                    continuation.resume(throwing: CancellationError())
                } else if let image,
                          !((info?[PHImageResultIsDegradedKey] as? Bool) ?? false) {
                    didResume = true
                    continuation.resume(returning: image)
                }
            }
        }
    }
}
