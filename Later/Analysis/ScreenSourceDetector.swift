import Foundation

struct ScreenSourceDetector {
    func detect(text: String, blocks: [OCRBlock] = []) -> ScreenDetection {
        let normalized = text.lowercased()
        let lines = normalized.components(separatedBy: .newlines)
        var candidates: [(ScreenshotSurface, ScreenshotSourceApp, Double, [String])] = []

        candidates.append(lockScreenCandidate(text: normalized, blocks: blocks))
        candidates.append(appStoreCandidate(text: normalized, lines: lines))
        candidates.append(mapCandidate(text: normalized))
        candidates.append(emailCandidate(text: normalized))
        candidates.append(boardingPassCandidate(text: normalized))

        let chat = chatCandidate(text: normalized, blocks: blocks)
        candidates.append(chat)
        candidates.append(storyCandidate(text: normalized, blocks: blocks))

        let redditScore = score(
            text: normalized,
            signals: [
                (#"(?m)\br/[a-z0-9_]+"#, 4, "subreddit name"),
                (#"(?m)\bu/[a-z0-9_-]+"#, 3, "Reddit username"),
                (#"\b(?:upvote|downvote|karma|awards?)\b"#, 3, "Reddit controls"),
                (#"\bop\b"#, 1, "original-poster label"),
                (#"\b(?:join|joined)\b"#, 1, "community membership")
            ]
        )
        let comments = commentsCandidate(text: normalized)
        if comments.2 >= 6 {
            let source = redditScore.0 >= 5 ? ScreenshotSourceApp.reddit : comments.1
            let evidence = redditScore.0 >= 5 ? comments.3 + redditScore.1 : comments.3
            candidates.append((.comments, source, comments.2 + min(2, redditScore.0 / 3), evidence))
        }
        if redditScore.0 >= 5 {
            candidates.append((.redditPost, .reddit, redditScore.0, redditScore.1))
        }

        guard let winner = candidates
            .filter({ $0.2 >= threshold(for: $0.0) })
            .max(by: { $0.2 < $1.2 }) else { return .unknown }

        let confidence = min(0.99, 0.55 + winner.2 * 0.045)
        return ScreenDetection(
            surface: winner.0,
            sourceApp: winner.1,
            confidence: confidence,
            evidence: Array(winner.3.prefix(8))
        )
    }

    private func lockScreenCandidate(
        text: String,
        blocks: [OCRBlock]
    ) -> (ScreenshotSurface, ScreenshotSourceApp, Double, [String]) {
        var value = 0.0
        var evidence: [String] = []
        add(#"\b(?:swipe up|press home) to open\b"#, weight: 7, label: "unlock instruction", text: text, value: &value, evidence: &evidence)
        add(#"\b(?:do not disturb|personal|work|sleep) focus\b"#, weight: 3, label: "Focus status", text: text, value: &value, evidence: &evidence)

        let largeTopTime = blocks.contains { block in
            block.y > 0.55
                && block.height > 0.045
                && matches(block.text, pattern: #"^\s*(?:1[0-2]|0?[1-9]):[0-5]\d\s*$"#)
        }
        if largeTopTime {
            value += 4
            evidence.append("large upper-screen time")
        }
        if largeTopTime && matches(text, pattern: #"\b(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday),?\s+(?:january|february|march|april|may|june|july|august|september|october|november|december)\b"#) {
            value += 3
            evidence.append("lock-screen date beneath time")
        }
        return (.lockScreen, .unknown, value, evidence)
    }

    private func appStoreCandidate(
        text: String,
        lines: [String]
    ) -> (ScreenshotSurface, ScreenshotSourceApp, Double, [String]) {
        var result = score(
            text: text,
            signals: [
                (#"\bratings\s*&\s*reviews\b"#, 4, "Ratings & Reviews"),
                (#"\bwhat'?s new\b"#, 4, "What's New"),
                (#"\bversion history\b"#, 4, "Version History"),
                (#"\bapp privacy\b"#, 4, "App Privacy"),
                (#"\bin-app purchases?\b"#, 4, "In-App Purchases"),
                (#"\b(?:age|category|developer|languages?)\b"#, 1, "App Store metadata"),
                (#"\b(?:iphone|ipad) app\b"#, 2, "platform app label")
            ]
        )
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "get" || $0.trimmingCharacters(in: .whitespaces) == "open" }) {
            result.0 += 3
            result.1.append("GET/OPEN button")
        }
        return (.appStore, .appStore, result.0, result.1)
    }

    private func mapCandidate(text: String) -> (ScreenshotSurface, ScreenshotSourceApp, Double, [String]) {
        var result = score(
            text: text,
            signals: [
                (#"\bdirections\b"#, 3, "Directions control"),
                (#"\badd stop\b"#, 4, "Add Stop control"),
                (#"\blook around\b"#, 4, "Look Around control"),
                (#"\b(?:driving|walking|transit|cycling)\b"#, 2, "transport mode"),
                (#"\b\d+(?:\.\d+)?\s*(?:mi|miles?|km)\b"#, 2, "route distance"),
                (#"\b\d+\s*min(?:utes?)?\b"#, 2, "route duration"),
                (#"\b(?:avoid tolls|avoid highways|route options)\b"#, 4, "route options"),
                (#"\bsearch maps\b"#, 4, "map search field")
            ]
        )
        let source: ScreenshotSourceApp
        if text.contains("google maps") || text.contains("search google maps") {
            source = .googleMaps
            result.0 += 3
            result.1.append("Google Maps")
        } else {
            source = .appleMaps
        }
        return (.map, source, result.0, result.1)
    }

    private func chatCandidate(
        text: String,
        blocks: [OCRBlock]
    ) -> (ScreenshotSurface, ScreenshotSourceApp, Double, [String]) {
        var generic = score(
            text: text,
            signals: [
                (#"\bdelivered\b"#, 2, "Delivered status"),
                (#"\bread\s+(?:at\s+)?\d{1,2}:?\d{0,2}\s*(?:am|pm)?\b"#, 2, "Read receipt"),
                (#"\btype a message\b"#, 4, "message input"),
                (#"\b(?:today|yesterday)\s+\d{1,2}:\d{2}\b"#, 2, "conversation timestamp"),
                (#"\b(?:video|audio) call\b"#, 2, "call control")
            ]
        )

        let shortBlocks = blocks.filter { $0.text.count >= 2 && $0.text.count <= 120 }
        let left = shortBlocks.filter { $0.x < 0.18 }.count
        let right = shortBlocks.filter { $0.x > 0.42 }.count
        if left >= 2 && right >= 2 {
            generic.0 += 4
            generic.1.append("alternating message layout")
        }

        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hasTime = lines.contains {
            matches($0, pattern: #"^(?:(?:today|yesterday)\s+)?\d{1,2}:\d{2}(?:\s*[ap]m)?$"#)
                || matches($0, pattern: #"^\d+\s*(?:s|m|h|d|w)$"#)
        }
        let chrome = Set([
            "message", "messages", "imessage", "facetime", "online", "delivered",
            "read", "reply", "send", "send a chat", "type a message"
        ])
        let hasPerson = lines.contains {
            !chrome.contains($0)
                && matches($0, pattern: #"^@?[a-z][a-z0-9._'-]*(?:\s+[a-z][a-z0-9._'-]*){0,3}$"#)
        }
        let hasMessageBody = lines.contains {
            $0.count >= 4
                && $0.split(separator: " ").count >= 2
                && !matches($0, pattern: #"^(?:(?:today|yesterday)\s+)?\d{1,2}:\d{2}(?:\s*[ap]m)?$"#)
        }
        if lines.count >= 3 && hasTime && hasPerson && hasMessageBody {
            generic.0 += 6
            generic.1.append("name, message, and time layout")
        }

        let imessage = score(text: text, signals: [
            (#"\bimessage\b"#, 6, "iMessage input"),
            (#"\btext message\b"#, 4, "Text Message input"),
            (#"\bnotify anyway\b"#, 5, "Notify Anyway"),
            (#"\bfacetime\b"#, 3, "FaceTime control")
        ])
        let whatsapp = score(text: text, signals: [
            (#"\bwhatsapp\b"#, 6, "WhatsApp"),
            (#"\blast seen\b"#, 5, "last seen status"),
            (#"\bend-to-end encrypted\b"#, 5, "encryption notice"),
            (#"\bonline\b"#, 1, "online status")
        ])
        let snapchat = score(text: text, signals: [
            (#"\bnew snap\b"#, 6, "New Snap"),
            (#"\bsend a chat\b"#, 6, "Send a Chat"),
            (#"\btap to load\b"#, 5, "Tap to load"),
            (#"\b(?:opened|received)\b"#, 2, "Snap status")
        ])

        let sources: [(ScreenshotSourceApp, (Double, [String]))] = [
            (.iMessage, imessage), (.whatsapp, whatsapp), (.snapchat, snapchat)
        ]
        let sourceWinner = sources.max(by: { $0.1.0 < $1.1.0 })
        if let sourceWinner, sourceWinner.1.0 > 0 {
            generic.0 += sourceWinner.1.0
            generic.1.append(contentsOf: sourceWinner.1.1)
            return (.chat, sourceWinner.0, generic.0, generic.1)
        }
        return (.chat, .unknown, generic.0, generic.1)
    }

    private func emailCandidate(text: String) -> (ScreenshotSurface, ScreenshotSourceApp, Double, [String]) {
        var result = score(text: text, signals: [
            (#"(?m)^\s*from:\s*\S+"#, 4, "From header"),
            (#"(?m)^\s*to:\s*\S+"#, 4, "To header"),
            (#"(?m)^\s*subject:\s*\S+"#, 4, "Subject header"),
            (#"\bto me\b"#, 4, "recipient summary"),
            (#"\bsent from my iphone\b"#, 4, "Mail signature"),
            (#"\b(?:reply all|forward)\b"#, 3, "mail actions"),
            (#"\b(?:inbox|all mail|compose)\b"#, 2, "mail navigation"),
            (#"\bshow trimmed content\b"#, 4, "mail thread control")
        ])

        let source: ScreenshotSourceApp
        if text.contains("gmail") || text.contains("to me") || text.contains("show trimmed content") {
            source = .gmail
        } else if text.contains("outlook") || text.contains("focused inbox") {
            source = .outlook
            result.0 += 3
            result.1.append("Outlook chrome")
        } else {
            source = .appleMail
        }
        return (.email, source, result.0, result.1)
    }

    private func boardingPassCandidate(text: String) -> (ScreenshotSurface, ScreenshotSourceApp, Double, [String]) {
        let result = score(text: text, signals: [
            (#"\bboarding pass\b"#, 8, "Boarding Pass label"),
            (#"\bboarding time\b"#, 4, "boarding time"),
            (#"\bpassenger\b"#, 3, "passenger field"),
            (#"\bflight\s*(?:no\.?|number|#)?\s*[a-z]{0,3}\s*\d{2,4}\b"#, 4, "flight number"),
            (#"\bgate\s*[a-z0-9-]+\b"#, 3, "gate field"),
            (#"\bseat\s*\d{1,3}[a-z]?\b"#, 3, "seat field"),
            (#"\b(?:group|zone)\s*[a-z0-9-]+\b"#, 2, "boarding group"),
            (#"\b(?:departure|arrival|destination)\b"#, 2, "flight routing"),
            (#"\b(?:record locator|confirmation code)\b"#, 3, "reservation code")
        ])
        return (.boardingPass, .unknown, result.0, result.1)
    }

    private func commentsCandidate(text: String) -> (ScreenshotSurface, ScreenshotSourceApp, Double, [String]) {
        var result = score(text: text, signals: [
            (#"\badd a comment\b"#, 5, "comment input"),
            (#"\bview (?:all )?\d*\s*repl(?:y|ies)\b"#, 4, "View replies"),
            (#"\bhide repl(?:y|ies)\b"#, 3, "Hide replies"),
            (#"\btop comments\b"#, 3, "Top comments")
        ])
        let replyCount = matchCount(text, pattern: #"\breply\b"#)
        if replyCount >= 2 {
            result.0 += min(4, Double(replyCount))
            result.1.append("repeated Reply controls")
        }
        let relativeTimeCount = matchCount(text, pattern: #"\b\d+\s*(?:m|h|d|w|mo|y)\b"#)
        if relativeTimeCount >= 3 {
            result.0 += 3
            result.1.append("repeated relative timestamps")
        }

        let source: ScreenshotSourceApp
        if text.contains("instagram") { source = .instagram }
        else if text.contains("youtube") { source = .youtube }
        else if text.contains("tiktok") { source = .tiktok }
        else { source = .unknown }
        return (.comments, source, result.0, result.1)
    }

    private func storyCandidate(
        text: String,
        blocks: [OCRBlock]
    ) -> (ScreenshotSurface, ScreenshotSourceApp, Double, [String]) {
        var value = 0.0
        var evidence: [String] = []
        let creatorAgePattern = #"^\s*@?[a-z0-9._][a-z0-9._ ]{1,38}?\s*[·•]?\s*\d+\s*(?:s|m|h|d|w)\s*$"#

        if matches(
            text,
            pattern: "(?m)" + creatorAgePattern
        ) {
            value += 5
            evidence.append("creator and story age")
        }

        if blocks.contains(where: {
            $0.y > 0.68 && matches($0.text.lowercased(), pattern: creatorAgePattern)
        }) {
            value += 5
            evidence.append("upper-screen story header")
        }

        let timeBlocks = blocks.filter {
            $0.y > 0.68
                && matches($0.text.lowercased(), pattern: #"^\s*\d+\s*(?:s|m|h|d|w)\s*$"#)
        }
        let hasUpperCreatorAndAge = timeBlocks.contains { timeBlock in
            blocks.contains { creatorBlock in
                creatorBlock.x < timeBlock.x
                    && abs(creatorBlock.y - timeBlock.y) < 0.055
                    && matches(
                        creatorBlock.text.lowercased(),
                        pattern: #"^\s*@?[a-z0-9._][a-z0-9._ ]{1,38}\s*$"#
                    )
            }
        }
        if hasUpperCreatorAndAge {
            value += 7
            evidence.append("upper-screen creator and story age")
        }

        let isSnapchat = matches(text, pattern: #"\bsend a chat\b"#)
        let isInstagram = matches(text, pattern: #"\bsend message\b"#)
            || matches(text, pattern: #"\bsee translation\b"#)
            || matches(text, pattern: #"\byour story\b"#)

        if isSnapchat {
            value += 8
            evidence.append("Snapchat Send a Chat control")
        }
        if isInstagram {
            value += 5
            evidence.append("Instagram story controls")
        }

        let source: ScreenshotSourceApp = isSnapchat ? .snapchat : .instagram
        return (.story, source, value, evidence)
    }

    private func threshold(for surface: ScreenshotSurface) -> Double {
        switch surface {
        case .lockScreen: 6
        case .story: 9
        case .email: 6
        case .boardingPass: 7
        case .appStore: 6
        case .map: 5
        case .chat: 5
        case .redditPost: 5
        case .comments: 6
        case .unknown: .infinity
        }
    }

    private func score(
        text: String,
        signals: [(String, Double, String)]
    ) -> (Double, [String]) {
        var value = 0.0
        var evidence: [String] = []
        for (pattern, weight, label) in signals where matches(text, pattern: pattern) {
            value += weight
            evidence.append(label)
        }
        return (value, evidence)
    }

    private func add(
        _ pattern: String,
        weight: Double,
        label: String,
        text: String,
        value: inout Double,
        evidence: inout [String]
    ) {
        guard matches(text, pattern: pattern) else { return }
        value += weight
        evidence.append(label)
    }

    private func matches(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private func matchCount(_ text: String, pattern: String) -> Int {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(text.startIndex..., in: text)
        return expression.numberOfMatches(in: text, range: range)
    }
}
