import Photos
import SwiftUI

struct OnboardingView: View {
    @Environment(\.colorScheme) private var colorScheme
    private enum Step {
        case introduction
        case scanning
    }

    @ObservedObject var discoveryCoordinator: ScreenshotDiscoveryCoordinator
    let onFinish: () -> Void

    @AppStorage(OnboardingState.introductionKey) private var hasSeenIntroduction = false
    @AppStorage(OnboardingState.requestedPhotosKey) private var hasRequestedPhotos = false
    @AppStorage(OnboardingState.initialScanKey) private var hasCompletedInitialScan = false
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
            case .scanning:
                InitialScanView(coordinator: discoveryCoordinator) {
                    finishOnboarding()
                }
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
                    message: "Later brings forgotten screenshots back to you and pulls out useful details like dates, prices, codes, and places.",
                    illustration: .cards
                )
                .tag(0)

                OnboardingPageView(
                    symbol: "lock.shield.fill",
                    title: "Your screenshots stay under your control.",
                    message: "Later only accesses the photos you allow. You can change Photos access anytime in Settings.",
                    illustration: .privacy
                )
                .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 8) {
                ForEach(0..<2) { index in
                    Capsule()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.22))
                        .frame(width: index == page ? 24 : 8, height: 8)
                }
            }
            .padding(.bottom, 22)

            if page == 0 {
                Button {
                    hasSeenIntroduction = true
                    withAnimation { page = 1 }
                } label: {
                    Text("Next").foregroundStyle(prominentLabelColor)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
            } else if authorizationStatus == .denied || authorizationStatus == .restricted {
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    Link(destination: settingsURL) {
                        Text("Open Settings").foregroundStyle(prominentLabelColor)
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else {
                Button {
                    Task { await requestPhotosAndScan() }
                } label: {
                    Text("Allow Photos Access").foregroundStyle(prominentLabelColor)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
            }

            Spacer().frame(height: 24)
        }
    }

    private var prominentLabelColor: Color {
        colorScheme == .dark ? Color(red: 0.02, green: 0.12, blue: 0.18) : .white
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
            page = 0
            step = .introduction
            return
        }
        guard hasRequestedPhotos else {
            page = 1
            step = .introduction
            return
        }
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            if hasCompletedInitialScan {
                onFinish()
            } else {
                Task { await startInitialScan() }
            }
        } else {
            page = 1
            step = .introduction
        }
    }
}
