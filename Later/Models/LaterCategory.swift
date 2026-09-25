import Foundation

enum LaterCategory: String, Codable, CaseIterable, Identifiable {
    case watch
    case listen
    case eat
    case go
    case buy
    case read
    case doItem
    case remember
    case offer
    case inspire
    case photo
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .watch: "Watch"
        case .listen: "Listen"
        case .eat: "Eat"
        case .go: "Go"
        case .buy: "Buy"
        case .read: "Read"
        case .doItem: "Do"
        case .remember: "Remember"
        case .offer: "Offer"
        case .inspire: "Inspiration"
        case .photo: "Photo"
        case .other: "Other"
        }
    }

    var icon: String {
        switch self {
        case .watch: "play.rectangle.fill"
        case .listen: "music.note"
        case .eat: "fork.knife"
        case .go: "mappin.and.ellipse"
        case .buy: "bag.fill"
        case .read: "book.fill"
        case .doItem: "checkmark.circle.fill"
        case .remember: "brain.head.profile.fill"
        case .offer: "tag.fill"
        case .inspire: "sparkles"
        case .photo: "camera.fill"
        case .other: "square.grid.2x2.fill"
        }
    }

    var openStatusLabel: String {
        switch self {
        case .watch: "Want to watch"
        case .listen: "Want to listen"
        case .eat: "Want to try"
        case .go: "Want to go"
        case .buy: "Want"
        case .read: "Want to read"
        case .doItem: "Open"
        case .remember: "Saved"
        case .offer: "Available"
        case .inspire: "Saved idea"
        case .photo: "Saved photo"
        case .other: "Saved"
        }
    }

    var completedStatusLabel: String {
        switch self {
        case .watch: "Watched"
        case .listen: "Listened"
        case .eat: "Tried"
        case .go: "Went"
        case .buy: "Bought"
        case .read: "Read"
        case .doItem: "Done"
        case .remember, .offer, .inspire, .photo, .other: "Archived"
        }
    }
}
