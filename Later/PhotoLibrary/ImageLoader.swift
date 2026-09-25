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
