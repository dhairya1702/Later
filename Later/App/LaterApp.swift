import SwiftData
import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@main
struct LaterApp: App {
    @UIApplicationDelegateAdaptor(LaterAppDelegate.self) private var appDelegate
    private let modelContainer: ModelContainer
    @StateObject private var discoveryCoordinator: ScreenshotDiscoveryCoordinator
    private let backgroundTasks: BackgroundTaskManager
    @AppStorage(OnboardingState.completedKey) private var hasCompletedOnboarding = false
    @AppStorage("appearancePreference") private var appearance = AppearancePreference.system

    @MainActor
    init() {
        do {
            let container = try ModelContainer(for: ScreenshotRecord.self, LaterItem.self)
            let coordinator = ScreenshotDiscoveryCoordinator(container: container)
            modelContainer = container
            NotificationManager.shared.configure(container: container)
            _discoveryCoordinator = StateObject(wrappedValue: coordinator)
            backgroundTasks = BackgroundTaskManager(coordinator: coordinator)
            backgroundTasks.scheduleNextRefresh()
            backgroundTasks.scheduleProcessingIfNeeded()
        } catch {
            fatalError("Unable to create Later's persistent store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    HomeView(discoveryCoordinator: discoveryCoordinator)
                } else {
                    OnboardingView(discoveryCoordinator: discoveryCoordinator) {
                        hasCompletedOnboarding = true
                    }
                }
            }
            .fontDesign(.rounded)
            .tint(Color.accentColor)
            .preferredColorScheme(appearance.colorScheme)
            .task(id: hasCompletedOnboarding) {
                guard hasCompletedOnboarding else { return }
                await NotificationManager.shared.activate()
            }
        }
        .modelContainer(modelContainer)
    }
}
