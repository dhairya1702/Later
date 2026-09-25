import Photos
import SwiftUI

@MainActor
@Observable
private final class ScreenshotGridModel {
    var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var assets: [PHAsset] = []
    var isLoading = false

    private let authorization = PhotoAuthorizationService()
    private let fetcher = ScreenshotFetcher()

    var hasAccess: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    func requestAccess() async {
        authorizationStatus = await authorization.requestAccess()
        if hasAccess { loadScreenshots() }
    }

    func refreshAuthorizationAndLoad() {
        authorizationStatus = authorization.status
        if hasAccess { loadScreenshots() }
    }

    func loadScreenshots() {
        isLoading = true
        assets = fetcher.latest(limit: 50)
        isLoading = false
    }
}

struct ScreenshotGridView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = ScreenshotGridModel()

    private let columns = [
        GridItem(.adaptive(minimum: 105), spacing: 2)
    ]

    var body: some View {
        NavigationStack {
            Group {
                switch model.authorizationStatus {
                case .notDetermined:
                    permissionPrompt
                case .restricted, .denied:
                    deniedState
                case .authorized, .limited:
                    screenshotGrid
                @unknown default:
                    deniedState
                }
            }
            .navigationTitle("Screenshots")
            .toolbar {
                if model.hasAccess {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        model.loadScreenshots()
                    }
                }
            }
        }
        .task { model.refreshAuthorizationAndLoad() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshAuthorizationAndLoad() }
        }
    }

    private var permissionPrompt: some View {
        ContentUnavailableView {
            Label("Your screenshots already contain everything you meant to remember.", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Later privately finds them in Photos. Processing happens on your iPhone.")
        } actions: {
            Button("Find my screenshots") {
                Task { await model.requestAccess() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var deniedState: some View {
        ContentUnavailableView {
            Label("Photos access is off", systemImage: "photo.badge.exclamationmark")
        } description: {
            Text("Allow full access to find screenshots automatically. Limited access only includes the photos you select.")
        } actions: {
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: settingsURL)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var screenshotGrid: some View {
        if model.isLoading {
            ProgressView("Finding screenshots…")
        } else if model.assets.isEmpty {
            ContentUnavailableView(
                "No screenshots found",
                systemImage: "rectangle.stack.badge.questionmark",
                description: Text(model.authorizationStatus == .limited
                    ? "Only selected photos are available. Add screenshots in Photos settings or grant full access."
                    : "Take a screenshot, then refresh this screen.")
            )
        } else {
            ScrollView {
                if model.authorizationStatus == .limited {
                    Text("Limited access: Later can only process the screenshots you selected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }

                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(model.assets, id: \.localIdentifier) { asset in
                        NavigationLink(value: asset.localIdentifier) {
                            ScreenshotThumbnail(asset: asset)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationDestination(for: String.self) { identifier in
                if let asset = model.assets.first(where: { $0.localIdentifier == identifier }) {
                    ScreenshotDetailView(asset: asset)
                }
            }
        }
    }
}

private struct ScreenshotThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
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
        .aspectRatio(0.56, contentMode: .fit)
        .clipped()
        .task(id: asset.localIdentifier) {
            image = try? await ImageLoader().image(
                for: asset,
                targetSize: CGSize(width: 320, height: 560),
                deliveryMode: .opportunistic
            )
        }
    }
}
