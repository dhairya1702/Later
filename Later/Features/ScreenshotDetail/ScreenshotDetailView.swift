import Photos
import SwiftData
import SwiftUI

struct ScreenshotDetailView: View {
    let asset: PHAsset

    @Environment(\.modelContext) private var modelContext
    @State private var image: UIImage?
    @State private var text = ""
    @State private var isProcessing = true
    @State private var errorMessage: String?
    @State private var classification: ClassificationResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let classification {
                    ClassificationDebugCard(result: classification)
                }

                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView("Loading screenshot…")
                            .frame(maxWidth: .infinity, minHeight: 280)
                    }
                }
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Extracted text")
                        .font(.headline)

                    if isProcessing {
                        HStack {
                            ProgressView()
                            Text("Reading on this iPhone…")
                                .foregroundStyle(.secondary)
                        }
                    } else if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    } else if text.isEmpty {
                        Text("No text was found in this screenshot.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(text)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("OCR Debug")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: asset.localIdentifier) { await loadAndRecognize() }
    }

    @MainActor
    private func loadAndRecognize() async {
        let repository = ScreenshotRepository(context: modelContext)

        do {
            let record = try repository.record(for: asset)
            if let savedText = record.OCRText, record.processingStatus == .completed {
                text = savedText
                let loadedImage = try? await loadOCRImage()
                image = loadedImage
                if let savedClassification = repository.savedClassification(for: record) {
                    classification = savedClassification
                } else {
                    classification = await classifyAndPersist(
                        savedText,
                        image: loadedImage,
                        ocrBlocks: repository.savedOCRBlocks(for: record),
                        record: record,
                        repository: repository
                    )
                }
                isProcessing = false
                return
            }

            record.processingStatus = .loadingImage
            try modelContext.save()
            let loadedImage = try await loadOCRImage()
            image = loadedImage

            record.processingStatus = .OCR
            try modelContext.save()
            let document = try await OCRService().recognizeDocument(in: loadedImage)
            try repository.saveOCR(document, for: record)
            text = document.text
            classification = await classifyAndPersist(
                document.text,
                image: loadedImage,
                ocrBlocks: document.blocks,
                record: record,
                repository: repository
            )
            _ = try? ItemRepository(context: modelContext).createIfNeeded(
                for: asset,
                text: document.text,
                classification: classification ?? .unavailable
            )
        } catch {
            errorMessage = error.localizedDescription
            if let record = try? repository.record(for: asset) {
                try? repository.saveFailure(error, for: record)
            }
        }

        isProcessing = false
    }

    @MainActor
    private func classifyAndPersist(
        _ text: String,
        image: UIImage?,
        ocrBlocks: [OCRBlock],
        record: ScreenshotRecord,
        repository: ScreenshotRepository
    ) async -> ClassificationResult {
        let result = await ScreenshotClassifier.shared.classify(
            text: text,
            image: image,
            ocrBlocks: ocrBlocks
        )
        try? repository.saveClassification(result, for: record)
        return result
    }

    private func loadOCRImage() async throws -> UIImage {
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

private struct ClassificationDebugCard: View {
    let result: ClassificationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(result.kind.displayName, systemImage: result.kind.icon)
                    .font(.title2.bold())
                Spacer()
                Text(result.needsReview ? "Needs You" : "Automatic")
                    .font(.caption.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(result.needsReview ? Color.orange.opacity(0.16) : Color.green.opacity(0.16))
                    .foregroundStyle(result.needsReview ? .orange : .green)
                    .clipShape(Capsule())
            }

            Text("Confidence \(result.confidence, format: .percent.precision(.fractionLength(0))) · margin \(result.margin, format: .percent.precision(.fractionLength(0)))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Intent: \(result.category == .other ? "No confident intent" : result.category.displayName) · Type confidence: \(result.kindConfidence, format: .percent.precision(.fractionLength(0)))")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let detection = result.screenDetection {
                Text("Screen: \(detection.surface.rawValue) · Source: \(detection.sourceApp.rawValue) · \(detection.confidence, format: .percent.precision(.fractionLength(0)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !detection.evidence.isEmpty {
                    Text("Signals: " + detection.evidence.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let facts = result.facts {
                let values = facts.discountTexts
                    + facts.couponCodes.map { "Code: \($0)" }
                    + facts.dateTexts
                    + facts.timeTexts
                    + facts.locations
                if !values.isEmpty {
                    Text(values.joined(separator: " · "))
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
            }

            if result.usedVisualClassification == true,
               let labels = result.visualLabels,
               !labels.isEmpty {
                Text("Visual: " + labels.prefix(4).map(\.identifier).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !result.semanticModelAvailable {
                Text("Apple sentence embeddings unavailable on this runtime; using rules-only scoring.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Category").bold()
                    Text("Rule").bold()
                    Text("Semantic").bold()
                    Text("Final").bold()
                }
                ForEach(result.scores.prefix(4)) { score in
                    GridRow {
                        Text(score.category.displayName)
                        Text(score.ruleScore, format: .percent.precision(.fractionLength(0)))
                        Text(score.semanticScore, format: .percent.precision(.fractionLength(0)))
                        Text(score.finalScore, format: .percent.precision(.fractionLength(0)))
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
