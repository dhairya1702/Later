import Contacts
import ContactsUI
import EventKit
import EventKitUI
import Photos
import SwiftData
import SwiftUI
import UIKit

struct LaterItemDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query(sort: \LaterItem.createdAt, order: .reverse) private var allItems: [LaterItem]
    @Bindable var item: LaterItem
    @State private var image: UIImage?
    @State private var copiedCode = false
    @State private var copiedActionValue: String?
    @State private var pendingDeletion: [LaterItem] = []
    @State private var showingDeleteConfirmation = false
    @State private var deletionError: String?
    @State private var showingFullScreenshot = false
    @State private var showingReminderChoices = false
    @State private var showingCustomReminder = false
    @State private var customReminderDate = Date.now.addingTimeInterval(60 * 60)
    @State private var actionError: String?
    @State private var calendarEvent: EKEvent?
    @State private var showingCalendarEditor = false
    @State private var contactDraft: CNMutableContact?
    @State private var showingContactEditor = false
    @State private var eventStore = EKEventStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if !contextualActions.isEmpty {
                    contextualActionButtons
                }

                if let media = item.detectedMedia {
                    mediaActionButtons(for: media)
                }

                if hasImportantDetails {
                    detailSection
                }

                screenshotPreview

                if !relatedScreenshots.isEmpty {
                    relatedScreenshotsSection
                }

                Button {
                    toggleCompletion()
                } label: {
                    Label(
                        item.isCompleted ? "Move back to Later" : item.category.completedStatusLabel,
                        systemImage: item.isCompleted ? "arrow.uturn.backward.circle" : "checkmark.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(item.isCompleted ? .orange : .green)
            }
            .padding()
        }
        .navigationTitle(item.kind == .other ? "Screenshot" : item.kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: item.screenshotAssetIdentifier) { await loadImage() }
        .confirmationDialog(
            pendingDeletion.count == 1 ? "Delete this screenshot?" : "Delete extra screenshots?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                pendingDeletion.count == 1 ? "Delete from Photos" : "Delete \(pendingDeletion.count) from Photos",
                role: .destructive
            ) {
                let targets = pendingDeletion
                Task { await deleteScreenshots(targets) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("iOS will ask you to confirm. Deleted screenshots remain recoverable in Photos → Recently Deleted.")
        }
        .alert("Couldn’t delete screenshots", isPresented: deletionErrorIsPresented) {
            Button("OK") { deletionError = nil }
        } message: {
            Text(deletionError ?? "Please try again.")
        }
        .fullScreenCover(isPresented: $showingFullScreenshot) {
            if let image {
                FullScreenScreenshotView(image: image)
            }
        }
        .confirmationDialog("Remind me", isPresented: $showingReminderChoices) {
            Button("Tonight") { Task { await saveReminder(at: reminderDate(.tonight)) } }
            Button("Tomorrow") { Task { await saveReminder(at: reminderDate(.tomorrow)) } }
            Button("This Weekend") { Task { await saveReminder(at: reminderDate(.weekend)) } }
            Button("Choose Date & Time…") {
                customReminderDate = max(Date.now.addingTimeInterval(60 * 15), item.detectedDate ?? .now)
                showingCustomReminder = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingCustomReminder) {
            NavigationStack {
                Form {
                    DatePicker(
                        "Remind me",
                        selection: $customReminderDate,
                        in: Date.now...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
                .navigationTitle("Custom Reminder")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingCustomReminder = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            let date = customReminderDate
                            showingCustomReminder = false
                            Task { await saveReminder(at: date) }
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingCalendarEditor, onDismiss: { calendarEvent = nil }) {
            if let calendarEvent {
                CalendarEventEditor(event: calendarEvent, eventStore: eventStore)
            }
        }
        .sheet(isPresented: $showingContactEditor, onDismiss: { contactDraft = nil }) {
            if let contactDraft {
                NewContactEditor(contact: contactDraft)
            }
        }
        .alert("Couldn’t complete action", isPresented: actionErrorIsPresented) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "Please try again.")
        }
    }

    private var screenshotPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Screenshot")
                .font(.headline)

            Button {
                guard image != nil else { return }
                showingFullScreenshot = true
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    Color(.secondarySystemBackground)
                    if let image {
                        GeometryReader { proxy in
                            ZStack {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: proxy.size.width, height: proxy.size.height)
                                    .blur(radius: 18)
                                    .opacity(0.28)

                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: proxy.size.width, height: proxy.size.height)
                            }
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                        }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                            Text("Loading screenshot…").font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }

                    if image != nil {
                        Label("View", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(10)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View full screenshot")
            .disabled(image == nil)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Label(item.kind.displayName.uppercased(), systemImage: item.kind.icon)
                if item.isOffer == true && item.kind != .offer {
                    Label("OFFER", systemImage: "tag.fill")
                }
            }
            .font(.caption.bold())
            .foregroundStyle(categoryColor)

            Text(item.title)
                .font(.system(.title, design: .rounded, weight: .bold))

            Text("Saved \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Details")
                .font(.headline)

            if item.productDetails != nil {
                ForEach(productDetailRows) { row in
                    DetailFact(icon: row.icon, label: row.label, value: row.value)
                }
            } else {
                if let discount = item.discountText {
                    DetailFact(icon: "tag.fill", label: "Offer", value: discount)
                }
                if let code = item.couponCode {
                    Button {
                        UIPasteboard.general.string = code
                        copiedCode = true
                    } label: {
                        DetailFact(
                            icon: copiedCode ? "checkmark.circle.fill" : "doc.on.doc.fill",
                            label: copiedCode ? "Copied" : "Coupon code",
                            value: code
                        )
                    }
                    .buttonStyle(.plain)
                }
                if let dateValue {
                    DetailFact(icon: "calendar", label: dateLabel, value: dateValue)
                }
                if let location = item.detectedLocation {
                    DetailFact(icon: "mappin.circle.fill", label: "Location", value: location)
                }
                if let price = formattedPrice {
                    DetailFact(icon: "banknote.fill", label: "Price", value: price)
                }
            }
        }
        .padding(18)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
    }

    private var contextualActionButtons: some View {
        ActionGrid {
            ForEach(contextualActions) { action in
                let isCopied = copiedActionValue == action.value && action.kind == .copyCode
                Button {
                    perform(action)
                } label: {
                    // The colour belongs to the action, never to the screenshot's
                    // category. A Message button stays blue whether the screenshot
                    // was classified as Food or Shopping.
                    ActionCircle(fill: action.kind.tint) {
                        Image(systemName: isCopied ? "checkmark" : action.kind.icon)
                            .font(.system(size: ActionMetrics.glyphSize, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCopied ? "Copied" : action.kind.label)
            }
        }
    }

    private var contextualActions: [ContextualItemAction] {
        var actions: [ContextualItemAction] = [
            ContextualItemAction(kind: .reminder, value: item.id.uuidString)
        ]
        let entities = item.actionableEntities

        if let phone = entities.first(where: { $0.type == .phone }) {
            actions.append(ContextualItemAction(kind: .message, value: phone.value))
            actions.append(ContextualItemAction(kind: .call, value: phone.value))
        }
        if let email = entities.first(where: { $0.type == .email }) {
            actions.append(ContextualItemAction(kind: .email, value: email.value))
        }
        if entities.contains(where: { $0.type == .phone || $0.type == .email }) {
            actions.append(ContextualItemAction(kind: .contact, value: item.id.uuidString))
        }
        if let url = entities.first(where: { $0.type == .url }) {
            actions.append(ContextualItemAction(kind: .openLink, value: url.value))
        }
        if let address = entities.first(where: { $0.type == .address }) {
            actions.append(ContextualItemAction(kind: .maps, value: address.value))
        }
        if let code = entities.first(where: { $0.type == .couponCode }) {
            actions.append(ContextualItemAction(kind: .copyCode, value: code.value))
        }
        if canAddToCalendar {
            actions.append(ContextualItemAction(kind: .calendar, value: item.id.uuidString))
        }
        return actions
    }

    private func mediaActionButtons(for media: DetectedMedia) -> some View {
        ActionGrid {
            ForEach(mediaDestinations(for: media), id: \.self) { destination in
                Button {
                    openMediaSearch(destination, media: media)
                } label: {
                    MediaDestinationMark(destination: destination)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mediaAccessibilityLabel(destination, media: media))
                .accessibilityHint("Opens search results; it does not start playback")
            }
        }
    }

    private func mediaDestinations(for media: DetectedMedia) -> [MediaDestination] {
        var destinations: [MediaDestination] = media.type == .song
            ? [.appleMusic, .spotify, .youtube]
            : [.spotify, .youtube]
        let preferred: MediaDestination? = switch media.sourceService {
        case .appleMusic: .appleMusic
        case .spotify: .spotify
        case .youtube: .youtube
        case .other, .unknown:
            switch item.sourceApp {
            case .appleMusic: .appleMusic
            case .spotify: .spotify
            case .youtube: .youtube
            default: nil
            }
        }
        if let preferred, let index = destinations.firstIndex(of: preferred) {
            destinations.remove(at: index)
            destinations.insert(preferred, at: 0)
        }
        return destinations
    }

    private func openMediaSearch(_ destination: MediaDestination, media: DetectedMedia) {
        let query = "\(media.title) \(media.creator)"
        guard let links = destination.searchLinks(query: query) else {
            actionError = "Couldn’t create a media search link."
            return
        }

        if let appURL = links.app {
            UIApplication.shared.open(appURL, options: [:]) { accepted in
                guard !accepted else { return }
                DispatchQueue.main.async { openURL(links.web) }
            }
        } else {
            openURL(links.web)
        }
    }

    private func mediaAccessibilityLabel(
        _ destination: MediaDestination,
        media: DetectedMedia
    ) -> String {
        "Search \(destination.accessibilityName) for \(media.title) by \(media.creator)"
    }

    private func perform(_ action: ContextualItemAction) {
        switch action.kind {
        case .message:
            if let url = URL(string: "sms:\(action.value)") { openURL(url) }
        case .call:
            if let url = URL(string: "tel:\(action.value)") { openURL(url) }
        case .email:
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = action.value
            if let url = components.url { openURL(url) }
        case .openLink:
            if let url = URL(string: action.value) { openURL(url) }
        case .maps:
            var components = URLComponents(string: "https://maps.apple.com/")
            components?.queryItems = [URLQueryItem(name: "q", value: action.value)]
            if let url = components?.url { openURL(url) }
        case .copyCode:
            UIPasteboard.general.string = action.value
            copiedActionValue = action.value
        case .reminder:
            showingReminderChoices = true
        case .calendar:
            Task { await prepareCalendarEvent() }
        case .contact:
            prepareContact()
        }
    }

    private var canAddToCalendar: Bool {
        guard item.detectedDate != nil, let role = item.meaningfulDateRole else { return false }
        return [.event, .reservation, .travel].contains(role)
    }

    private enum ReminderChoice { case tonight, tomorrow, weekend }

    private func reminderDate(_ choice: ReminderChoice, now: Date = .now) -> Date {
        let calendar = Calendar.current
        switch choice {
        case .tonight:
            let tonight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now) ?? now
            return tonight > now ? tonight : now.addingTimeInterval(60 * 60)
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        case .weekend:
            return calendar.nextDate(
                after: now,
                matching: DateComponents(hour: 10, minute: 0, weekday: 7),
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(3 * 86_400)
        }
    }

    @MainActor
    private func saveReminder(at date: Date) async {
        do {
            let granted = try await eventStore.requestFullAccessToReminders()
            guard granted else {
                actionError = "Reminder access is off. You can enable it in Settings."
                return
            }
            let reminder = EKReminder(eventStore: eventStore)
            reminder.title = item.title
            reminder.notes = reminderNotes
            reminder.calendar = eventStore.defaultCalendarForNewReminders()
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: date
            )
            try eventStore.save(reminder, commit: true)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private var reminderNotes: String {
        [item.subtitle, dateValue, item.detectedLocation]
            .compactMap { value in
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return value
            }
            .joined(separator: "\n")
    }

    @MainActor
    private func prepareCalendarEvent() async {
        guard let startDate = item.detectedDate, canAddToCalendar else { return }
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            guard granted else {
                actionError = "Calendar access is off. You can enable it in Settings."
                return
            }
            let event = EKEvent(eventStore: eventStore)
            event.title = item.title
            event.startDate = startDate
            event.isAllDay = item.detectedTimeText?.isEmpty != false
            event.endDate = event.isAllDay
                ? Calendar.current.date(byAdding: .day, value: 1, to: startDate)
                : startDate.addingTimeInterval(60 * 60)
            event.location = item.detectedLocation
            event.notes = [item.subtitle, item.discountText].compactMap { $0 }.joined(separator: "\n")
            event.url = firstDetectedURL
            event.calendar = eventStore.defaultCalendarForNewEvents
            calendarEvent = event
            showingCalendarEditor = true
        } catch {
            actionError = error.localizedDescription
        }
    }

    private var firstDetectedURL: URL? {
        let rawValue = item.actionableEntities.first(where: { $0.type == .url })?.value ?? item.detectedURL
        return rawValue.flatMap(URL.init(string:))
    }

    private func prepareContact() {
        let entities = item.actionableEntities
        let phones = entities.filter { $0.type == .phone }
        let emails = entities.filter { $0.type == .email }
        guard !phones.isEmpty || !emails.isEmpty else { return }
        let contact = CNMutableContact()
        contact.phoneNumbers = phones.map {
            CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: $0.value))
        }
        contact.emailAddresses = emails.map {
            CNLabeledValue(label: CNLabelWork, value: $0.value as NSString)
        }
        contactDraft = contact
        showingContactEditor = true
    }

    private var relatedScreenshots: [LaterItem] {
        guard let groupID = item.duplicateGroupID else { return [] }
        return allItems.filter { $0.id != item.id && $0.duplicateGroupID == groupID }
    }

    private var relatedScreenshotsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Related screenshots")
                        .font(.headline)
                    Text("Later only groups very close matches. Review them before deleting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ForEach(relatedScreenshots) { relatedItem in
                RelatedScreenshotRow(item: relatedItem) {
                    pendingDeletion = [relatedItem]
                    showingDeleteConfirmation = true
                }
            }

            if relatedScreenshots.count > 1 {
                Button(role: .destructive) {
                    pendingDeletion = relatedScreenshots
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete all extra copies", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private var hasImportantDetails: Bool {
        !productDetailRows.isEmpty || item.discountText != nil || item.couponCode != nil || dateValue != nil ||
            item.detectedLocation != nil || formattedPrice != nil
    }

    private var productDetailRows: [ProductDetailRow] {
        guard let product = item.productDetails else { return [] }
        var rows: [ProductDetailRow] = []
        if !product.name.localizedCaseInsensitiveContains(item.title),
           !item.title.localizedCaseInsensitiveContains(product.name) {
            rows.append(ProductDetailRow(icon: "shippingbox.fill", label: "Product", value: product.name))
        }
        if let brand = product.brand { rows.append(ProductDetailRow(icon: "building.2.fill", label: "Brand", value: brand)) }
        let modelVariant = [product.model, product.variant].compactMap { $0 }.joined(separator: " · ")
        if !modelVariant.isEmpty { rows.append(ProductDetailRow(icon: "tag.fill", label: "Model / variant", value: modelVariant)) }
        if let price = product.currentPrice { rows.append(ProductDetailRow(icon: "banknote.fill", label: "Price", value: price)) }
        if let original = product.originalPrice { rows.append(ProductDetailRow(icon: "arrow.uturn.backward", label: "Original price", value: original)) }
        if let discount = product.discount { rows.append(ProductDetailRow(icon: "percent", label: "Discount", value: discount)) }
        if let condition = product.condition { rows.append(ProductDetailRow(icon: "checkmark.seal.fill", label: "Condition", value: condition)) }
        if let negotiable = product.negotiable { rows.append(ProductDetailRow(icon: "arrow.left.arrow.right", label: "Negotiable", value: negotiable)) }
        if let seller = product.seller { rows.append(ProductDetailRow(icon: "person.crop.circle.fill", label: "Seller", value: seller)) }
        let rating = [product.rating, product.reviewCount.map { "\($0) reviews" }].compactMap { $0 }.joined(separator: " · ")
        if !rating.isEmpty { rows.append(ProductDetailRow(icon: "star.fill", label: "Rating", value: rating)) }
        if let delivery = product.delivery { rows.append(ProductDetailRow(icon: "truck.box.fill", label: "Delivery", value: delivery)) }
        if let availability = product.availability { rows.append(ProductDetailRow(icon: "shippingbox.and.arrow.backward.fill", label: "Availability", value: availability)) }
        if let fulfillment = product.fulfillment { rows.append(ProductDetailRow(icon: "storefront.fill", label: "Fulfillment", value: fulfillment)) }
        if let location = product.location { rows.append(ProductDetailRow(icon: "mappin.circle.fill", label: "Location", value: location)) }
        return Array(rows.prefix(7))
    }

    private var dateValue: String? {
        guard item.meaningfulDateRole != nil else { return nil }
        let parts = [item.detectedDateText, item.detectedTimeText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " at ")
    }

    private var dateLabel: String {
        switch item.importantDateRole {
        case .expiration: "Expires"
        case .deadline: "Due"
        case .reservation: "Reservation"
        case .delivery: "Arrives"
        case .travel: "Travel date"
        case .event: "Event date"
        default: "Date and time"
        }
    }

    private var formattedPrice: String? {
        guard let price = item.detectedPrice else { return nil }
        if let currency = item.detectedCurrency {
            return price.formatted(.currency(code: currency))
        }
        return price.formatted()
    }

    private var categoryColor: Color {
        switch item.kind {
        case .concert, .music: .pink
        case .shopping, .style, .home, .recipe, .product: .purple
        case .food: .orange
        case .movie, .show: .indigo
        case .activity: .green
        case .task: .mint
        case .book, .article: .teal
        case .place, .event: .blue
        case .information, .document: .brown
        case .offer: .red
        case .photo: .cyan
        case .meme: .yellow
        case .chat, .story, .comments, .email: .green
        case .boardingPass: .blue
        case .app: .indigo
        case .map: .blue
        case .socialPost: .orange
        case .lockScreen: .gray
        case .other: .gray
        }
    }

    @MainActor
    private func loadImage() async {
        if let filename = item.sharedImageFilename {
            image = UIImage(contentsOfFile: ShareInboxStore().imageURL(filename: filename).path)
            return
        }
        guard let identifier = item.photoLibraryAssetIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return
        }
        let maxDimension: CGFloat = 1800
        let scale = min(maxDimension / CGFloat(max(asset.pixelWidth, asset.pixelHeight)), 1)
        image = try? await ImageLoader().image(
            for: asset,
            targetSize: CGSize(
                width: CGFloat(asset.pixelWidth) * scale,
                height: CGFloat(asset.pixelHeight) * scale
            )
        )
    }

    private func toggleCompletion() {
        item.completedAt = item.isCompleted ? nil : .now
        item.statusRaw = item.isCompleted ? "completed" : "open"
        item.updatedAt = .now
        try? modelContext.save()
    }

    private var deletionErrorIsPresented: Binding<Bool> {
        Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )
    }

    private var actionErrorIsPresented: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )
    }

    @MainActor
    private func deleteScreenshots(_ targets: [LaterItem]) async {
        let identifiers = targets.compactMap(\.photoLibraryAssetIdentifier)
        guard !identifiers.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }

            let deletedIDs = Set(targets.map(\.id))
            for target in targets { modelContext.delete(target) }

            let records = try modelContext.fetch(FetchDescriptor<ScreenshotRecord>())
            for record in records where identifiers.contains(record.assetIdentifier) {
                modelContext.delete(record)
            }

            let remaining = relatedScreenshots.filter { !deletedIDs.contains($0.id) }
            item.relatedCopyCount = remaining.count
            if remaining.isEmpty {
                item.duplicateGroupID = nil
                item.duplicateMatchRaw = nil
            } else {
                item.duplicateMatchRaw = remaining.contains {
                    $0.duplicateMatchRaw == ScreenshotMatchKind.duplicate.rawValue
                } ? ScreenshotMatchKind.duplicate.rawValue : ScreenshotMatchKind.similar.rawValue
            }
            try modelContext.save()
            pendingDeletion = []
        } catch {
            deletionError = error.localizedDescription
        }
    }
}

private enum MediaDestination: Hashable {
    case appleMusic
    case spotify
    case youtube

    var accessibilityName: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .youtube: "YouTube"
        }
    }

    func searchLinks(query: String) -> (app: URL?, web: URL)? {
        switch self {
        case .appleMusic:
            var components = URLComponents(string: "https://music.apple.com/us/search")
            components?.queryItems = [URLQueryItem(name: "term", value: query)]
            guard let web = components?.url else { return nil }
            return (nil, web)
        case .spotify:
            let allowed = CharacterSet.alphanumerics
            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed),
                  let app = URL(string: "spotify:search:\(encoded)"),
                  let web = URL(string: "https://open.spotify.com/search/\(encoded)") else { return nil }
            return (app, web)
        case .youtube:
            var components = URLComponents(string: "https://www.youtube.com/results")
            components?.queryItems = [URLQueryItem(name: "search_query", value: query)]
            guard let web = components?.url else { return nil }
            return (nil, web)
        }
    }
}

/// Music destinations keep their official brand colour, but share the exact circle
/// size and treatment used by every other action.
private struct MediaDestinationMark: View {
    let destination: MediaDestination

    var body: some View {
        switch destination {
        case .appleMusic:
            ActionCircle(
                fill: LinearGradient(
                    colors: [Color(red: 0.98, green: 0.16, blue: 0.35), Color(red: 0.98, green: 0.31, blue: 0.56)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            ) {
                Image(systemName: "music.note")
                    .font(.system(size: ActionMetrics.glyphSize + 2, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .spotify:
            ActionCircle(fill: Color(red: 0.11, green: 0.73, blue: 0.33)) {
                SpotifyWaveMark()
                    .stroke(.black, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .frame(width: 28, height: 22)
            }
        case .youtube:
            ActionCircle(fill: Color(red: 1, green: 0, blue: 0)) {
                Image(systemName: "play.fill")
                    .font(.system(size: ActionMetrics.glyphSize - 2, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: 1)
            }
        }
    }
}

/// One circle, one size, one shape for every action in the app.
private enum ActionMetrics {
    static let diameter: CGFloat = 52
    static let glyphSize: CGFloat = 20
}

private struct ActionCircle<Fill: ShapeStyle, Glyph: View>: View {
    let fill: Fill
    @ViewBuilder let glyph: Glyph

    var body: some View {
        ZStack {
            Circle().fill(fill)
            glyph
        }
        .frame(width: ActionMetrics.diameter, height: ActionMetrics.diameter)
        .contentShape(Circle())
    }
}

private struct ActionGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 52, maximum: 56), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            content
        }
    }
}

private struct SpotifyWaveMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let lines: [(CGFloat, CGFloat, CGFloat)] = [
            (0.18, 0.82, 0.20),
            (0.40, 0.75, 0.14),
            (0.61, 0.67, 0.09)
        ]
        for (height, endY, inset) in lines {
            path.move(to: CGPoint(x: rect.width * inset, y: rect.height * height))
            path.addQuadCurve(
                to: CGPoint(x: rect.width * (1 - inset), y: rect.height * endY),
                control: CGPoint(x: rect.midX, y: rect.height * (height - 0.10))
            )
        }
        return path
    }
}

private struct FullScreenScreenshotView: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            ZoomableImage(image: image)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
            .accessibilityLabel("Close screenshot")
        }
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .black

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }
    }
}

private struct CalendarEventEditor: UIViewControllerRepresentable {
    let event: EKEvent
    let eventStore: EKEventStore

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        controller.eventStore = eventStore
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        func eventEditViewController(
            _ controller: EKEventEditViewController,
            didCompleteWith action: EKEventEditViewAction
        ) {
            controller.dismiss(animated: true)
        }
    }
}

private struct NewContactEditor: UIViewControllerRepresentable {
    let contact: CNMutableContact

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = CNContactViewController(forNewContact: contact)
        controller.contactStore = CNContactStore()
        controller.delegate = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        func contactViewController(
            _ viewController: CNContactViewController,
            didCompleteWith contact: CNContact?
        ) {
            viewController.dismiss(animated: true)
        }
    }
}

private struct RelatedScreenshotRow: View {
    @Bindable var item: LaterItem
    let deleteAction: () -> Void
    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Color(.secondarySystemBackground)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .frame(width: 62, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 5) {
                Label(matchKind.displayName, systemImage: "square.on.square")
                    .font(.caption.bold())
                    .foregroundStyle(matchKind == .duplicate ? Color.purple : Color.orange)
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                Text(matchKind == .duplicate ? "Very close visual match" : "Possible variation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: deleteAction) {
                Image(systemName: "trash")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete related screenshot")
        }
        .task(id: item.screenshotAssetIdentifier) { await loadImage() }
    }

    private var matchKind: ScreenshotMatchKind {
        ScreenshotMatchKind(rawValue: item.duplicateMatchRaw ?? "") ?? .similar
    }

    @MainActor
    private func loadImage() async {
        guard let identifier = item.photoLibraryAssetIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return
        }
        image = try? await ImageLoader().image(
            for: asset,
            targetSize: CGSize(width: 186, height: 264),
            deliveryMode: .opportunistic
        )
    }
}

private struct ProductDetailRow: Identifiable {
    let icon: String
    let label: String
    let value: String

    var id: String { "\(label):\(value)" }
}

private struct ContextualItemAction: Identifiable {
    enum Kind: String {
        case message
        case call
        case email
        case openLink
        case maps
        case copyCode
        case reminder
        case calendar
        case contact

        var label: String {
            switch self {
            case .message: "Message"
            case .call: "Call"
            case .email: "Email"
            case .openLink: "Open Link"
            case .maps: "Maps"
            case .copyCode: "Copy Code"
            case .reminder: "Remind Me"
            case .calendar: "Calendar"
            case .contact: "Add Contact"
            }
        }

        var icon: String {
            switch self {
            case .message: "message.fill"
            case .call: "phone.fill"
            case .email: "envelope.fill"
            case .openLink: "safari.fill"
            case .maps: "map.fill"
            case .copyCode: "doc.on.doc.fill"
            case .reminder: "bell.fill"
            case .calendar: "calendar.badge.plus"
            case .contact: "person.crop.circle.badge.plus"
            }
        }

        /// Action identity is stable. These colours describe what the button does,
        /// so the same action looks the same on every screenshot in the app.
        var tint: Color {
            switch self {
            case .reminder: .orange
            case .message: .blue
            case .call: .green
            case .email: .indigo
            case .contact: .teal
            case .calendar: .red
            case .maps: Color(red: 0.94, green: 0.38, blue: 0.18)
            case .openLink: .blue
            case .copyCode: .purple
            }
        }
    }

    let kind: Kind
    let value: String
    var id: String { "\(kind.rawValue):\(value)" }
}

private struct DetailFact: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
