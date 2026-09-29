import CryptoKit
import DeviceCheck
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
        if let authorization = BackendCredentialStore.authorizationHeader {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.setValue(
            BackendCredentialStore.installationID,
            forHTTPHeaderField: "X-Later-Install-ID"
        )
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

enum BackendCredentialStore {
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: ShareInboxConfiguration.appGroup)
    }

    static var installationID: String {
        if let existing = defaults?.string(forKey: ShareInboxConfiguration.installationIDKey),
           UUID(uuidString: existing) != nil {
            return existing
        }
        let value = UUID().uuidString.lowercased()
        defaults?.set(value, forKey: ShareInboxConfiguration.installationIDKey)
        return value
    }

    static var appAttestKeyID: String? {
        get { defaults?.string(forKey: ShareInboxConfiguration.appAttestKeyIDKey) }
        set { defaults?.set(newValue, forKey: ShareInboxConfiguration.appAttestKeyIDKey) }
    }

    static var authorizationHeader: String? {
        if let token = defaults?.string(forKey: ShareInboxConfiguration.sessionTokenKey),
           defaults?.double(forKey: ShareInboxConfiguration.sessionExpirationKey) ?? 0
            > Date.now.timeIntervalSince1970 {
            return "AppAttest \(token)"
        }
        if let token = Bundle.main.object(forInfoDictionaryKey: "LaterAnalysisToken") as? String,
           !token.isEmpty {
            return "Bearer \(token)"
        }
        return nil
    }

    static var sessionIsFresh: Bool {
        let expiration = defaults?.double(
            forKey: ShareInboxConfiguration.sessionExpirationKey
        ) ?? 0
        return expiration > Date.now.addingTimeInterval(60 * 60).timeIntervalSince1970
    }

    static func saveSession(_ session: BackendSession) {
        defaults?.set(session.token, forKey: ShareInboxConfiguration.sessionTokenKey)
        defaults?.set(
            session.expiresAt / 1000,
            forKey: ShareInboxConfiguration.sessionExpirationKey
        )
    }

    static func clearAttestation() {
        defaults?.removeObject(forKey: ShareInboxConfiguration.appAttestKeyIDKey)
        defaults?.removeObject(forKey: ShareInboxConfiguration.sessionTokenKey)
        defaults?.removeObject(forKey: ShareInboxConfiguration.sessionExpirationKey)
    }
}

private struct BackendChallenge: Decodable {
    let challenge: String
}

struct BackendSession: Decodable {
    let token: String
    let expiresAt: Double
}

private struct BackendAttestationRequest: Encodable {
    let keyID: String
    let challenge: String
    let attestationObject: String
}

private struct BackendAssertionRequest: Encodable {
    let keyID: String
    let challenge: String
    let assertion: String
}

private struct BackendSecurityErrorBody: Decodable {
    let error: String
    let code: String?
}

private enum BackendSecurityClientError: LocalizedError {
    case unavailable
    case invalidResponse
    case server(message: String, code: String?)

    var errorDescription: String? {
        switch self {
        case .unavailable: "App Attest is unavailable."
        case .invalidResponse: "The security service returned an invalid response."
        case .server(let message, _): message
        }
    }

    var code: String? {
        guard case .server(_, let code) = self else { return nil }
        return code
    }
}

actor BackendAuthManager {
    static let shared = BackendAuthManager()

    private let service = DCAppAttestService.shared
    private var isPreparing = false

    func prepareCredential() async {
        guard service.isSupported,
              !BackendCredentialStore.sessionIsFresh,
              !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        do {
            let challenge = try await fetchChallenge()
            if let keyID = BackendCredentialStore.appAttestKeyID {
                do {
                    let assertion = try await generateAssertion(
                        keyID: keyID,
                        challenge: challenge.challenge
                    )
                    let session: BackendSession = try await post(
                        path: "auth/assert",
                        body: BackendAssertionRequest(
                            keyID: keyID,
                            challenge: challenge.challenge,
                            assertion: assertion.base64EncodedString()
                        )
                    )
                    BackendCredentialStore.saveSession(session)
                    return
                } catch let error as BackendSecurityClientError
                    where error.code == "unknown_key" {
                    BackendCredentialStore.clearAttestation()
                } catch {
                    if (error as NSError).domain == DCError.errorDomain {
                        BackendCredentialStore.clearAttestation()
                    } else {
                        throw error
                    }
                }
            }

            try await enroll(challenge: challenge.challenge)
        } catch {
            // The legacy credential remains available during migration. Enrollment is
            // intentionally silent and will retry the next time the main app opens.
        }
    }

    private func enroll(challenge: String) async throws {
        let keyID = try await generateKey()
        // Persist before attesting so a lost HTTP response can be recovered with an
        // assertion instead of abandoning a successfully registered hardware key.
        BackendCredentialStore.appAttestKeyID = keyID
        let clientDataHash = Data(SHA256.hash(data: Data(challenge.utf8)))
        let attestation = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            service.attestKey(keyID, clientDataHash: clientDataHash) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? BackendSecurityClientError.invalidResponse)
                }
            }
        }
        let session: BackendSession = try await post(
            path: "auth/attest",
            body: BackendAttestationRequest(
                keyID: keyID,
                challenge: challenge,
                attestationObject: attestation.base64EncodedString()
            )
        )
        BackendCredentialStore.saveSession(session)
    }

    private func generateKey() async throws -> String {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, Error>) in
            service.generateKey { keyID, error in
                if let keyID {
                    continuation.resume(returning: keyID)
                } else {
                    continuation.resume(throwing: error ?? BackendSecurityClientError.unavailable)
                }
            }
        }
    }

    private func generateAssertion(keyID: String, challenge: String) async throws -> Data {
        let hash = Data(SHA256.hash(data: Data(challenge.utf8)))
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            service.generateAssertion(keyID, clientDataHash: hash) { assertion, error in
                if let assertion {
                    continuation.resume(returning: assertion)
                } else {
                    continuation.resume(throwing: error ?? BackendSecurityClientError.unavailable)
                }
            }
        }
    }

    private func fetchChallenge() async throws -> BackendChallenge {
        let request = try request(path: "auth/challenge", body: Data("{}".utf8))
        return try await send(request)
    }

    private func post<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request
    ) async throws -> Response {
        let data = try JSONEncoder().encode(body)
        return try await send(request(path: path, body: data))
    }

    private func request(path: String, body: Data) throws -> URLRequest {
        guard let baseURLString = Bundle.main.object(
            forInfoDictionaryKey: "LaterVisionBaseURL"
        ) as? String,
              let url = URL(string: baseURLString)?.appendingPathComponent(path) else {
            throw BackendSecurityClientError.unavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BackendSecurityClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(BackendSecurityErrorBody.self, from: data)
            throw BackendSecurityClientError.server(
                message: body?.error ?? "Security request failed with HTTP \(http.statusCode).",
                code: body?.code
            )
        }
        return try JSONDecoder().decode(Response.self, from: data)
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
