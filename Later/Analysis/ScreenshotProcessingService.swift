import Photos
import SwiftData
import UIKit

@MainActor
struct ScreenshotProcessingService {
    let context: ModelContext

    func process(_ asset: PHAsset) async {
        guard !Task.isCancelled else { return }
        let items = ItemRepository(context: context)
        let screenshots = ScreenshotRepository(context: context)
        do {
            let record = try screenshots.record(for: asset)
            var text: String
            var ocrBlocks: [OCRBlock] = []
            var analysisImage: UIImage?

            if let savedText = record.OCRText, record.processingStatus == .completed {
                text = savedText
                ocrBlocks = screenshots.savedOCRBlocks(for: record)
                if record.OCRLayoutJSON == nil {
                    let image = try await loadOCRImage(for: asset)
                    analysisImage = image
                    let document = try await OCRService().recognizeDocument(in: image)
                    text = document.text
                    ocrBlocks = document.blocks
                    try screenshots.saveOCR(document, for: record)
                }
            } else {
                record.processingStatus = .loadingImage
                try context.save()
                let image = try await loadOCRImage(for: asset)
                analysisImage = image
                try Task.checkCancellation()
                record.processingStatus = .OCR
                try context.save()
                let document = try await OCRService().recognizeDocument(in: image)
                text = document.text
                ocrBlocks = document.blocks
                try Task.checkCancellation()
                try screenshots.saveOCR(document, for: record)
            }

            let classification: ClassificationResult
            if let savedClassification = screenshots.savedClassification(for: record) {
                classification = savedClassification
            } else {
                if analysisImage == nil {
                    analysisImage = try await loadOCRImage(for: asset)
                }
                classification = await ScreenshotClassifier.shared.classify(
                    text: text,
                    image: analysisImage,
                    ocrBlocks: ocrBlocks
                )
            }
            try screenshots.saveClassification(classification, for: record)
            let isNewItem = try items.item(for: asset.localIdentifier) == nil
            let item = try items.createIfNeeded(
                for: asset,
                text: text,
                classification: classification
            )
            if let analysisImage {
                try DuplicateScreenshotDetector(context: context).analyze(
                    item: item,
                    image: analysisImage,
                    text: text
                )
            }
            record.resultingItemID = item.id
            try context.save()
            await NotificationManager.shared.handleProcessed(
                item: item,
                captureDate: asset.creationDate ?? .now,
                isNew: isNewItem
            )
        } catch {
            if let record = try? screenshots.record(for: asset) {
                try? screenshots.saveFailure(error, for: record)
            }
        }
    }

    private func loadOCRImage(for asset: PHAsset) async throws -> UIImage {
        let maxDimension: CGFloat = 1800
        let scale = min(maxDimension / CGFloat(max(asset.pixelWidth, asset.pixelHeight)), 1)
        return try await ImageLoader().image(
            for: asset,
            targetSize: CGSize(
                width: CGFloat(asset.pixelWidth) * scale,
                height: CGFloat(asset.pixelHeight) * scale
            )
        )
    }
}
