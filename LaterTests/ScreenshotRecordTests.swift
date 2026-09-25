import Foundation
import SwiftData
import Testing
@testable import Later

@MainActor
struct ScreenshotRecordTests {
    @Test func processingStatusRoundTripsThroughRawValue() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ScreenshotRecord.self, configurations: configuration)
        let record = ScreenshotRecord(assetIdentifier: "fixture", screenshotDate: .now)
        container.mainContext.insert(record)

        record.processingStatus = .OCR

        #expect(record.processingStatusRaw == ProcessingStatus.OCR.rawValue)
        #expect(record.processingStatus == .OCR)
    }

    @Test func successfulScreenshotIdentifiersRequireAResultingItem() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ScreenshotRecord.self,
            LaterItem.self,
            configurations: configuration
        )
        let completed = ScreenshotRecord(assetIdentifier: "completed", screenshotDate: .now)
        completed.resultingItemID = UUID()
        let failed = ScreenshotRecord(assetIdentifier: "failed", screenshotDate: .now)
        failed.processingStatus = .failed
        container.mainContext.insert(completed)
        container.mainContext.insert(failed)
        try container.mainContext.save()

        let identifiers = try ScreenshotRepository(context: container.mainContext)
            .successfullyProcessedIdentifiers()

        #expect(identifiers == ["completed"])
    }

    @Test func staleClassificationsAreEligibleForMetadataRefresh() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ScreenshotRecord.self,
            LaterItem.self,
            configurations: configuration
        )
        let current = ScreenshotRecord(assetIdentifier: "current", screenshotDate: .now)
        current.resultingItemID = UUID()
        current.classifierVersion = ClassificationConfig.classifierVersion
        let stale = ScreenshotRecord(assetIdentifier: "stale", screenshotDate: .now)
        stale.resultingItemID = UUID()
        stale.classifierVersion = ClassificationConfig.classifierVersion - 1
        container.mainContext.insert(current)
        container.mainContext.insert(stale)
        try container.mainContext.save()

        let identifiers = try ScreenshotRepository(context: container.mainContext)
            .upToDateProcessedIdentifiers()

        #expect(identifiers == ["current"])
    }

    @Test func discoverySourcesUseExpectedBatchLimits() {
        #expect(ScreenshotDiscoverySource.initialScan.batchLimit == Int.max)
        #expect(ScreenshotDiscoverySource.foreground.batchLimit == 50)
        #expect(ScreenshotDiscoverySource.photoLibraryChange.batchLimit == 50)
        #expect(ScreenshotDiscoverySource.backgroundRefresh.batchLimit == 10)
        #expect(ScreenshotDiscoverySource.backgroundProcessing.batchLimit == 50)
    }

    @Test func doorDashCouponIsAPrimaryOffer() async {
        let result = await ScreenshotClassifier.shared.classify(
            text: "DoorDash: Get $15 off your next order. Promo code SAVE15. Expires October 15."
        )

        #expect(result.category == .offer)
        #expect(result.kind == .offer)
        #expect(result.facts?.discountTexts.contains("$15 off") == true)
        #expect(result.facts?.couponCodes.contains("SAVE15") == true)
        #expect(result.facts?.primaryDateRole == .expiration)
    }

    @Test func productSaleKeepsShoppingAsPrimaryAndOfferAsSecondary() async {
        let result = await ScreenshotClassifier.shared.classify(
            text: "Nike Air Max $129. 30% off. Add to cart. In stock."
        )

        #expect(result.category == .buy)
        #expect(result.kind == .shopping)
        #expect((result.offerConfidence ?? 0) >= 0.5)
    }

    @Test func ikeaDeskListingIsShoppingNotAShow() async {
        let result = await ScreenshotClassifier.shared.classify(
            text: "IKEA\nMICKE desk, white\n$99.99\nProduct details\nArticle number 802.130.74\nDelivery available"
        )

        #expect(result.category == .buy)
        #expect(result.kind == .shopping)
    }

    @Test func importantFactsUseOnlyTextualLocationEvidence() {
        let extractor = ImportantFactExtractor()
        let explicit = extractor.extract(
            from: "Venue: United Center\nOctober 15 at 7:30 PM",
            prices: []
        )
        let visualOnly = extractor.extract(
            from: "Beautiful landmark photo",
            prices: []
        )

        #expect(explicit.locations.contains("United Center"))
        #expect((explicit.dateTexts + explicit.timeTexts).contains { $0.contains("7:30 PM") })
        #expect(visualOnly.locations.isEmpty)
    }

    @Test func visualLabelsRouteTextlessImagesIntoUsefulTypes() {
        let router = VisualClassificationRouter()

        let style = router.route(labels: [
            VisualLabel(identifier: "clothing, apparel, shirt", confidence: 0.82)
        ])
        let home = router.route(labels: [
            VisualLabel(identifier: "living room, furniture", confidence: 0.76)
        ])
        let generic = router.route(labels: [
            VisualLabel(identifier: "dog", confidence: 0.91)
        ])
        let weakTextGuess = router.route(labels: [
            VisualLabel(identifier: "screenshot", confidence: 0.72),
            VisualLabel(identifier: "text, paper", confidence: 0.18)
        ])
        let actualDocument = router.route(labels: [
            VisualLabel(identifier: "document, receipt", confidence: 0.84)
        ])

        #expect(style.category == .inspire)
        #expect(style.kind == .style)
        #expect(home.kind == .home)
        #expect(generic.category == .photo)
        #expect(generic.kind == .photo)
        #expect(weakTextGuess.category == .photo)
        #expect(weakTextGuess.kind == .photo)
        #expect(actualDocument.kind == .document)
    }

    @Test func duplicateMatcherIsConservative() {
        let candidate = LaterItem(
            title: "IKEA desk",
            category: .buy,
            kind: .shopping,
            confidence: 0.9,
            createdAt: .now,
            screenshotAssetIdentifier: "candidate",
            rawOCRText: "IKEA MICKE desk white product details article number 123 delivery available",
            needsReview: false
        )
        candidate.imageContentHash = "same-content"
        candidate.perceptualHash = "0000000000000000"
        candidate.sourcePixelWidth = 1179
        candidate.sourcePixelHeight = 2556

        let matcher = DuplicateScreenshotMatcher()
        let exact = matcher.match(
            exactHash: "same-content",
            perceptualHash: "ffffffffffffffff",
            text: "different text does not matter for exact pixels",
            pixelWidth: 1179,
            pixelHeight: 2556,
            against: candidate
        )
        let similar = matcher.match(
            exactHash: "different-content",
            perceptualHash: "0000000000000003",
            text: "IKEA MICKE desk white product details article number 123 delivery available today",
            pixelWidth: 1179,
            pixelHeight: 2556,
            against: candidate
        )
        let unrelated = matcher.match(
            exactHash: "different-content",
            perceptualHash: "ffffffffffffffff",
            text: "Spotify now playing a completely unrelated song and artist",
            pixelWidth: 1179,
            pixelHeight: 2556,
            against: candidate
        )

        #expect(exact == .duplicate)
        #expect(similar == .similar || similar == .duplicate)
        #expect(unrelated == nil)
    }

    @Test func spotifyPlayerIsMusic() async {
        let spotify = await ScreenshotClassifier.shared.classify(
            text: "Spotify\nNow Playing\nNights\nFrank Ocean\nLyrics"
        )

        #expect(spotify.category == .listen)
        #expect(spotify.kind == .music)
    }

    @Test func iMessageChatWithIncidentalPromoLanguageIsNotAnOffer() async {
        let result = await ScreenshotClassifier.shared.classify(text: """
        Maya
        FaceTime
        Today 8:42 PM
        This promo code was funny lol
        Delivered
        iMessage
        """)

        #expect(result.screenDetection?.surface == .chat)
        #expect(result.screenDetection?.sourceApp == .iMessage)
        #expect(result.kind == .chat)
        #expect(result.category == .remember)
        #expect((result.offerConfidence ?? 0) <= 0.25)
    }

    @Test func whatsappAndSnapchatScreensAreRecognizedAsChats() async {
        let whatsapp = await ScreenshotClassifier.shared.classify(text: """
        Alex
        online
        Messages and calls are end-to-end encrypted
        Are we still meeting Friday?
        Message
        """)
        let snapchat = await ScreenshotClassifier.shared.classify(text: """
        Jordan
        New Snap
        Opened
        Tap to load
        Send a Chat
        """)

        #expect(whatsapp.screenDetection?.surface == .chat)
        #expect(whatsapp.screenDetection?.sourceApp == .whatsapp)
        #expect(whatsapp.kind == .chat)
        #expect(snapchat.screenDetection?.surface == .chat)
        #expect(snapchat.screenDetection?.sourceApp == .snapchat)
        #expect(snapchat.kind == .chat)
    }

    @Test func genericNameMessageAndTimeLayoutIsAChat() async {
        let text = "Maya\nCan you pick me up after work?\n10:42 PM"
        let result = await ScreenshotClassifier.shared.classify(text: text)
        let title = TitleExtractor().extract(
            from: text,
            category: result.category,
            screenDetection: result.screenDetection
        )

        #expect(result.screenDetection?.surface == .chat)
        #expect(result.kind == .chat)
        #expect(title == "Maya")
    }

    @Test func gmailMessageUsesEmailSurfaceAndSubjectTitle() async {
        let text = """
        Inbox
        Your flight schedule changed
        United Airlines
        to me
        Sep 22, 4:31 PM
        Your departure is now at 8:20 PM.
        Forward
        """
        let result = await ScreenshotClassifier.shared.classify(text: text)
        let title = TitleExtractor().extract(
            from: text,
            category: result.category,
            screenDetection: result.screenDetection
        )

        #expect(result.screenDetection?.surface == .email)
        #expect(result.screenDetection?.sourceApp == .gmail)
        #expect(result.kind == .email)
        #expect(title == "Your flight schedule changed")
    }

    @Test func boardingPassIsTravelAndUsesRouteAsTitle() async {
        let text = """
        BOARDING PASS
        UNITED
        ORD → SFO
        Passenger MAYA PATEL
        Flight UA 1847
        Boarding time 7:20 AM
        Gate B16
        Seat 12A
        Group 2
        """
        let result = await ScreenshotClassifier.shared.classify(text: text)
        let title = TitleExtractor().extract(
            from: text,
            category: result.category,
            screenDetection: result.screenDetection
        )

        #expect(result.screenDetection?.surface == .boardingPass)
        #expect(result.kind == .boardingPass)
        #expect(result.category == .go)
        #expect(title == "ORD → SFO")
    }

    @Test func redditPostUsesThreadHeadlineAsTitle() async {
        let text = """
        r/chicago
        u/lakeviewlocal
        Join
        What is the best late-night ramen spot?
        I have friends visiting this weekend.
        342 upvotes
        98 comments
        """
        let result = await ScreenshotClassifier.shared.classify(text: text)
        let title = TitleExtractor().extract(
            from: text,
            category: result.category,
            screenDetection: result.screenDetection
        )

        #expect(result.screenDetection?.surface == .redditPost)
        #expect(result.kind == .socialPost)
        #expect(title == "What is the best late-night ramen spot?")
    }

    @Test func instagramStoryUsesCreatorAsItsTitle() async {
        let text = """
        maya.travels · 36m
        Best view in Chicago tonight
        See translation
        Send message
        """
        let result = await ScreenshotClassifier.shared.classify(text: text)
        let title = TitleExtractor().extract(
            from: text,
            category: result.category,
            screenDetection: result.screenDetection
        )

        #expect(result.screenDetection?.surface == .story)
        #expect(result.screenDetection?.sourceApp == .instagram)
        #expect(result.kind == .story)
        #expect(title == "maya.travels")
    }

    @Test func instagramStoryHeaderGeometryWorksWithoutBottomControls() async {
        let text = "alex.photos 16h\nLake Michigan"
        let blocks = [
            OCRBlock(text: "alex.photos 16h", confidence: 0.98, x: 0.16, y: 0.88, width: 0.28, height: 0.03),
            OCRBlock(text: "Lake Michigan", confidence: 0.96, x: 0.25, y: 0.42, width: 0.5, height: 0.05)
        ]
        let result = await ScreenshotClassifier.shared.classify(
            text: text,
            ocrBlocks: blocks
        )

        #expect(result.screenDetection?.surface == .story)
        #expect(result.screenDetection?.sourceApp == .instagram)
        #expect(result.kind == .story)
    }

    @Test func snapchatStoryAndChatUseTheCreatorRatherThanContentAsTitle() async {
        let storyText = """
        Jordan · 16h
        You need to try this restaurant
        Send a Chat
        """
        let story = await ScreenshotClassifier.shared.classify(text: storyText)
        let storyTitle = TitleExtractor().extract(
            from: storyText,
            category: story.category,
            screenDetection: story.screenDetection
        )
        let chatText = "Jordan\nNew Snap\nOpened\nTap to load\nSend a Chat"
        let chat = await ScreenshotClassifier.shared.classify(text: chatText)
        let chatTitle = TitleExtractor().extract(
            from: chatText,
            category: chat.category,
            screenDetection: chat.screenDetection
        )

        #expect(story.screenDetection?.surface == .story)
        #expect(story.screenDetection?.sourceApp == .snapchat)
        #expect(story.kind == .story)
        #expect(storyTitle == "Jordan")
        #expect(chat.screenDetection?.surface == .chat)
        #expect(chat.screenDetection?.sourceApp == .snapchat)
        #expect(chatTitle == "Jordan")
    }

    @Test func appStoreListingOverridesActivityWords() async {
        let result = await ScreenshotClassifier.shared.classify(text: """
        Trail Activity
        GET
        4.8 Ratings
        What's New
        Version History
        Ratings & Reviews
        App Privacy
        Developer
        """)

        #expect(result.screenDetection?.surface == .appStore)
        #expect(result.screenDetection?.sourceApp == .appStore)
        #expect(result.kind == .app)
        #expect(result.category == .remember)
    }

    @Test func mapWithRestaurantLabelIsGoNotEat() async {
        let result = await ScreenshotClassifier.shared.classify(text: """
        Search Maps
        Ramen Wasabi Restaurant
        Directions
        Driving 18 min
        4.2 mi
        Add Stop
        """)

        #expect(result.screenDetection?.surface == .map)
        #expect(result.kind == .map)
        #expect(result.category == .go)
    }

    @Test func redditDiscussionWithIncidentalDiscountIsReadNotOffer() async {
        let result = await ScreenshotClassifier.shared.classify(text: """
        r/chicago
        u/example
        Join
        Best ramen places?
        Someone mentioned 20% off once
        342 upvotes
        98 comments
        """)

        #expect(result.screenDetection?.surface == .redditPost)
        #expect(result.screenDetection?.sourceApp == .reddit)
        #expect(result.kind == .socialPost)
        #expect(result.category == .read)
    }

    @Test func redditPostWithCompleteOfferEvidenceCanStillBeAnOffer() async {
        let result = await ScreenshotClassifier.shared.classify(text: """
        r/deals
        u/dealposter
        25% off
        Promo code SAVE25
        Offer expires Friday
        Redeem online
        """)

        #expect(result.screenDetection?.surface == .redditPost)
        #expect(result.kind == .socialPost)
        #expect(result.category == .offer)
        #expect(result.facts?.couponCodes.contains("SAVE25") == true)
    }

    @Test func genericCommentThreadIsRecognizedBeforeItsContent() async {
        let result = await ScreenshotClassifier.shared.classify(text: """
        Comments
        user_a 2h
        Great suggestion
        Reply
        View 3 replies
        user_b 1d
        I tried it
        Reply
        Add a comment
        """)

        #expect(result.screenDetection?.surface == .comments)
        #expect(result.kind == .comments)
        #expect(result.category == .remember)
    }

    @Test func lockScreenUsesOCRGeometryAndDoesNotBecomeAnIntent() async {
        let blocks = [
            OCRBlock(text: "9:41", confidence: 0.99, x: 0.38, y: 0.72, width: 0.24, height: 0.08),
            OCRBlock(text: "Tuesday, September 22", confidence: 0.98, x: 0.25, y: 0.65, width: 0.5, height: 0.03)
        ]
        let result = await ScreenshotClassifier.shared.classify(
            text: "9:41\nTuesday, September 22",
            ocrBlocks: blocks
        )

        #expect(result.screenDetection?.surface == .lockScreen)
        #expect(result.kind == .lockScreen)
        #expect(result.category == .other)
    }

    @Test func genericCodeLabelDoesNotCreateACoupon() {
        let facts = ImportantFactExtractor().extract(
            from: "Invite code ABCD shared by Maya",
            prices: []
        )

        #expect(facts.couponCodes.isEmpty)
    }

    @Test func weakSemanticOnlyShowDiscussionAbstains() async {
        let result = await ScreenshotClassifier.shared.classify(
            text: "YouTube comments\nI started watching this last night and the ending was incredible"
        )

        #expect(result.category == .other)
        #expect(result.kind == .other)
        #expect(result.needsReview)
    }

    @Test func normalizerCollapsesWhitespaceAndNormalizesCase() {
        let normalized = TextNormalizer().normalize("  SEVERANCE\t\n\n\nApple TV+  ")
        #expect(normalized == "severance \n\napple tv+")
    }

    @Test func priceExtractionRecognizesCommonCurrencies() {
        let features = FeatureExtractor().extract(
            from: "$20 $20.99 ₹5,000 £14 EUR 12.50"
        )
        #expect(features.detectedPrices.count == 5)
    }

    @Test func ruleAndSemanticClassifierHandlesObviousExamples() async {
        let examples: [(String, LaterCategory)] = [
            ("SEVERANCE Apple TV+ hit television series. Watch now.", .watch),
            ("Au Cheval restaurant menu reservations. Best cheeseburger in Chicago.", .eat),
            ("New Balance 990v6 $199.99 Add to cart. Size 11 in stock.", .buy),
            ("Concert tickets at the Chicago Symphony Center. Venue admission October 4.", .go),
            ("Application deadline Friday. Submit by 5 PM. Due tomorrow.", .doItem),
            ("A new book by this author. Read the first chapter on Goodreads.", .read)
        ]

        for (text, expected) in examples {
            let result = await ScreenshotClassifier.shared.classify(text: text)
            #expect(result.category == expected, "Expected \(expected) for: \(text)")
        }
    }

    @Test func concreteTypeClassifierSeparatesIntentFromContent() async {
        let examples: [(String, LaterCategory, LaterKind)] = [
            ("Ludovico Einaudi live concert tickets at the Symphony Center", .go, .concert),
            ("New Balance 990v6 $199 sponsored products buy now", .buy, .shopping),
            ("Au Cheval restaurant menu best cheeseburger", .eat, .food),
            ("Severance hit Apple TV series season 2", .watch, .show),
            ("Oppenheimer movie film trailer IMDb", .watch, .movie),
            ("Application deadline Friday submit by 5 PM", .doItem, .task)
        ]

        for (text, category, kind) in examples {
            let result = await ScreenshotClassifier.shared.classify(text: text)
            #expect(result.category == category)
            #expect(result.kind == kind)
        }
    }

    @Test func confidenceRouterRejectsSmallWinningMargin() {
        let result = ConfidenceRouter().route(scores: [
            CategoryClassificationScore(category: .watch, ruleScore: 0.8, semanticScore: 0.8, finalScore: 0.80),
            CategoryClassificationScore(category: .read, ruleScore: 0.78, semanticScore: 0.78, finalScore: 0.78)
        ])

        #expect(result.category == .other)
        #expect(result.kind == .other)
        #expect(result.needsReview)
        #expect(result.margin < ClassificationConfig.automaticMargin)
    }

    @Test func concertWithSeveralDatesKeepsOnlyTheConfidentType() async {
        let result = await ScreenshotClassifier.shared.classify(text: """
        Khruangbin concert tour dates
        October 4 — Chicago
        October 6 — Detroit
        October 9 — Toronto
        Tickets and venue information
        """)

        #expect(result.kind == .concert)
        #expect(result.category == .other)
        #expect(result.needsReview)
        #expect(result.facts?.dateTexts.count == 3)
        #expect(result.facts?.primaryDate == nil)
        #expect(result.facts?.primaryDateRole == nil)
    }

    @Test func titleExtractorRejectsBrowserChrome() {
        let restaurant = """
        Google
        AI Mode
        Images
        Au Cheval is an upscale diner-style bar and restaurant in Chicago.
        Essential Menu Items to Try
        Au Cheval
        """
        let show = """
        Google
        Short videos
        You can watch the sci-fi thriller series on Apple TV.
        What is Severance?
        Watch Severance - Show - Apple TV
        """
        let product = """
        Google
        Q New Balance 990v6 $199 buy
        Sponsored Products
        New Balance
        Men's 990v6
        $199.99
        New Ba
        """

        #expect(TitleExtractor().extract(from: restaurant, category: .eat) == "Au Cheval")
        #expect(TitleExtractor().extract(from: show, category: .watch) == "Severance")
        #expect(TitleExtractor().extract(from: product, category: .buy) == "New Balance 990v6")
    }

    @Test func notificationPlannerKeepsDailyBudgetAndDoesNotRepeatAnItemInADay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 22,
            hour: 7
        ))!
        let categories: [LaterCategory] = [.watch, .eat, .go, .buy, .read, .doItem]
        let items = (0..<20).map { index in
            let category = categories[index % categories.count]
            return LaterItem(
                title: "Saved item \(index)",
                category: category,
                kind: .fallback(for: category),
                confidence: 0.9,
                createdAt: now.addingTimeInterval(TimeInterval(-index * 60)),
                screenshotAssetIdentifier: "asset-\(index)",
                rawOCRText: "Saved item \(index)",
                needsReview: false
            )
        }

        let plans = NotificationPlanner(calendar: calendar).plans(
            for: items,
            now: now,
            horizonDays: 7
        )
        let plansByDay = Dictionary(grouping: plans) {
            calendar.startOfDay(for: $0.fireDate)
        }

        #expect(!plans.isEmpty)
        for dayPlans in plansByDay.values {
            #expect(dayPlans.count >= 3)
            #expect(dayPlans.count <= 5)
            let individualPlans = dayPlans.filter { !$0.isSummary }
            #expect(Set(individualPlans.map(\.itemID)).count == individualPlans.count)
            #expect(dayPlans.filter(\.isSummary).count == 1)
            #expect(dayPlans.first(where: \.isSummary).map {
                calendar.component(.hour, from: $0.fireDate)
            } == 20)
        }
    }

    @Test func notificationPlannerResurfacesUnclassifiedButSkipsCompletedSnoozedAndLockScreens() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let completed = LaterItem(
            title: "Completed",
            category: .doItem,
            kind: .task,
            confidence: 0.9,
            createdAt: now,
            screenshotAssetIdentifier: "completed-notification",
            rawOCRText: "Completed",
            needsReview: false
        )
        completed.completedAt = now
        let uncertain = LaterItem(
            title: "Uncertain",
            category: .other,
            kind: .other,
            confidence: 0.2,
            createdAt: now,
            screenshotAssetIdentifier: "uncertain-notification",
            rawOCRText: "Uncertain",
            needsReview: true
        )
        let snoozed = LaterItem(
            title: "Snoozed",
            category: .read,
            kind: .article,
            confidence: 0.9,
            createdAt: now,
            screenshotAssetIdentifier: "snoozed-notification",
            rawOCRText: "Snoozed",
            needsReview: false
        )
        snoozed.snoozedUntil = now.addingTimeInterval(8 * 86_400)
        let lockScreen = LaterItem(
            title: "9:41",
            category: .other,
            kind: .lockScreen,
            confidence: 0.9,
            createdAt: now,
            screenshotAssetIdentifier: "lock-screen-notification",
            rawOCRText: "9:41 Tuesday, September 22",
            needsReview: false
        )
        lockScreen.screenSurface = .lockScreen

        let plans = NotificationPlanner().plans(
            for: [completed, uncertain, snoozed, lockScreen],
            now: now,
            horizonDays: 7
        )

        #expect(!plans.isEmpty)
        #expect(plans.allSatisfy { $0.itemID == uncertain.id })
        #expect(plans.allSatisfy { $0.title == "You might want to check this out" })
    }

    @Test func notificationComposerUsesNeutralCopyForUnclassifiedScreenshots() {
        let item = LaterItem(
            title: "Possibly misleading OCR title",
            category: .other,
            kind: .other,
            confidence: 0.25,
            createdAt: .now,
            screenshotAssetIdentifier: "unclassified-copy",
            rawOCRText: "Assorted text",
            needsReview: true
        )

        let copy = IntentNotificationComposer().compose(for: item)

        #expect(copy.title == "You might want to check this out")
        #expect(copy.body == "You saved this screenshot recently.")
    }

    @Test func notificationComposerRecoversConcreteTaskLanguage() {
        let item = LaterItem(
            title: "Trip planning",
            category: .doItem,
            kind: .task,
            confidence: 0.92,
            createdAt: .now,
            screenshotAssetIdentifier: "task-copy",
            rawOCRText: "Reminders\nDon't forget to text Maya about the flights.\nToday",
            needsReview: false
        )

        let copy = IntentNotificationComposer().compose(for: item)

        #expect(copy.title == "Text Maya about the flights")
        #expect(!copy.title.localizedCaseInsensitiveContains("screenshot"))
        #expect(!copy.body.localizedCaseInsensitiveContains("classified"))
    }

    @Test func notificationComposerLeadsWithOfferAndExpiration() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 22,
            hour: 12
        ))!
        let item = LaterItem(
            title: "Nike Air Max",
            category: .offer,
            kind: .offer,
            confidence: 0.95,
            createdAt: now,
            screenshotAssetIdentifier: "offer-copy",
            rawOCRText: "Nike Air Max 25% off. Offer expires tomorrow.",
            needsReview: false
        )
        item.discountText = "25% off"
        item.detectedDate = calendar.date(byAdding: .day, value: 1, to: now)
        item.detectedDateText = "tomorrow"
        item.importantDateRole = .expiration

        let copy = IntentNotificationComposer(calendar: calendar).compose(
            for: item,
            referenceDate: now
        )

        #expect(copy.title == "25% off: Nike Air Max")
        #expect(copy.body == "Expires tomorrow")
    }

    @Test func notificationComposerUsesEventFactsWithoutOperationalLanguage() {
        let item = LaterItem(
            title: "Khruangbin",
            category: .go,
            kind: .concert,
            confidence: 0.94,
            createdAt: .now,
            screenshotAssetIdentifier: "concert-copy",
            rawOCRText: "Khruangbin October 15 at 8 PM. The Salt Shed.",
            needsReview: false
        )
        item.detectedDateText = "October 15"
        item.detectedTimeText = "8 PM"
        item.detectedLocation = "The Salt Shed"
        item.importantDateRole = .event

        let copy = IntentNotificationComposer().compose(for: item)

        #expect(copy.title == "Khruangbin")
        #expect(copy.body == "October 15 at 8 PM · The Salt Shed")
        #expect(!copy.body.localizedCaseInsensitiveContains("organized"))
    }
}
