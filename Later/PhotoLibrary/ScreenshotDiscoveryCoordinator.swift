import Photos
import SwiftData
import UIKit

enum ScreenshotDiscoverySource {
    case initialScan
    case foreground
    case photoLibraryChange
    case backgroundRefresh
    case backgroundProcessing

    var batchLimit: Int {
        switch self {
        case .initialScan: 10
        case .backgroundRefresh: 10
        case .foreground, .photoLibraryChange, .backgroundProcessing: 10
        }
    }
}

/// Owns every path that discovers screenshots. The class is main-actor isolated so
/// its ModelContext is never touched concurrently, even while OCR requests overlap.
@MainActor
final class ScreenshotDiscoveryCoordinator: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var isProcessing = false
    @Published private(set) var currentBatchTotal = 0
    @Published private(set) var currentBatchCompleted = 0

    var progress: Double {
        guard currentBatchTotal > 0 else { return isProcessing ? 0 : 1 }
        return min(1, Double(currentBatchCompleted) / Double(currentBatchTotal))
    }

    private let container: ModelContainer
    private let fetcher = ScreenshotFetcher()
    private var screenshotFetchResult: PHFetchResult<PHAsset>?
    private var isObservingPhotoLibrary = false
    private var inFlightIdentifiers = Set<String>()
    private var pendingChangedIdentifiers = Set<String>()
    private var changeDebounceTask: Task<Void, Never>?
    private var activeBatch: Task<Bool, Never>?
    private var backgroundWorkScheduler: (() -> Void)?
    private var finiteBackgroundTask = UIBackgroundTaskIdentifier.invalid
    private var isProcessingPhotoChanges = false
    private var isActive = false

    init(container: ModelContainer) {
        self.container = container
        super.init()
    }

    deinit {
        changeDebounceTask?.cancel()
        activeBatch?.cancel()
        if isObservingPhotoLibrary {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            startPhotoLibraryObservationIfAuthorized()
            if !pendingChangedIdentifiers.isEmpty {
                Task { @MainActor [weak self] in await self?.processPendingPhotoChanges() }
            }
        } else {
            backgroundWorkScheduler?()
        }
    }

    func setBackgroundWorkScheduler(_ scheduler: @escaping () -> Void) {
        backgroundWorkScheduler = scheduler
    }

    @discardableResult
    func discover(_ source: ScreenshotDiscoverySource) async -> Bool {
        guard PhotoAuthorizationService().status == .authorized ||
                PhotoAuthorizationService().status == .limited else { return true }
        startPhotoLibraryObservationIfAuthorized()

        if let activeBatch {
            return await activeBatch.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.runDiscovery(limit: source.batchLimit)
        }
        activeBatch = task
        let completed = await task.value
        activeBatch = nil
        return completed
    }

    func cancelActiveProcessing() {
        activeBatch?.cancel()
    }

    /// True when at least one available screenshot has not produced a LaterItem.
    func hasUnprocessedScreenshots() -> Bool {
        guard PhotoAuthorizationService().status == .authorized ||
                PhotoAuthorizationService().status == .limited else { return false }
        let context = ModelContext(container)
        guard let processed = try? ScreenshotRepository(context: context)
            .upToDateProcessedIdentifiers() else { return false }

        let result = fetcher.allScreenshots()
        var found = false
        result.enumerateObjects { asset, _, stop in
            if !processed.contains(asset.localIdentifier) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    @objc nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.receivePhotoLibraryChange(changeInstance)
        }
    }

    private func receivePhotoLibraryChange(_ change: PHChange) {
        guard let currentFetchResult = screenshotFetchResult,
              let details = change.changeDetails(for: currentFetchResult) else { return }
        screenshotFetchResult = details.fetchResultAfterChanges
        guard details.hasIncrementalChanges else { return }

        pendingChangedIdentifiers.formUnion(
            details.insertedObjects.map(\.localIdentifier)
        )
        guard !pendingChangedIdentifiers.isEmpty else { return }

        if !isActive {
            beginFiniteBackgroundExecutionIfNeeded()
            backgroundWorkScheduler?()
        }

        changeDebounceTask?.cancel()
        changeDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(self?.isActive == true ? 750 : 150))
                await self?.processPendingPhotoChanges()
            } catch {
                // A newer library update replaced this debounce window.
            }
        }
    }

    private func startPhotoLibraryObservationIfAuthorized() {
        let status = PhotoAuthorizationService().status
        guard !isObservingPhotoLibrary,
              status == .authorized || status == .limited else { return }
        screenshotFetchResult = fetcher.allScreenshots()
        PHPhotoLibrary.shared().register(self)
        isObservingPhotoLibrary = true
    }

    private func processPendingPhotoChanges() async {
        guard !isProcessingPhotoChanges else { return }
        isProcessingPhotoChanges = true
        if !isActive { beginFiniteBackgroundExecutionIfNeeded() }
        defer {
            isProcessingPhotoChanges = false
            endFiniteBackgroundExecution()
        }

        while !pendingChangedIdentifiers.isEmpty && !Task.isCancelled {
            let identifiers = pendingChangedIdentifiers
            pendingChangedIdentifiers.removeAll()
            let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
            var assets: [PHAsset] = []
            result.enumerateObjects { asset, _, _ in
                guard asset.mediaType == .image,
                      asset.mediaSubtypes.contains(.photoScreenshot) else { return }
                assets.append(asset)
            }

            // Join any existing batch before starting this one so the global OCR
            // and classification concurrency never exceeds two.
            if let activeBatch {
                _ = await activeBatch.value
            }
            let task = Task { @MainActor [weak self] in
                guard let self else { return false }
                self.isProcessing = true
                defer { self.isProcessing = false }
                return await self.process(
                    assets: assets,
                    limit: ScreenshotDiscoverySource.photoLibraryChange.batchLimit
                )
            }
            activeBatch = task
            _ = await task.value
            activeBatch = nil
        }
    }

    private func beginFiniteBackgroundExecutionIfNeeded() {
        guard finiteBackgroundTask == .invalid else { return }
        finiteBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Process recent screenshot"
        ) { [weak self] in
            Task { @MainActor in
                self?.changeDebounceTask?.cancel()
                self?.activeBatch?.cancel()
                self?.endFiniteBackgroundExecution()
            }
        }
    }

    private func endFiniteBackgroundExecution() {
        guard finiteBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(finiteBackgroundTask)
        finiteBackgroundTask = .invalid
    }

    private func runDiscovery(limit: Int) async -> Bool {
        isProcessing = true
        defer { isProcessing = false }

        let context = ModelContext(container)
        let repository = ScreenshotRepository(context: context)
        guard let processed = try? repository.upToDateProcessedIdentifiers(),
              let successful = try? repository.successfullyProcessedIdentifiers() else { return false }

        let result = fetcher.allScreenshots()
        var neverProcessed: [PHAsset] = []
        var stale: [PHAsset] = []
        result.enumerateObjects { [inFlightIdentifiers] asset, _, stop in
            guard !processed.contains(asset.localIdentifier),
                  !inFlightIdentifiers.contains(asset.localIdentifier) else { return }
            if successful.contains(asset.localIdentifier) {
                stale.append(asset)
            } else {
                neverProcessed.append(asset)
            }
        }
        let assets = Array((neverProcessed + stale).prefix(limit))
        return await process(assets: assets, limit: limit, context: context)
    }

    private func process(
        assets: [PHAsset],
        limit: Int,
        context suppliedContext: ModelContext? = nil
    ) async -> Bool {
        let context = suppliedContext ?? ModelContext(container)
        let processed = (try? ScreenshotRepository(context: context)
            .upToDateProcessedIdentifiers()) ?? []
        let candidates = Array(assets
            .filter { !processed.contains($0.localIdentifier) && !inFlightIdentifiers.contains($0.localIdentifier) }
            .prefix(limit))
        currentBatchTotal = candidates.count
        currentBatchCompleted = 0
        guard !candidates.isEmpty else { return !Task.isCancelled }

        let processor = ScreenshotProcessingService(context: context)
        var iterator = candidates.makeIterator()

        return await withTaskGroup(of: String.self, returning: Bool.self) { group in
            for _ in 0..<2 {
                guard let asset = iterator.next() else { break }
                inFlightIdentifiers.insert(asset.localIdentifier)
                group.addTask {
                    await processor.process(asset)
                    return asset.localIdentifier
                }
            }

            while let identifier = await group.next() {
                inFlightIdentifiers.remove(identifier)
                currentBatchCompleted += 1
                guard !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }
                if let asset = iterator.next() {
                    inFlightIdentifiers.insert(asset.localIdentifier)
                    group.addTask {
                        await processor.process(asset)
                        return asset.localIdentifier
                    }
                }
            }
            return !Task.isCancelled
        }
    }
}
