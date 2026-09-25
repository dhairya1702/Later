import SwiftData
import UIKit

@MainActor
struct ShareInboxImporter {
    let context: ModelContext

    func importPending() async {
        let store = ShareInboxStore()
        let records = (try? store.records()) ?? []

        for originalRecord in records {
            guard !Task.isCancelled else { return }
            var record = originalRecord

            do {
                let data = try store.imageData(for: record)
                guard let image = UIImage(data: data) else { throw ShareInboxError.invalidImage }

                if record.fingerprint == nil {
                    record.fingerprint = ImageFingerprintGenerator().fingerprint(data: data)
                        ?? ImageFingerprintGenerator().fingerprint(image)
                    try store.save(record)
                }

                // The share extension normally finishes analysis before it dismisses.
                // This only runs when it could not reach the vision bridge in time.
                if record.analysis == nil {
                    record.analysis = try await VisionBridgeClient().analyze(
                        data: data,
                        contentType: record.imageFilename.hasSuffix(".png")
                            ? "image/png"
                            : "image/jpeg"
                    )
                    record.lastError = nil
                    try store.save(record)
                }
                guard let analysis = record.analysis else { continue }

                let repository = ItemRepository(context: context)
                let resolution = try repository.resolve(
                    from: record,
                    classification: analysis.classification,
                    fingerprint: record.fingerprint
                )
                let item = resolution.item

                if let fingerprint = record.fingerprint {
                    try DuplicateScreenshotDetector(context: context).analyze(
                        item: item,
                        fingerprint: fingerprint,
                        text: analysis.visibleText
                    )
                }

                // Merged items were already announced by whichever route arrived first.
                if !record.notificationDelivered && resolution.isNew && !item.isDuplicateCopy {
                    await NotificationManager.shared.handleSharedItemProcessed(item)
                } else {
                    await NotificationManager.shared.reconcile()
                }
                try store.removeRecord(record)
            } catch {
                record.lastError = error.localizedDescription
                try? store.save(record)
            }
        }

        reconcilePreviouslyImportedSharedItems(using: store)
    }

    private func reconcilePreviouslyImportedSharedItems(using store: ShareInboxStore) {
        guard let items = try? context.fetch(FetchDescriptor<LaterItem>()) else { return }
        for item in items where item.sharedImageFilename != nil && item.imageContentHash == nil {
            guard let filename = item.sharedImageFilename,
                  let data = try? Data(contentsOf: store.imageURL(filename: filename)),
                  let fingerprint = ImageFingerprintGenerator().fingerprint(data: data) else {
                continue
            }
            try? DuplicateScreenshotDetector(context: context).analyze(
                item: item,
                fingerprint: fingerprint,
                text: item.rawOCRText
            )
        }
    }
}
