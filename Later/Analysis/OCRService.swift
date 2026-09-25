import UIKit
@preconcurrency import Vision

enum OCRError: LocalizedError {
    case invalidImage

    var errorDescription: String? { "Vision could not read this image." }
}

struct OCRBlock: Codable, Hashable {
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct OCRDocument: Codable, Hashable {
    let text: String
    let blocks: [OCRBlock]
}

struct OCRService {
    func recognizeText(in image: UIImage) async throws -> String {
        try await recognizeDocument(in: image).text
    }

    func recognizeDocument(in image: UIImage) async throws -> OCRDocument {
        guard let cgImage = image.cgImage else { throw OCRError.invalidImage }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let blocks = observations.compactMap { observation -> OCRBlock? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let box = observation.boundingBox
                    return OCRBlock(
                        text: candidate.string,
                        confidence: candidate.confidence,
                        x: box.origin.x,
                        y: box.origin.y,
                        width: box.width,
                        height: box.height
                    )
                }
                continuation.resume(returning: OCRDocument(
                    text: blocks.map(\.text).joined(separator: "\n"),
                    blocks: blocks
                ))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try VNImageRequestHandler(cgImage: cgImage).perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
