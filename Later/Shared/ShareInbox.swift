import Foundation
import UIKit

enum ShareInboxConfiguration {
    static let appGroup = "group.com.dhairyalalwani.Later"
}

struct ShareInboxRecord: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let imageFilename: String
    var fingerprint: ScreenshotFingerprint?
    var analysis: VisionAnalysis?
    var lastError: String?
    var notificationDelivered: Bool
}

enum ShareInboxError: LocalizedError {
    case unavailable
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .unavailable: "Later's shared inbox is unavailable."
        case .invalidImage: "The shared screenshot is not a valid image."
        }
    }
}

struct ShareInboxStore {
    private let fileManager = FileManager.default

    /// Writes the shared screenshot losslessly. Recompressing here would change the
    /// pixels Photos discovery later sees and break fingerprint matching.
    func enqueue(
        _ image: UIImage,
        originalData: Data?,
        fingerprint: ScreenshotFingerprint?
    ) throws -> ShareInboxRecord {
        guard let data = Self.losslessPNG(originalData: originalData, image: image) else {
            throw ShareInboxError.invalidImage
        }
        let id = UUID()
        let filename = "\(id.uuidString).png"
        try prepareDirectories()
        try data.write(to: imagesURL.appendingPathComponent(filename), options: .atomic)
        let record = ShareInboxRecord(
            id: id,
            createdAt: .now,
            imageFilename: filename,
            fingerprint: fingerprint,
            analysis: nil,
            lastError: nil,
            notificationDelivered: false
        )
        try save(record)
        return record
    }

    func records() throws -> [ShareInboxRecord] {
        try prepareDirectories()
        let urls = try fileManager.contentsOfDirectory(
            at: recordsURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(ShareInboxRecord.self, from: data)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    func imageData(for record: ShareInboxRecord) throws -> Data {
        try Data(contentsOf: imageURL(filename: record.imageFilename))
    }

    func image(for record: ShareInboxRecord) throws -> UIImage {
        guard let image = UIImage(data: try imageData(for: record)) else {
            throw ShareInboxError.invalidImage
        }
        return image
    }

    func imageURL(filename: String) -> URL {
        imagesURL.appendingPathComponent(filename)
    }

    func save(_ record: ShareInboxRecord) throws {
        try prepareDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: recordURL(id: record.id), options: .atomic)
    }

    func removeRecord(_ record: ShareInboxRecord) throws {
        let url = recordURL(id: record.id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private static func losslessPNG(originalData: Data?, image: UIImage) -> Data? {
        if let originalData, originalData.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return originalData
        }
        return image.pngData()
    }

    private var rootURL: URL {
        guard let url = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: ShareInboxConfiguration.appGroup
        ) else { fatalError(ShareInboxError.unavailable.localizedDescription) }
        return url.appendingPathComponent("ShareInbox", isDirectory: true)
    }

    private var recordsURL: URL { rootURL.appendingPathComponent("Records", isDirectory: true) }
    private var imagesURL: URL { rootURL.appendingPathComponent("Images", isDirectory: true) }
    private func recordURL(id: UUID) -> URL { recordsURL.appendingPathComponent("\(id.uuidString).json") }

    private func prepareDirectories() throws {
        guard fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: ShareInboxConfiguration.appGroup
        ) != nil else { throw ShareInboxError.unavailable }
        try fileManager.createDirectory(at: recordsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    }
}
