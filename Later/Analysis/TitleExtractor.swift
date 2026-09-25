import Foundation

struct TitleExtractor {
    private let junk = [
        "photos", "google", "sign in", "ai mode", "all", "news", "shopping",
        "forums", "videos", "images", "short videos", "ai mode", "al mode",
        "ai overview", "al overview",
        "show more", "ticketmaster",
        "overview", "menu", "reviews", "home", "search", "share", "sponsored products"
    ]

    func extract(
        from text: String,
        category: LaterCategory,
        screenDetection: ScreenDetection? = nil
    ) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && $0.count <= 70 }

        if screenDetection?.surface == .story,
           let creator = storyCreator(in: lines) {
            return creator
        }

        if screenDetection?.surface == .chat,
           let person = conversationPerson(in: lines) {
            return person
        }

        if screenDetection?.surface == .redditPost,
           let thread = redditThreadTitle(in: lines) {
            return thread
        }

        if screenDetection?.surface == .email,
           let subject = emailSubject(in: lines) {
            return subject
        }

        if screenDetection?.surface == .boardingPass,
           let flight = boardingPassTitle(in: lines) {
            return flight
        }

        if category == .watch,
           let question = lines.first(where: { $0.lowercased().hasPrefix("what is ") }) {
            return question
                .dropFirst("what is ".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "? "))
        }

        if category == .buy,
           let query = lines.first(where: { normalizedKey($0).hasPrefix("q ") }) {
            let cleaned = query
                .replacingOccurrences(of: #"^[Qq]\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(
                    of: #"(?i)\s*(?:buy|shop)\s*$"#,
                    with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(
                    of: #"(?i)\s*[$€£₹]\s?\d[\d,.]*\s*$"#,
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.count >= 4 { return cleaned }
        }

        let frequencies = Dictionary(grouping: lines, by: normalizedKey)
            .mapValues(\.count)
        let fullText = normalizedKey(text)

        let ranked = lines.enumerated().compactMap { index, line -> (String, Double)? in
            let key = normalizedKey(line)
            guard !junk.contains(key),
                  !key.hasPrefix("http"),
                  !key.hasPrefix("q "),
                  !key.contains("sign in"),
                  line.rangeOfCharacter(from: .letters) != nil else { return nil }

            let mentions = key.count >= 5
                ? fullText.components(separatedBy: key).count - 1
                : 1
            var score = Double(max(frequencies[key, default: 1], mentions) * 4)
            if line.count <= 40 { score += 2 }
            if line.split(separator: " ").count <= 6 { score += 2 }
            if index < 20 { score += 1 }
            if line.last == "." { score -= 2 }
            if line.split(separator: " ").last?.count ?? 0 <= 2 { score -= 8 }
            if line.contains(":") { score -= 1 }
            if key.contains("featured concert") || key.contains("upcoming event") { score -= 2 }
            return (line, score)
        }
        .sorted { $0.1 > $1.1 }

        if let title = ranked.first?.0 {
            return title
                .replacingOccurrences(of: #"^[•·]\s*"#, with: "", options: .regularExpression)
        }

        return switch category {
        case .watch: "Saved to watch"
        case .listen: "Saved music"
        case .eat: "Saved place to eat"
        case .go: "Saved place or event"
        case .buy: "Saved product"
        case .read: "Saved to read"
        case .doItem: "Saved task"
        case .remember: "Saved information"
        case .offer: "Saved offer"
        case .inspire: "Saved inspiration"
        case .photo: "Saved photo"
        case .other: "Saved screenshot"
        }
    }

    private func normalizedKey(_ line: String) -> String {
        line.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func storyCreator(in lines: [String]) -> String? {
        for line in lines {
            if let match = line.firstMatch(
                of: /^\s*(@?[\p{L}\p{N}._][\p{L}\p{N}._ ]{1,38}?)\s*(?:[·•]\s*)?\d+\s*[smhdw]\s*$/
            ) {
                let creator = String(match.1).trimmingCharacters(in: .whitespaces)
                if isPlausiblePerson(creator) { return creator }
            }
        }

        for index in lines.indices where lines[index].range(
            of: #"^\s*\d+\s*[smhdw]\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            guard index > lines.startIndex else { continue }
            let creator = lines[lines.index(before: index)]
            if isPlausiblePerson(creator) { return creator }
        }
        return nil
    }

    private func conversationPerson(in lines: [String]) -> String? {
        lines.first { line in
            let key = normalizedKey(line)
            let chrome = [
                "facetime", "imessage", "text message", "message", "online",
                "new snap", "opened", "received", "tap to load", "send a chat",
                "delivered", "read", "whatsapp",
                "messages and calls are endtoend encrypted", "verizon", "att",
                "lte", "5g", "wifi"
            ]
            return isPlausiblePerson(line)
                && !chrome.contains(key)
                && line.range(
                    of: #"^(?:today|yesterday)?\s*\d{1,2}:\d{2}(?:\s*[ap]m)?$"#,
                    options: [.regularExpression, .caseInsensitive]
                ) == nil
        }
    }

    private func isPlausiblePerson(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              trimmed.count <= 40,
              trimmed.rangeOfCharacter(from: .letters) != nil,
              trimmed.split(separator: " ").count <= 4 else { return false }
        return trimmed.range(
            of: #"^(?:\d+|\d{1,2}:\d{2}|send message|see translation|your story)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) == nil
    }

    private func redditThreadTitle(in lines: [String]) -> String? {
        lines.first { line in
            let key = normalizedKey(line)
            let isChrome = line.range(
                of: #"^(?:r/|u/|join(?:ed)?$|\d+[,.]?\d*\s*(?:upvotes?|comments?)$|share$|save$|award$|report$|op$)"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            return !isChrome
                && !junk.contains(key)
                && line.rangeOfCharacter(from: .letters) != nil
                && line.split(separator: " ").count >= 2
        }
    }

    private func emailSubject(in lines: [String]) -> String? {
        if let explicit = lines.first(where: {
            $0.range(of: #"^subject:\s*\S"#, options: [.regularExpression, .caseInsensitive]) != nil
        }) {
            return explicit.replacingOccurrences(
                of: #"^subject:\s*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return lines.first { line in
            let key = normalizedKey(line)
            let isChrome = line.range(
                of: #"^(?:from:|to:|cc:|bcc:|reply$|reply all$|forward$|to me$|inbox$|all mail$|compose$|\d{1,2}:\d{2})"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            return !isChrome
                && !["sent from my iphone", "show trimmed content"].contains(key)
                && line.rangeOfCharacter(from: .letters) != nil
        }
    }

    private func boardingPassTitle(in lines: [String]) -> String? {
        if let route = lines.first(where: {
            $0.range(
                of: #"\b[A-Z]{3}\s*(?:→|TO|-)\s*[A-Z]{3}\b"#,
                options: .regularExpression
            ) != nil
        }) {
            return route
        }

        if let line = lines.first(where: {
            $0.range(
                of: #"\b(?:flight\s*)?[A-Z]{2}\s?\d{2,4}\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }), let range = line.range(
            of: #"\b(?:flight\s*)?[A-Z]{2}\s?\d{2,4}\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let value = String(line[range])
            return value.lowercased().hasPrefix("flight") ? value : "Flight \(value)"
        }
        return "Boarding pass"
    }
}
