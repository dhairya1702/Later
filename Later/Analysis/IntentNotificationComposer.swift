import Foundation

struct IntentNotificationCopy: Equatable {
    let title: String
    let body: String
}

/// Converts classified, OCR-grounded metadata into language about the thing the
/// user saved. It never invents a person, venue, date, price, or action.
struct IntentNotificationComposer {
    let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func compose(
        for item: LaterItem,
        referenceDate: Date = .now
    ) -> IntentNotificationCopy {
        switch item.category {
        case .doItem:
            return IntentNotificationCopy(
                title: taskAction(in: item.rawOCRText) ?? groundedTitle(item, fallback: "A task you wanted to handle"),
                body: timingBody(for: item, referenceDate: referenceDate) ?? "You meant to take care of this."
            )
        case .offer:
            return IntentNotificationCopy(
                title: offerTitle(for: item),
                body: expirationBody(for: item, referenceDate: referenceDate) ?? offerDetail(for: item)
            )
        case .watch:
            return IntentNotificationCopy(
                title: prefixed("Watch", to: groundedTitle(item, fallback: "Something on your watch list")),
                body: timingBody(for: item, referenceDate: referenceDate) ?? "Still on your watch list."
            )
        case .listen:
            return IntentNotificationCopy(
                title: prefixed("Listen to", to: groundedTitle(item, fallback: "Music you saved")),
                body: "Still on your listening list."
            )
        case .eat:
            return IntentNotificationCopy(
                title: prefixed("Try", to: groundedTitle(item, fallback: "A place you wanted to try")),
                body: locationBody(for: item) ?? "A place you wanted to eat."
            )
        case .go:
            return IntentNotificationCopy(
                title: visitTitle(for: item),
                body: timingBody(for: item, referenceDate: referenceDate)
                    ?? locationBody(for: item)
                    ?? "A place or event you wanted to visit."
            )
        case .buy:
            return IntentNotificationCopy(
                title: groundedTitle(item, fallback: "Something you wanted to buy"),
                body: priceBody(for: item) ?? "Still thinking about it?"
            )
        case .read:
            return IntentNotificationCopy(
                title: prefixed("Read", to: groundedTitle(item, fallback: "Something on your reading list")),
                body: "Still on your reading list."
            )
        case .remember:
            return IntentNotificationCopy(
                title: groundedTitle(item, fallback: "Something you wanted to remember"),
                body: timingBody(for: item, referenceDate: referenceDate) ?? "Worth keeping in mind."
            )
        case .inspire:
            return IntentNotificationCopy(
                title: groundedTitle(item, fallback: "An idea you wanted to revisit"),
                body: "An idea worth coming back to."
            )
        case .photo:
            return IntentNotificationCopy(
                title: groundedTitle(item, fallback: "A photo you wanted to revisit"),
                body: "Worth another look."
            )
        case .other:
            return IntentNotificationCopy(
                title: "You might want to check this out",
                body: "You saved this screenshot recently."
            )
        }
    }

    func taskAction(in text: String) -> String? {
        let candidates = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 && $0.count <= 140 }
        let pattern = #"(?i)\b(?:text|call|email|send|buy|book|cancel|pay|apply|submit|schedule|reserve|pick\s+up|reply|follow\s+up|order|return)\b[^\n.!?]{1,100}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }

        let matches = candidates.compactMap { candidate -> (text: String, score: Int)? in
            let range = NSRange(candidate.startIndex..., in: candidate)
            guard let match = expression.firstMatch(in: candidate, range: range),
                  let swiftRange = Range(match.range, in: candidate) else { return nil }
            let action = String(candidate[swiftRange])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            guard action.split(separator: " ").count >= 2 else { return nil }
            let prefixLength = candidate.distance(from: candidate.startIndex, to: swiftRange.lowerBound)
            return (sentenceCased(action), max(0, 30 - prefixLength) - action.count / 10)
        }
        return matches.max(by: { $0.score < $1.score })?.text
    }

    private func offerTitle(for item: LaterItem) -> String {
        let title = groundedTitle(item, fallback: "An offer you wanted to use")
        guard let discount = item.discountText,
              !title.localizedCaseInsensitiveContains(discount) else { return title }
        return "\(discount): \(title)"
    }

    private func visitTitle(for item: LaterItem) -> String {
        let title = groundedTitle(item, fallback: "A place or event you wanted to visit")
        if item.kind == .concert || item.kind == .event { return title }
        return prefixed("Visit", to: title)
    }

    private func timingBody(for item: LaterItem, referenceDate: Date) -> String? {
        var parts: [String] = []
        if let date = item.detectedDate {
            parts.append(relativeDate(date, fallback: item.detectedDateText, referenceDate: referenceDate))
        } else if let dateText = item.detectedDateText {
            parts.append(dateText)
        }
        if let time = item.detectedTimeText,
           !parts.contains(where: { $0.localizedCaseInsensitiveContains(time) }) {
            if parts.isEmpty {
                parts.append(time)
            } else {
                parts[0] += " at \(time)"
            }
        }
        if let location = item.detectedLocation { parts.append(location) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func expirationBody(for item: LaterItem, referenceDate: Date) -> String? {
        guard item.importantDateRole == .expiration else { return nil }
        if let date = item.detectedDate {
            return "Expires \(relativeDate(date, fallback: item.detectedDateText, referenceDate: referenceDate).lowercased())"
        }
        if let dateText = item.detectedDateText { return "Expires \(dateText)" }
        return nil
    }

    private func relativeDate(_ date: Date, fallback: String?, referenceDate: Date) -> String {
        if calendar.isDate(date, inSameDayAs: referenceDate) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: referenceDate),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: referenceDate),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        if (2...6).contains(days) {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        }
        if let fallback, !fallback.isEmpty { return fallback }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func priceBody(for item: LaterItem) -> String? {
        guard let price = item.detectedPrice else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = item.detectedCurrency ?? "USD"
        return formatter.string(from: NSNumber(value: price)).map { "\($0) · Still thinking about it?" }
    }

    private func offerDetail(for item: LaterItem) -> String {
        if let code = item.couponCode { return "Code: \(code)" }
        return "Still available when you need it."
    }

    private func locationBody(for item: LaterItem) -> String? {
        item.detectedLocation.map { "\($0) · Still want to go?" }
    }

    private func groundedTitle(_ item: LaterItem, fallback: String) -> String {
        let normalized = item.title.lowercased()
        if normalized.hasPrefix("saved ") || normalized == "saved screenshot" { return fallback }
        return item.title
    }

    private func prefixed(_ prefix: String, to title: String) -> String {
        if title.lowercased().hasPrefix(prefix.lowercased() + " ") { return title }
        return "\(prefix) \(title)"
    }

    private func sentenceCased(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }
}
