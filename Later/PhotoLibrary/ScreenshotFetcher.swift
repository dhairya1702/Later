import Photos

struct ScreenshotFetcher {
    func allScreenshots() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "(mediaSubtype & %d) != 0",
            PHAssetMediaSubtype.photoScreenshot.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(with: .image, options: options)
    }

    func latest(limit: Int = 50) -> [PHAsset] {
        let result = allScreenshots()
        var assets: [PHAsset] = []
        assets.reserveCapacity(min(limit, result.count))
        result.enumerateObjects { asset, _, stop in
            assets.append(asset)
            if assets.count == limit { stop.pointee = true }
        }
        return assets
    }
}
