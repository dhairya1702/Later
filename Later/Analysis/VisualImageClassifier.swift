import UIKit
import Vision

struct VisualClassification {
    let labels: [VisualLabel]
    let category: LaterCategory
    let kind: LaterKind
    let confidence: Double
}

struct VisualClassificationRouter {
    func route(labels: [VisualLabel]) -> VisualClassification {
        let topConfidence = labels.first?.confidence ?? 0

        let routes: [(keywords: [String], minimumConfidence: Double, category: LaterCategory, kind: LaterKind)] = [
            (["coupon", "voucher", "ticket"], 0.45, .offer, .offer),
            (["meme", "comic", "cartoon", "emoji"], 0.30, .photo, .meme),
            (["document", "receipt", "invoice", "handwriting"], 0.70, .remember, .document),
            (["clothing", "apparel", "outfit", "dress", "shirt", "shoe", "sneaker", "hairstyle", "hair", "makeup", "jewelry"], 0.22, .inspire, .style),
            (["interior", "furniture", "living room", "bedroom", "kitchen", "home decor", "architecture", "building"], 0.22, .inspire, .home),
            (["food", "dish", "meal", "dessert", "bread", "cake", "pizza", "burger", "drink", "cuisine"], 0.22, .inspire, .recipe),
            (["product", "package", "appliance", "electronics", "gadget"], 0.40, .inspire, .product),
            (["landscape", "scenery", "beach", "mountain", "park", "garden", "travel"], 0.22, .inspire, .place)
        ]

        for route in routes {
            if let match = labels.prefix(4).first(where: { label in
                label.confidence >= route.minimumConfidence && route.keywords.contains {
                    label.identifier.localizedCaseInsensitiveContains($0)
                }
            }) {
                return VisualClassification(
                    labels: labels,
                    category: route.category,
                    kind: route.kind,
                    confidence: match.confidence
                )
            }
        }

        return VisualClassification(
            labels: labels,
            category: .photo,
            kind: .photo,
            confidence: max(0.45, topConfidence)
        )
    }
}

actor VisualImageClassifier {
    static let shared = VisualImageClassifier()

    func classify(_ image: UIImage) -> VisualClassification? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)

        do {
            try handler.perform([request])
            let labels = (request.results ?? [])
                .filter { $0.confidence >= 0.04 }
                .prefix(8)
                .map {
                    VisualLabel(
                        identifier: $0.identifier,
                        confidence: Double($0.confidence)
                    )
                }
            guard !labels.isEmpty else { return nil }
            return VisualClassificationRouter().route(labels: labels)
        } catch {
            return nil
        }
    }
}
