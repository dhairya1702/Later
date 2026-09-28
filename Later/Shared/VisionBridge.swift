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
    let sourceContext: String?
    let likelyAccidental: Bool
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
        case .missingEndpoint: "The screenshot analysis service URL is missing."
        case .invalidImage: "The screenshot could not be prepared for analysis."
        case .invalidResponse: "The screenshot analysis service returned an invalid response."
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
        if let token = Bundle.main.object(forInfoDictionaryKey: "LaterAnalysisToken") as? String,
           !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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

/// Owns the system background upload used by the share extension. iOS continues
/// this transfer after the share sheet dismisses and relaunches the containing app
/// to deliver the response when necessary.
final class ShareAnalysisUploadManager: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    static let shared = ShareAnalysisUploadManager()
    static let sessionIdentifier = "com.dhairyalalwani.Later.share-analysis"

    private let lock = NSLock()
    private var responseData: [Int: Data] = [:]
    private var pushDelivery: [Int: Bool] = [:]
    private var backgroundEventsCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: Self.sessionIdentifier
        )
        configuration.sharedContainerIdentifier = ShareInboxConfiguration.appGroup
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    func upload(_ record: ShareInboxRecord) throws {
        let store = ShareInboxStore()
        var request = try VisionBridgeClient().makeRequest(
            contentType: "image/png",
            timeout: 180
        )
        request.setValue(record.id.uuidString, forHTTPHeaderField: "X-Later-Item-ID")

        let defaults = UserDefaults(suiteName: ShareInboxConfiguration.appGroup)
        if let token = defaults?.string(forKey: ShareInboxConfiguration.pushTokenKey),
           !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Later-Push-Token")
            request.setValue(
                defaults?.string(forKey: ShareInboxConfiguration.apnsEnvironmentKey) ?? "production",
                forHTTPHeaderField: "X-Later-APNS-Environment"
            )
        }

        let task = session.uploadTask(
            with: request,
            fromFile: store.imageURL(filename: record.imageFilename)
        )
        task.taskDescription = record.id.uuidString
        task.resume()
    }

    func handleEvents(completionHandler: @escaping () -> Void) {
        lock.lock()
        backgroundEventsCompletionHandler = completionHandler
        lock.unlock()
        _ = session
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        responseData[dataTask.taskIdentifier] = Data()
        if let httpResponse = response as? HTTPURLResponse {
            pushDelivery[dataTask.taskIdentifier] =
                httpResponse.value(forHTTPHeaderField: "X-Later-Push-Sent") == "true"
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        responseData[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let data = responseData.removeValue(forKey: task.taskIdentifier)
        let pushWasSent = pushDelivery.removeValue(forKey: task.taskIdentifier) ?? false
        lock.unlock()

        guard let rawID = task.taskDescription, let id = UUID(uuidString: rawID) else { return }
        let store = ShareInboxStore()
        guard var record = try? store.records().first(where: { $0.id == id }) else { return }

        do {
            if let error { throw error }
            guard let data else { throw VisionBridgeClientError.invalidResponse }
            record.analysis = try VisionBridgeClient().decode(data, response: task.response)
            record.lastError = nil
            record.notificationDelivered = pushWasSent
            try store.save(record)
        } catch {
            record.lastError = error.localizedDescription
            try? store.save(record)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completionHandler = backgroundEventsCompletionHandler
        backgroundEventsCompletionHandler = nil
        lock.unlock()
        DispatchQueue.main.async { completionHandler?() }
    }
}
