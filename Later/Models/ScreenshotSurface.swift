import Foundation

enum ScreenshotSurface: String, Codable, Hashable {
    case chat
    case story
    case email
    case boardingPass
    case appStore
    case map
    case redditPost
    case comments
    case lockScreen
    case unknown
}

enum ScreenshotSourceApp: String, Codable, Hashable {
    case iMessage
    case whatsapp
    case snapchat
    case appleMail
    case gmail
    case outlook
    case reddit
    case appStore
    case appleMaps
    case googleMaps
    case instagram
    case youtube
    case appleMusic
    case spotify
    case amazon
    case flipkart
    case facebookMarketplace
    case ebay
    case tiktok
    case unknown
}

struct ScreenDetection: Codable, Hashable {
    let surface: ScreenshotSurface
    let sourceApp: ScreenshotSourceApp
    let confidence: Double
    let evidence: [String]

    static let unknown = ScreenDetection(
        surface: .unknown,
        sourceApp: .unknown,
        confidence: 0,
        evidence: []
    )
}
