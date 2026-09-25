import Foundation
import UIKit

struct VisionBridgeEnvelope: Codable {
    let analysis: VisionAnalysis
}

struct VisionAnalysis: Codable {
    let title: String
    let summary: String
    let suggestedAction: String
    let visibleText: String
    let category: String
    let kind: String
    let surface: String
    let sourceApp: String
    let confidence: Double
    let needsReview: Bool
    let evidence: [String]
    let actionableEntities: [VisionActionableEntity]?
    let media: VisionMedia?
    let productDetails: VisionProductDetails?
    let facts: VisionFacts
}

struct VisionActionableEntity: Codable {
    let type: String
    let value: String
    let confidence: Double
    let evidence: String
}

struct VisionMedia: Codable {
    let type: String
    let title: String
    let creator: String
    let sourceService: String
    let confidence: Double
    let evidence: [String]
}

struct VisionProductDetails: Codable {
    let name: String
    let brand: String?
    let model: String?
    let variant: String?
    let currentPrice: String?
    let originalPrice: String?
    let discount: String?
    let seller: String?
    let condition: String?
    let negotiable: String?
    let rating: String?
    let reviewCount: String?
    let delivery: String?
    let availability: String?
    let fulfillment: String?
    let location: String?
    let confidence: Double
    let evidence: [String]
}

struct VisionFacts: Codable {
    let dateText: String?
    let timeText: String?
    let dateRole: String?
    let location: String?
    let priceText: String?
    let currency: String?
    let url: String?
    let couponCode: String?
    let discountText: String?
}

private struct VisionBridgeError: Decodable {
    let error: String
}

enum VisionBridgeClientError: LocalizedError {
    case missingEndpoint
    case invalidImage
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingEndpoint: "The local vision bridge URL is missing."
        case .invalidImage: "The screenshot could not be prepared for analysis."
        case .invalidResponse: "The local vision bridge returned an invalid response."
        case .server(let message): message
        }
    }
}

struct VisionBridgeClient {
    func analyze(_ image: UIImage) async throws -> VisionAnalysis {
        guard let data = image.jpegData(compressionQuality: 0.82) else {
            throw VisionBridgeClientError.invalidImage
        }
        return try await analyze(data: data, contentType: "image/jpeg")
    }

    func analyze(
        data: Data,
        contentType: String,
        timeout: TimeInterval = 120
    ) async throws -> VisionAnalysis {
        var request = try makeRequest(contentType: contentType, timeout: timeout)
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        return try decode(responseData, response: response)
    }

    func makeRequest(
        contentType: String = "image/jpeg",
        timeout: TimeInterval = 120
    ) throws -> URLRequest {
        guard let baseURLString = Bundle.main.object(
            forInfoDictionaryKey: "LaterVisionBaseURL"
        ) as? String,
              let url = URL(string: baseURLString)?.appendingPathComponent("analyze") else {
            throw VisionBridgeClientError.missingEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

    func decode(_ responseData: Data, response: URLResponse?) throws -> VisionAnalysis {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VisionBridgeClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(
                VisionBridgeError.self,
                from: responseData
            ).error) ?? "Vision analysis failed with HTTP \(httpResponse.statusCode)."
            throw VisionBridgeClientError.server(message)
        }
        return try JSONDecoder().decode(VisionBridgeEnvelope.self, from: responseData).analysis
    }
}
