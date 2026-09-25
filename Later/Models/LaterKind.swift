import Foundation

enum LaterKind: String, Codable, CaseIterable, Identifiable {
    case concert
    case music
    case shopping
    case food
    case movie
    case show
    case activity
    case task
    case book
    case article
    case place
    case event
    case information
    case offer
    case photo
    case style
    case home
    case recipe
    case document
    case meme
    case product
    case chat
    case story
    case email
    case boardingPass
    case app
    case map
    case socialPost
    case comments
    case lockScreen
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .concert: "Concert"
        case .music: "Music"
        case .shopping: "Shopping"
        case .food: "Food"
        case .movie: "Movie"
        case .show: "Show"
        case .activity: "Activity"
        case .task: "To-do"
        case .book: "Book"
        case .article: "Article"
        case .place: "Place"
        case .event: "Event"
        case .information: "Remember"
        case .offer: "Offer"
        case .photo: "Photo"
        case .style: "Style inspiration"
        case .home: "Home inspiration"
        case .recipe: "Food inspiration"
        case .document: "Document"
        case .meme: "Meme"
        case .product: "Product inspiration"
        case .chat: "Chat"
        case .story: "Story"
        case .email: "Email"
        case .boardingPass: "Boarding pass"
        case .app: "App"
        case .map: "Map"
        case .socialPost: "Social post"
        case .comments: "Comments"
        case .lockScreen: "Lock Screen"
        case .other: "Misc / Junk"
        }
    }

    var icon: String {
        switch self {
        case .concert: "music.mic"
        case .music: "music.note"
        case .shopping: "bag.fill"
        case .food: "fork.knife"
        case .movie: "film.fill"
        case .show: "tv.fill"
        case .activity: "figure.hiking"
        case .task: "checklist"
        case .book: "book.closed.fill"
        case .article: "doc.text.fill"
        case .place: "mappin.and.ellipse"
        case .event: "ticket.fill"
        case .information: "brain.head.profile.fill"
        case .offer: "tag.fill"
        case .photo: "camera.fill"
        case .style: "tshirt.fill"
        case .home: "house.fill"
        case .recipe: "takeoutbag.and.cup.and.straw.fill"
        case .document: "doc.text.viewfinder"
        case .meme: "face.smiling.inverse"
        case .product: "shippingbox.fill"
        case .chat: "bubble.left.and.bubble.right.fill"
        case .story: "circle.dashed.inset.filled"
        case .email: "envelope.fill"
        case .boardingPass: "airplane.boarding"
        case .app: "app.badge.fill"
        case .map: "map.fill"
        case .socialPost: "text.bubble.fill"
        case .comments: "text.bubble.fill"
        case .lockScreen: "lock.iphone"
        case .other: "tray.full.fill"
        }
    }

    static func fallback(for category: LaterCategory) -> LaterKind {
        switch category {
        case .watch: .show
        case .listen: .music
        case .eat: .food
        case .go: .place
        case .buy: .shopping
        case .read: .article
        case .doItem: .task
        case .remember: .information
        case .offer: .offer
        case .inspire: .photo
        case .photo: .photo
        case .other: .other
        }
    }
}
