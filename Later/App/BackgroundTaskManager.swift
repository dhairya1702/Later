import BackgroundTasks
import Foundation

private final class BackgroundTaskCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isCompleted = false

    func finish(_ task: BGTask, success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !isCompleted else { return }
        isCompleted = true
        task.setTaskCompleted(success: success)
    }
}

@MainActor
final class BackgroundTaskManager {
    static let refreshIdentifier = "com.later.refreshScreenshots"
    static let processingIdentifier = "com.later.processScreenshots"

    private weak var coordinator: ScreenshotDiscoveryCoordinator?

    init(coordinator: ScreenshotDiscoveryCoordinator) {
        self.coordinator = coordinator

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in self?.handle(refreshTask) }
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingIdentifier,
            using: nil
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in self?.handle(processingTask) }
        }

        coordinator.setBackgroundWorkScheduler { [weak self] in
            self?.scheduleBackgroundCatchUp()
        }
    }

    func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // iOS may reject duplicate requests or disable background refresh.
        }
    }

    func scheduleProcessingIfNeeded() {
        guard coordinator?.hasUnprocessedScreenshots() == true else { return }
        let request = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Scheduling is best-effort and a foreground catch-up remains available.
        }
    }

    private func scheduleBackgroundCatchUp() {
        scheduleNextRefresh()
        scheduleProcessingIfNeeded()
    }

    private func handle(_ task: BGAppRefreshTask) {
        scheduleNextRefresh()
        let completion = BackgroundTaskCompletion()
        guard let coordinator else {
            completion.finish(task, success: false)
            return
        }

        let work = Task { @MainActor in
            let completed = await coordinator.discover(.backgroundRefresh)
            if !Task.isCancelled {
                self.scheduleProcessingIfNeeded()
                completion.finish(task, success: completed)
            }
        }
        task.expirationHandler = { [weak coordinator] in
            work.cancel()
            Task { @MainActor in coordinator?.cancelActiveProcessing() }
            completion.finish(task, success: false)
        }
    }

    private func handle(_ task: BGProcessingTask) {
        scheduleNextRefresh()
        let completion = BackgroundTaskCompletion()
        guard let coordinator else {
            completion.finish(task, success: false)
            return
        }

        let work = Task { @MainActor in
            let completed = await coordinator.discover(.backgroundProcessing)
            if !Task.isCancelled {
                self.scheduleProcessingIfNeeded()
                completion.finish(task, success: completed)
            }
        }
        task.expirationHandler = { [weak coordinator] in
            work.cancel()
            Task { @MainActor in coordinator?.cancelActiveProcessing() }
            completion.finish(task, success: false)
        }
    }
}
