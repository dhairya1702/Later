import Photos
import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \LaterItem.createdAt, order: .reverse) private var items: [LaterItem]

    @State private var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var selectedItem: LaterItem?
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var pendingDeletion: [LaterItem] = []
    @State private var showingDeleteConfirmation = false
    @State private var actionError: String?
    @State private var showingCleanup = false
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
                    Button { showingCleanup = true } label: {
                        Image(systemName: "paintbrush.pointed.fill")
                    }
                    .accessibilityLabel("Cleanup")
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
            .navigationDestination(isPresented: $showingCleanup) {
                ScreenshotCleanupView()
            }
            .confirmationDialog(
                pendingDeletion.count == 1 ? "Delete this screenshot?" : "Delete \(pendingDeletion.count) screenshots?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                if !pendingDeletion.isEmpty {
                    Button(
                        pendingDeletion.contains(where: \.hasPhotoLibraryAsset)
                            ? "Delete from Later and Photos"
                            : "Delete from Later",
                        role: .destructive
                    ) {
                        let targets = pendingDeletion
                        Task { await deleteItems(targets) }
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingDeletion = []
                }
            } message: {
                Text(deleteConfirmationMessage)
            }
            .alert("Couldn’t complete action", isPresented: actionErrorIsPresented) {
                Button("OK") { actionError = nil }
            } message: {
                Text(actionError ?? "Please try again.")
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
                        withAnimation { toggleSelection(item) }
                    } label: {
                        Image(systemName: selectedItemIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(selectedItemIDs.contains(item.id) ? Color.accentColor : Color.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(selectedItemIDs.contains(item.id) ? "Deselect \(item.title)" : "Select \(item.title)")
                    .accessibilityAddTraits(selectedItemIDs.contains(item.id) ? .isSelected : [])
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if selectedItemIDs.isEmpty {
                        Button {
                            markDone(item)
                        } label: {
                            Label("Mark Done", systemImage: "checkmark")
                        }
                        .tint(.green)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if selectedItemIDs.isEmpty {
                        Button(role: .destructive) {
                            prepareToDelete([item])
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await catchUp() }
        .safeAreaInset(edge: .bottom) {
            if !selectedItemIDs.isEmpty {
                selectionActions
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: Set(laterItems.map(\.id))) { _, visibleItemIDs in
            selectedItemIDs.formIntersection(visibleItemIDs)
        }
    }

    private var selectionActions: some View {
        VStack(spacing: 10) {
            Text("\(selectedItemIDs.count) selected")
                .font(.subheadline.weight(.semibold))

            HStack(spacing: 12) {
                Button {
                    withAnimation { selectedItemIDs.removeAll() }
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)

                Button {
                    markSelectedDone()
                } label: {
                    Label("Mark Done", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button(role: .destructive) {
                    prepareToDelete(selectedItems)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private var laterItems: [LaterItem] {
        items.filter { !$0.isCompleted && !$0.isDuplicateCopy }
    }

    private var selectedItems: [LaterItem] {
        laterItems.filter { selectedItemIDs.contains($0.id) }
    }

    private var detailIsPresented: Binding<Bool> {
        Binding(
            get: { selectedItem != nil },
            set: { isPresented in
                if !isPresented { selectedItem = nil }
            }
        )
    }

    private func toggleSelection(_ item: LaterItem) {
        if !selectedItemIDs.insert(item.id).inserted {
            selectedItemIDs.remove(item.id)
        }
    }

    private func markDone(_ item: LaterItem) {
        markDone([item])
    }

    private func markSelectedDone() {
        markDone(selectedItems)
    }

    private func markDone(_ targets: [LaterItem]) {
        guard !targets.isEmpty else { return }
        let now = Date.now
        for item in targets {
            item.completedAt = now
            item.statusRaw = "completed"
            item.updatedAt = now
        }
        do {
            try modelContext.save()
            withAnimation { selectedItemIDs.subtract(targets.map(\.id)) }
            Task { await NotificationManager.shared.reconcile() }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func prepareToDelete(_ targets: [LaterItem]) {
        guard !targets.isEmpty else { return }
        pendingDeletion = targets
        showingDeleteConfirmation = true
    }

    @MainActor
    private func deleteItems(_ targets: [LaterItem]) async {
        do {
            try await ItemDeletionService(context: modelContext).delete(targets)
            withAnimation { selectedItemIDs.subtract(targets.map(\.id)) }
            pendingDeletion = []
        } catch {
            actionError = error.localizedDescription
        }
    }

    private var deleteConfirmationMessage: String {
        guard !pendingDeletion.isEmpty else { return "" }
        if pendingDeletion.contains(where: \.hasPhotoLibraryAsset) {
            return pendingDeletion.count == 1
                ? "This removes the save from Later and deletes the original from Photos. iOS will ask you to confirm. The original is recoverable in Photos → Recently Deleted."
                : "This removes the selected saves from Later and deletes their linked originals from Photos. iOS will ask you to confirm. The originals are recoverable in Photos → Recently Deleted."
        }
        return pendingDeletion.count == 1
            ? "This removes the saved image and its details from Later. No original in Photos is linked to this save."
            : "This removes the selected images and their details from Later. No originals in Photos are linked to these saves."
    }

    private var actionErrorIsPresented: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )
    }

    private func openPendingNotification() {
        if NotificationManager.shared.consumePendingCleanup() {
            showingCleanup = true
            return
        }
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
            Button {
                Task {
                    authorizationStatus = await PhotoAuthorizationService().requestAccess()
                    await catchUp()
                }
            } label: {
                Text("Find my screenshots")
                    .foregroundStyle(colorScheme == .dark
                        ? Color(red: 0.02, green: 0.12, blue: 0.18)
                        : .white)
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

private struct ScreenshotCleanupView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LaterItem.createdAt) private var items: [LaterItem]
    @State private var deletionTarget: LaterItem?
    @State private var errorMessage: String?

    private var candidates: [LaterItem] {
        items.filter { ItemRelevancePolicy().cleanupReason(for: $0) != nil }
    }

    var body: some View {
        List {
            if candidates.isEmpty {
                Text("Nothing needs cleanup right now.")
            }
            ForEach(candidates) { item in
                VStack(alignment: .leading, spacing: 12) {
                    NavigationLink { LaterItemDetailView(item: item) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            SourceThumbnail(
                                identifier: item.photoLibraryAssetIdentifier,
                                sharedImageFilename: item.sharedImageFilename
                            )
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.title).font(.headline).lineLimit(2)
                                if let reason = ItemRelevancePolicy().cleanupReason(for: item) {
                                    Label(reason.displayName, systemImage: cleanupIcon(reason))
                                        .font(.caption2)
                                        .foregroundStyle(tagColor(reason))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(tagColor(reason).opacity(0.13), in: Capsule())
                                }
                                Text(item.createdAt, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    HStack(spacing: 8) {
                        Button {
                            item.keepFromCleanup = true
                            save()
                        } label: {
                            Text("Keep").frame(maxWidth: .infinity)
                        }
                        .tint(.blue)
                        Button {
                            markAsDone(item)
                            save()
                        } label: {
                            Text("Mark as done").frame(maxWidth: .infinity)
                        }
                        .tint(.green)
                        Button(role: .destructive) { deletionTarget = item } label: {
                            Text("Delete").frame(maxWidth: .infinity)
                        }
                        .tint(.red)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.caption.weight(.semibold))
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Cleanup")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this screenshot?", isPresented: Binding(
            get: { deletionTarget != nil },
            set: { if !$0 { deletionTarget = nil } }
        ), titleVisibility: .visible) {
            if let target = deletionTarget {
                Button(target.hasPhotoLibraryAsset ? "Delete from Later and Photos" : "Delete from Later", role: .destructive) {
                    Task { await deleteScreenshot(target) }
                }
            }
        } message: {
            Text(deletionTarget?.hasPhotoLibraryAsset == true
                ? "This removes the save from Later and deletes the original from Photos. iOS will ask you to confirm. The original is recoverable in Photos → Recently Deleted."
                : "This removes the saved image and its details from Later. No original in Photos is linked to this save.")
        }
        .alert("Couldn’t finish cleanup", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func tagColor(_ reason: ItemCleanupReason) -> Color {
        switch reason {
        case .likelyAccidental: .gray
        case .expired: .red
        case .datePassed: .orange
        case .old: .blue
        }
    }

    private func cleanupIcon(_ reason: ItemCleanupReason) -> String {
        switch reason {
        case .likelyAccidental: "exclamationmark.triangle.fill"
        case .expired: "clock.badge.exclamationmark"
        case .datePassed: "calendar.badge.exclamationmark"
        case .old: "clock.arrow.circlepath"
        }
    }

    private func markAsDone(_ item: LaterItem) {
        item.completedAt = .now
        item.statusRaw = "completed"
        item.updatedAt = .now
    }

    private func save() {
        do {
            try context.save()
            Task { await NotificationManager.shared.reconcile() }
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func deleteScreenshot(_ item: LaterItem) async {
        do {
            try await ItemDeletionService(context: context).delete([item])
        } catch { errorMessage = error.localizedDescription }
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

            Section("Privacy & Support") {
                NavigationLink("Privacy") {
                    PrivacyView()
                }
                NavigationLink("Support") {
                    SupportView()
                }
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

private struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Text("Later is built to organize screenshots without building a profile about you. There are no accounts, ads, or cross-app tracking.")
            }

            Section("On your device") {
                Text("Later reads only the photos you allow. Apple Vision performs text recognition on your device. Screenshot records, extracted details, completion state, and preferences are stored locally on your device and in Later’s private app-group container.")
            }

            Section("Screenshot analysis") {
                Text("To understand a screenshot, Later sends a resized image over encrypted HTTPS to Later’s analysis service, which uses Google Vertex AI. The image is processed in memory to return structured details. Later’s backend does not save the image, recognized text, title, or analysis result, and does not include that content in operational logs.")
            }

            Section("Security and delivery") {
                Text("Later uses Apple App Attest and a random installation identifier to prevent abuse and enforce service limits. Security records may include an App Attest public key, assertion and rate-limit counters, and timestamps. If you share an image to Later, an APNs device token and item identifier may be used to deliver the completion notification.")
            }

            Section("Your choices") {
                Text("You can change Photos and notification access in iOS Settings. Deleting an item removes Later’s local copy and details. If it is linked to Photos, you can also ask iOS to delete the original; Photos keeps it in Recently Deleted according to your Photos settings.")
            }

            if let privacyURL = LaterExternalLinks.privacy {
                Section {
                    Link("View Privacy Policy Online", destination: privacyURL)
                }
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SupportView: View {
    var body: some View {
        List {
            Section("Photos") {
                Text("If screenshots are missing, open iOS Settings → Apps → Later → Photos and allow the screenshots you want Later to use. Return to Later and pull down on the home list to refresh.")
            }

            Section("Sharing") {
                Text("In a share sheet, choose Later and wait for the confirmation that the image was queued. Analysis continues in the background and can retry the next time you open Later.")
            }

            Section("Notifications") {
                Text("Open iOS Settings → Notifications → Later to change notification access. Later avoids discovery reminders for completed, expired, duplicate, date-passed, and likely accidental items.")
            }

            Section("Data") {
                Text("Later has no account or cloud library to delete. Delete individual items in Later, and use iOS Settings to revoke access or delete the app and its local data.")
            }

            Section("Diagnostic information") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: buildNumber)
            }

            Section("Contact") {
                if let supportURL = LaterExternalLinks.support {
                    Link("Visit Support Website", destination: supportURL)
                }
                Link("Email Support", destination: URL(string: "mailto:dhairya.lalwani@icloud.com?subject=Later%20Support")!)
            }
        }
        .navigationTitle("Support")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }
}

private enum LaterExternalLinks {
    static let privacy = url(for: "LaterPrivacyURL")
    static let support = url(for: "LaterSupportURL")

    private static func url(for key: String) -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        return URL(string: value)
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
                            .accessibilityLabel(item.isCompleted ? "Mark as not done" : "Mark as done")
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
                            .accessibilityLabel("Mark as not done")
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                moveBackToLater(item)
                            } label: {
                                Label("Mark as not done", systemImage: "circle")
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
                HStack(spacing: 6) {
                    if item.sourceApp == .linkedin {
                        Label("LINKEDIN", systemImage: "briefcase.fill")
                    } else {
                        Label(item.kind.displayName.uppercased(), systemImage: item.kind.icon)
                    }
                    if item.sourceApp != .linkedin, item.isOffer == true && item.kind != .offer {
                        Label("OFFER", systemImage: "tag.fill")
                    }
                }
                .font(.caption2.bold())
                .foregroundStyle(categoryColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(categoryColor.opacity(0.13))
                .clipShape(Capsule())
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
        case .job: .blue
        case .book, .article: .teal
        case .place, .event: .blue
        case .information: .brown
        case .offer: .red
        case .photo: .cyan
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
