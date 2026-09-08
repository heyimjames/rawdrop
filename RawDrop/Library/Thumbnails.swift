import Photos
import UIKit

/// Thin wrapper over PHCachingImageManager that streams the fast degraded
/// thumbnail first and the sharp one after, then ends.
final class Thumbnails {
    static let shared = Thumbnails()

    private let manager = PHCachingImageManager()

    func stream(for asset: PHAsset, targetSize: CGSize) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true

            let id = manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, userInfo in
                if let image { continuation.yield(image) }
                let degraded = (userInfo?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let cancelled = (userInfo?[PHImageCancelledKey] as? Bool) ?? false
                let failed = userInfo?[PHImageErrorKey] != nil
                if !degraded || cancelled || failed { continuation.finish() }
            }

            continuation.onTermination = { [manager] _ in
                manager.cancelImageRequest(id)
            }
        }
    }
}
