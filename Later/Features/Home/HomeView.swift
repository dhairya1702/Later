import Photos
import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \LaterItem.createdAt, order: .reverse) private var items: [LaterItem]

    @State private var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var selectedItem: LaterItem?
    @ObservedObject var discoveryCoordinator: ScreenshotDiscoveryCoordinator

    var body: some View {
        NavigationStack {
            Group {
                if authorizationStatus == .notDetermined {
                    permissionPrompt
                } else if authorizationStatus == .denied || authorizationStatus == .restricted {
                    deniedState
                } else if items.isEmpty && discoveryCoordinator.isProcessing {
                    ProgressView("Recovering what you saved…")
                } else if items.isEmpty {
                    ContentUnavailableView(
                        "Nothing in Later yet",
                        systemImage: "sparkles.rectangle.stack",
                        description: Text("Take a screenshot, then come back. Later will quietly catch up.")
                    )
                } else {
                    laterLibrary
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if discoveryCoordinator.isProcessing { ProgressView() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        CategoriesView()
                    } label: {
                        Label("Categories", systemImage: "square.grid.2x2")
                    }

                    NavigationLink {
                        CompletedItemsView()
                    } label: {
                        Label("Completed", systemImage: "checkmark.circle")
                    }

                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Later")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Later")
                }
            }
            .navigationDestination(isPresented: detailIsPresented) {
                if let selectedItem {
                    LaterItemDetailView(item: selectedItem)
                }
            }
        }
        .task {
            await catchUp()
            await openPendingNotificationWhenActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: .laterOpenItem)) { _ in
            Task { await openPendingNotificationWhenActive() }
        }
        .onChange(of: scenePhase) { _, phase in
            discoveryCoordinator.setActive(phase == .active)
            if phase == .active {
                Task {
                    await catchUp()
                    await openPendingNotificationWhenActive()
                }
            }
        }
    }

    @ViewBuilder
    private var laterLibrary: some View {
        if laterItems.isEmpty {
            ContentUnavailableView(
                "You’re all caught up",
                systemImage: "checkmark.circle",
                description: Text("Your finished items are in Completed.")
            )
        } else {
            itemList
        }
    }

    private var itemList: some View {
        List {
            ForEach(laterItems) { item in
                HStack(spacing: 10) {
                    Button {
                        selectedItem = item
                    } label: {
                        LaterItemRow(item: item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation { toggleCompletion(item) }
                    } label: {
                        Image(systemName: "circle")
                            .font(.title2)
                            .foregroundStyle(Color.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mark as done")
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        toggleCompletion(item)
                    } label: {
                        Label("Complete", systemImage: "checkmark")
                    }
                    .tint(.green)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await catchUp() }
    }

    private var laterItems: [LaterItem] {
        items.filter { !$0.isCompleted && !$0.isDuplicateCopy }
    }

    private var detailIsPresented: Binding<Bool> {
        Binding(
            get: { selectedItem != nil },
            set: { isPresented in
                if !isPresented { selectedItem = nil }
            }
        )
    }

    private func toggleCompletion(_ item: LaterItem) {
        item.completedAt = item.isCompleted ? nil : .now
        item.statusRaw = item.isCompleted ? "completed" : "open"
        item.updatedAt = .now
        try? modelContext.save()
        Task { await NotificationManager.shared.reconcile() }
    }

    private func openPendingNotification() {
        guard let itemID = NotificationManager.shared.consumePendingOpenedItemID() else { return }
        let id = itemID
        var descriptor = FetchDescriptor<LaterItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        selectedItem = try? modelContext.fetch(descriptor).first
    }

    @MainActor
    private func openPendingNotificationWhenActive() async {
        guard scenePhase == .active else { return }
        await Task.yield()
        guard scenePhase == .active else { return }
        openPendingNotification()
    }

    private var permissionPrompt: some View {
        ContentUnavailableView {
            Text("You screenshot things for a reason.")
                .font(.system(.title3, design: .rounded, weight: .bold))
        } description: {
            Text("Later privately turns screenshots into things you want to watch, try, visit, buy, read, and do.")
        } actions: {
            Button("Find my screenshots") {
                Task {
                    authorizationStatus = await PhotoAuthorizationService().requestAccess()
                    await catchUp()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var deniedState: some View {
        ContentUnavailableView(
            "Photos access is off",
            systemImage: "photo.badge.exclamationmark",
            description: Text("Allow Photos access in Settings so Later can recover saved intentions.")
        )
    }

    @MainActor
    private func catchUp() async {
        await ShareInboxImporter(context: modelContext).importPending()
        authorizationStatus = PhotoAuthorizationService().status
        guard authorizationStatus == .authorized || authorizationStatus == .limited else { return }
        discoveryCoordinator.setActive(true)
        await discoveryCoordinator.discover(.foreground)
    }
}

private struct SettingsView: View {
    @AppStorage("appearancePreference") private var appearance = AppearancePreference.system

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("About") {
                LabeledContent("App", value: "Later")
                LabeledContent("Version", value: appVersion)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version ?? "1.0"
    }
}

private struct CategoriesView: View {
    @Query(sort: \LaterItem.createdAt, order: .reverse) private var items: [LaterItem]
    @State private var showCompleted = false

    private var visibleItems: [LaterItem] {
        let primaryItems = items.filter { !$0.isDuplicateCopy }
        return showCompleted ? primaryItems : primaryItems.filter { !$0.isCompleted }
    }

    private var categoryCounts: [(category: LaterCategory, count: Int)] {
        let grouped = Dictionary(grouping: visibleItems, by: \.category)
        return LaterCategory.allCases.compactMap { category in
            guard category != .other else { return nil }
            guard let count = grouped[category]?.count, count > 0 else { return nil }
            return (category, count)
        }
    }

    var body: some View {
        Group {
            if categoryCounts.isEmpty {
                ContentUnavailableView(
                    showCompleted ? "No saved items" : "No pending items",
                    systemImage: "square.grid.2x2",
                    description: Text(
                        showCompleted
                            ? "Your categories will appear here as Later organizes screenshots."
                            : "Turn on Show Completed to include finished items."
                    )
                )
            } else {
                List(categoryCounts, id: \.category) { summary in
                    NavigationLink {
                        CategoryItemsView(
                            category: summary.category,
                            showCompleted: showCompleted
                        )
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: summary.category.icon)
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 36, height: 36)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            Text(summary.category.displayName)
                                .font(.headline)
                            Spacer()
                            Text("\(summary.count)")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $showCompleted) {
                    Label("Show Completed", systemImage: "checkmark.circle")
                }
            }
        }
    }
}

private struct CategoryItemsView: View {
    let category: LaterCategory
    let showCompleted: Bool

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LaterItem.createdAt, order: .reverse) private var items: [LaterItem]
    @State private var selectedItem: LaterItem?

    private var categoryItems: [LaterItem] {
        items.filter {
            !$0.isDuplicateCopy && $0.category == category && (showCompleted || !$0.isCompleted)
        }
    }

    var body: some View {
        Group {
            if categoryItems.isEmpty {
                ContentUnavailableView(
                    "No pending \(category.displayName.lowercased()) items",
                    systemImage: category.icon
                )
            } else {
                List {
                    ForEach(categoryItems) { item in
                        HStack(spacing: 10) {
                            Button {
                                selectedItem = item
                            } label: {
                                LaterItemRow(item: item)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                withAnimation { toggleCompletion(item) }
                            } label: {
                                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(item.isCompleted ? Color.green : Color.secondary)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.isCompleted ? "Move back to Later" : "Mark as done")
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(category.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: detailIsPresented) {
            if let selectedItem {
                LaterItemDetailView(item: selectedItem)
            }
        }
    }

    private var detailIsPresented: Binding<Bool> {
        Binding(
            get: { selectedItem != nil },
            set: { isPresented in
                if !isPresented { selectedItem = nil }
            }
        )
    }

    private func toggleCompletion(_ item: LaterItem) {
        item.completedAt = item.isCompleted ? nil : .now
        item.statusRaw = item.isCompleted ? "completed" : "open"
        item.updatedAt = .now
        try? modelContext.save()
        Task { await NotificationManager.shared.reconcile() }
    }
}

private struct CompletedItemsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LaterItem.completedAt, order: .reverse) private var items: [LaterItem]
    @State private var selectedItem: LaterItem?

    private var completedItems: [LaterItem] {
        items.filter { $0.isCompleted && !$0.isDuplicateCopy }
    }

    var body: some View {
        Group {
            if completedItems.isEmpty {
                ContentUnavailableView(
                    "Nothing completed yet",
                    systemImage: "checkmark.circle",
                    description: Text("Finished items will appear here.")
                )
            } else {
                List {
                    ForEach(completedItems) { item in
                        HStack(spacing: 10) {
                            Button {
                                selectedItem = item
                            } label: {
                                LaterItemRow(item: item)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                withAnimation { moveBackToLater(item) }
                            } label: {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.green)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Move back to Later")
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                moveBackToLater(item)
                            } label: {
                                Label("Move to Later", systemImage: "arrow.uturn.backward")
                            }
                            .tint(.orange)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Completed")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: detailIsPresented) {
            if let selectedItem {
                LaterItemDetailView(item: selectedItem)
            }
        }
    }

    private var detailIsPresented: Binding<Bool> {
        Binding(
            get: { selectedItem != nil },
            set: { isPresented in
                if !isPresented { selectedItem = nil }
            }
        )
    }

    private func moveBackToLater(_ item: LaterItem) {
        item.completedAt = nil
        item.statusRaw = "open"
        item.updatedAt = .now
        try? modelContext.save()
        Task { await NotificationManager.shared.reconcile() }
    }
}

private struct LaterItemRow: View {
    @Bindable var item: LaterItem

    var body: some View {
        HStack(spacing: 12) {
            SourceThumbnail(
                identifier: item.photoLibraryAssetIdentifier,
                sharedImageFilename: item.sharedImageFilename
            )

            VStack(alignment: .leading, spacing: 4) {
                if item.kind != .other || item.isOffer == true {
                    HStack(spacing: 6) {
                        if item.kind != .other {
                            Label(item.kind.displayName.uppercased(), systemImage: item.kind.icon)
                        }
                        if item.isOffer == true && item.kind != .offer {
                            Label("OFFER", systemImage: "tag.fill")
                        }
                    }
                    .font(.caption2.bold())
                    .foregroundStyle(categoryColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(categoryColor.opacity(0.13))
                    .clipShape(Capsule())
                }
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                if let importantFacts {
                    Text(importantFacts)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let copyBadge {
                    Label(copyBadge, systemImage: "square.on.square")
                        .font(.caption2.bold())
                        .foregroundStyle(.purple)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var copyBadge: String? {
        guard let count = item.relatedCopyCount, count > 0 else { return nil }
        let label = item.duplicateMatchRaw == ScreenshotMatchKind.duplicate.rawValue
            ? (count == 1 ? "1 DUPLICATE" : "\(count) DUPLICATES")
            : (count == 1 ? "1 SIMILAR" : "\(count) SIMILAR")
        return label
    }

    private var categoryColor: Color {
        switch item.kind {
        case .concert, .music: .pink
        case .shopping: .purple
        case .food: .orange
        case .movie, .show: .indigo
        case .activity: .green
        case .task: .mint
        case .book, .article: .teal
        case .place, .event: .blue
        case .information: .brown
        case .offer: .red
        case .photo: .cyan
        case .style, .home, .recipe, .product: .purple
        case .document: .brown
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

    private var importantFacts: String? {
        var facts: [String] = []
        if let discount = item.discountText { facts.append(discount) }
        if let code = item.couponCode { facts.append("Code: \(code)") }

        if let role = item.meaningfulDateRole {
            let dateAndTime = [item.detectedDateText, item.detectedTimeText]
                .compactMap { $0 }
                .joined(separator: " at ")
            if !dateAndTime.isEmpty {
                let prefix = switch role {
                case .expiration: "Expires "
                case .deadline: "Due "
                case .delivery: "Arrives "
                case .reservation: "Reserved "
                case .travel: "Travel "
                case .event: "Event "
                case .unspecified: ""
                }
                facts.append(prefix + dateAndTime)
            }
        }
        if let location = item.detectedLocation { facts.append(location) }
        return facts.isEmpty ? nil : facts.prefix(3).joined(separator: " · ")
    }
}

private struct SourceThumbnail: View {
    let identifier: String?
    let sharedImageFilename: String?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: identifier) {
            if let sharedImageFilename {
                image = UIImage(contentsOfFile: ShareInboxStore()
                    .imageURL(filename: sharedImageFilename).path)
                return
            }
            guard let identifier,
                  let asset = PHAsset.fetchAssets(
                    withLocalIdentifiers: [identifier],
                    options: nil
                  ).firstObject else { return }
            image = try? await ImageLoader().image(
                for: asset,
                targetSize: CGSize(width: 156, height: 204),
                deliveryMode: .opportunistic
            )
        }
    }
}
