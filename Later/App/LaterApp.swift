import SwiftData
import SwiftUI

@main
struct LaterApp: App {
    private let modelContainer: ModelContainer
    @StateObject private var discoveryCoordinator: ScreenshotDiscoveryCoordinator
    private let backgroundTasks: BackgroundTaskManager
    @AppStorage(OnboardingState.completedKey) private var hasCompletedOnboarding = false

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
            .task(id: hasCompletedOnboarding) {
                guard hasCompletedOnboarding else { return }
                await NotificationManager.shared.activate()
            }
        }
        .modelContainer(modelContainer)
    }
}
