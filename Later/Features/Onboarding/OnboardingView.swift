import Photos
import SwiftData
import SwiftUI

struct OnboardingView: View {
    private enum Step {
        case introduction
        case permission
        case scanning
        case complete
    }

    @ObservedObject var discoveryCoordinator: ScreenshotDiscoveryCoordinator
    let onFinish: () -> Void

    @AppStorage(OnboardingState.introductionKey) private var hasSeenIntroduction = false
    @AppStorage(OnboardingState.requestedPhotosKey) private var hasRequestedPhotos = false
    @AppStorage(OnboardingState.initialScanKey) private var hasCompletedInitialScan = false
    @Query private var items: [LaterItem]

    @State private var step: Step = .introduction
    @State private var page = 0
    @State private var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var scanStarted = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.13), .clear, Color.accentColor.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            switch step {
            case .introduction:
                introduction
            case .permission:
                permission
            case .scanning:
                InitialScanView(coordinator: discoveryCoordinator) {
                    finishOnboarding()
                }
            case .complete:
                completion
            }
        }
        .animation(.easeInOut(duration: 0.28), value: step)
        .task { restoreStep() }
    }

    private var introduction: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Later")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            TabView(selection: $page) {
                OnboardingPageView(
                    symbol: "rectangle.stack.fill",
                    title: "Your screenshots, finally useful.",
                    message: "Later turns things you save into offers, events, places, products, ideas, and more.",
                    illustration: .cards
                )
                .tag(0)

                OnboardingPageView(
                    symbol: "sparkles.rectangle.stack",
                    title: "The important parts, already pulled out.",
                    message: "Dates, times, prices, coupon codes, and locations written in the screenshot stay easy to find.",
                    illustration: .facts
                )
                .tag(1)

                OnboardingPageView(
                    symbol: "lock.shield.fill",
                    title: "Private by design.",
                    message: "Everything is processed on this device. Screenshots are not uploaded, and Later never uses GPS location.",
                    illustration: .privacy
                )
                .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 8) {
                ForEach(0..<3) { index in
                    Capsule()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.22))
                        .frame(width: index == page ? 24 : 8, height: 8)
                }
            }
            .padding(.bottom, 22)

            Button(page == 2 ? "Continue" : "Next") {
                if page < 2 {
                    withAnimation { page += 1 }
                } else {
                    hasSeenIntroduction = true
                    step = .permission
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)

            Spacer().frame(height: 24)
        }
    }

    private var permission: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 58, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse)

            VStack(spacing: 12) {
                Text("Allow access to your screenshots")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("Later needs Photos access to find and organize your screenshots. You can choose selected photos or allow full access on the next screen.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            privacyPoints

            if authorizationStatus == .denied || authorizationStatus == .restricted {
                Text("Photos access is off. You can enable it in Settings whenever you’re ready.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: settingsURL)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else {
                Button("Allow Photos Access") {
                    Task { await requestPhotosAndScan() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer()
        }
        .padding(28)
    }

    private var privacyPoints: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingCheck(text: "Only photos you allow are available to Later")
            OnboardingCheck(text: "Everything stays private on your iPhone")
            OnboardingCheck(text: "You can change access anytime in Settings")
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private var completion: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 68))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.bounce, value: step)
            Text(items.isEmpty ? "You’re ready for Later." : "Your Later is ready.")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)
            Text(items.isEmpty
                 ? "Take a screenshot and Later will organize it when it becomes available."
                 : "We organized \(items.count) \(items.count == 1 ? "thing" : "things") from your screenshots.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if !items.isEmpty {
                summaryGrid
            }

            Button("See my Later") { onFinish() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            Spacer()
        }
        .padding(28)
    }

    private var summaryGrid: some View {
        let summaries = categorySummaries
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(summaries, id: \.category) { summary in
                HStack(spacing: 10) {
                    Image(systemName: summary.category.icon)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(summary.count)").font(.headline)
                        Text(summary.category.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var categorySummaries: [(category: LaterCategory, count: Int)] {
        Dictionary(grouping: items, by: \.category)
            .map { (category: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(4)
            .map { $0 }
    }

    @MainActor
    private func requestPhotosAndScan() async {
        authorizationStatus = await PhotoAuthorizationService().requestAccess()
        hasRequestedPhotos = true
        guard authorizationStatus == .authorized || authorizationStatus == .limited else { return }
        await startInitialScan()
    }

    @MainActor
    private func startInitialScan() async {
        guard !scanStarted else { return }
        scanStarted = true
        step = .scanning
        discoveryCoordinator.setActive(true)
        Task {
            _ = await discoveryCoordinator.discover(.initialScan)
        }
    }

    @MainActor
    private func finishOnboarding() {
        hasCompletedInitialScan = true
        onFinish()
    }

    @MainActor
    private func restoreStep() {
        authorizationStatus = PhotoAuthorizationService().status
        guard hasSeenIntroduction else {
            step = .introduction
            return
        }
        guard hasRequestedPhotos else {
            step = .permission
            return
        }
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            if hasCompletedInitialScan {
                onFinish()
            } else {
                Task { await startInitialScan() }
            }
        } else {
            step = .permission
        }
    }
}

private struct OnboardingCheck: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.subheadline)
            .foregroundStyle(.primary, Color.accentColor)
    }
}
