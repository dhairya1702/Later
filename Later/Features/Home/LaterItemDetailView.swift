import Photos
import SwiftData
import SwiftUI
import UIKit

struct LaterItemDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LaterItem.createdAt, order: .reverse) private var allItems: [LaterItem]
    @Bindable var item: LaterItem
    @State private var image: UIImage?
    @State private var copiedCode = false
    @State private var pendingDeletion: [LaterItem] = []
    @State private var showingDeleteConfirmation = false
    @State private var deletionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                screenshot
                header

                if hasImportantDetails {
                    detailSection
                }

                contextSection

                if !relatedScreenshots.isEmpty {
                    relatedScreenshotsSection
                }

                if !item.rawOCRText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DisclosureGroup("Text found in screenshot") {
                        Text(item.rawOCRText)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 10)
                    }
                    .padding(18)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
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
    }

    private var screenshot: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                    Text("Loading screenshot…").font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(height: 280)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22))
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
            Text("Important details")
                .font(.headline)

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
        .padding(18)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About this save")
                .font(.headline)
            if item.category != .other {
                DetailFact(icon: item.category.icon, label: "Category", value: item.category.displayName)
            }
            if item.kind != .other {
                DetailFact(icon: item.kind.icon, label: "Type", value: item.kind.displayName)
            }

            if let labels = item.visualLabelsText, !labels.isEmpty {
                DetailFact(
                    icon: "eye.fill",
                    label: "What’s pictured",
                    value: labels
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).capitalized }
                        .prefix(4)
                        .joined(separator: ", ")
                )
            }
        }
        .padding(18)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
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
        item.discountText != nil || item.couponCode != nil || dateValue != nil ||
            item.detectedLocation != nil || formattedPrice != nil
    }

    private var dateValue: String? {
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
        guard let identifier = item.screenshotAssetIdentifier,
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

    @MainActor
    private func deleteScreenshots(_ targets: [LaterItem]) async {
        let identifiers = targets.compactMap(\.screenshotAssetIdentifier)
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
        guard let identifier = item.screenshotAssetIdentifier,
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
