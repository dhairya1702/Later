import Foundation
import SwiftData
import UserNotifications

struct LaterNotificationPlan: Hashable {
    let identifier: String
    let itemID: UUID
    let relatedItemIDs: [UUID]
    let fireDate: Date
    let title: String
    let body: String
    let isUrgent: Bool
    let isSummary: Bool
}

struct NotificationPlanner {
    let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func plans(
        for allItems: [LaterItem],
        now: Date = .now,
        horizonDays: Int = 7,
        currentDayImmediateCount: Int = 0
    ) -> [LaterNotificationPlan] {
        let items = allItems.filter {
            !$0.isCompleted
                && !$0.isDuplicateCopy
                && $0.screenSurface != .lockScreen
        }
        guard !items.isEmpty,
              let horizonEnd = calendar.date(byAdding: .day, value: horizonDays, to: now) else {
            return []
        }

        var result = urgentPlans(for: items, now: now, horizonEnd: horizonEnd)
        var usage = Dictionary(grouping: result, by: \.itemID).mapValues(\.count)

        for dayOffset in 0..<horizonDays {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let dayStart = calendar.startOfDay(for: day)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            let plansToday = { result.filter { $0.fireDate >= dayStart && $0.fireDate < nextDay } }
            var usedToday = Set(plansToday().map(\.itemID))
            let baseTarget = min(3, items.count)
            let dailyTarget = dayOffset == 0
                ? max(0, baseTarget - currentDayImmediateCount)
                : baseTarget

            for (slotIndex, hourAndMinute) in Self.dailySlots.enumerated() {
                guard plansToday().count < dailyTarget,
                      plansToday().count < 5,
                      let fireDate = calendar.date(
                        bySettingHour: hourAndMinute.hour,
                        minute: hourAndMinute.minute,
                        second: 0,
                        of: dayStart
                      ),
                      fireDate > now.addingTimeInterval(5 * 60) else { continue }

                let available = items.filter { item in
                    !usedToday.contains(item.id)
                        && usage[item.id, default: 0] < 2
                        && (item.snoozedUntil == nil || item.snoozedUntil! <= fireDate)
                }
                guard !available.isEmpty else { continue }

                let preferred = available.filter {
                    preferredCategories(forSlot: slotIndex).contains($0.category)
                }
                let pool = preferred.isEmpty ? available : preferred
                let sorted = pool.sorted {
                    if $0.resurfacedCount != $1.resurfacedCount {
                        return $0.resurfacedCount < $1.resurfacedCount
                    }
                    return $0.createdAt < $1.createdAt
                }
                let item = sorted[(dayOffset + slotIndex) % sorted.count]
                result.append(generalPlan(for: item, fireDate: fireDate))
                usedToday.insert(item.id)
                usage[item.id, default: 0] += 1
            }

            if let summary = summaryPlan(
                for: items,
                relatedItemIDs: Array(usedToday),
                day: dayStart,
                now: now
            ) {
                result.append(summary)
            }
        }

        let inHorizon = result.filter { $0.fireDate > now && $0.fireDate <= horizonEnd }
        let cappedByDay = Dictionary(grouping: inHorizon) {
            calendar.startOfDay(for: $0.fireDate)
        }.values.flatMap { dayPlans in
            let dailyCap = dayPlans.first.map {
                calendar.isDate($0.fireDate, inSameDayAs: now)
                    ? max(0, 5 - currentDayImmediateCount)
                    : 5
            } ?? 5
            return dayPlans.sorted {
                if $0.isUrgent != $1.isUrgent { return $0.isUrgent }
                if $0.isSummary != $1.isSummary { return $0.isSummary }
                return $0.fireDate < $1.fireDate
            }.prefix(dailyCap)
        }

        return cappedByDay
            .sorted { $0.fireDate < $1.fireDate }
            .prefix(60)
            .map { $0 }
    }

    private func urgentPlans(
        for items: [LaterItem],
        now: Date,
        horizonEnd: Date
    ) -> [LaterNotificationPlan] {
        var plans: [LaterNotificationPlan] = []

        for item in items {
            guard let date = item.detectedDate,
                  date > now,
                  let role = item.importantDateRole,
                  role != .unspecified else { continue }

            let offsets: [TimeInterval]
            switch role {
            case .expiration:
                offsets = [-259_200.0, -86_400.0, 0.0]
            case .event, .reservation, .travel:
                offsets = [-604_800.0, -86_400.0, -7_200.0]
            case .deadline:
                offsets = [-86_400.0, -7_200.0]
            case .delivery:
                offsets = [-86_400.0]
            case .unspecified:
                offsets = []
            }

            for (index, offset) in offsets.enumerated() {
                var fireDate = date.addingTimeInterval(offset)
                if role == .expiration && offset == 0 {
                    fireDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
                }
                guard fireDate > now.addingTimeInterval(5 * 60),
                      fireDate <= horizonEnd,
                      item.snoozedUntil == nil || item.snoozedUntil! <= fireDate else { continue }
                let copy = IntentNotificationComposer(calendar: calendar).compose(
                    for: item,
                    referenceDate: fireDate
                )
                plans.append(LaterNotificationPlan(
                    identifier: "later.urgent.\(item.id.uuidString).\(index).\(dayKey(fireDate))",
                    itemID: item.id,
                    relatedItemIDs: [item.id],
                    fireDate: fireDate,
                    title: copy.title,
                    body: copy.body,
                    isUrgent: true,
                    isSummary: false
                ))
            }
        }
        return plans
    }

    private func generalPlan(for item: LaterItem, fireDate: Date) -> LaterNotificationPlan {
        let copy = IntentNotificationComposer(calendar: calendar).compose(
            for: item,
            referenceDate: fireDate
        )
        return LaterNotificationPlan(
            identifier: "later.resurface.\(item.id.uuidString).\(dayKey(fireDate))",
            itemID: item.id,
            relatedItemIDs: [item.id],
            fireDate: fireDate,
            title: copy.title,
            body: copy.body,
            isUrgent: false,
            isSummary: false
        )
    }

    private func summaryPlan(
        for items: [LaterItem],
        relatedItemIDs: [UUID],
        day: Date,
        now: Date
    ) -> LaterNotificationPlan? {
        guard relatedItemIDs.count >= 2,
              let fireDate = calendar.date(bySettingHour: 20, minute: 30, second: 0, of: day),
              fireDate > now.addingTimeInterval(5 * 60) else { return nil }

        let itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let relatedItems = relatedItemIDs
            .compactMap { itemByID[$0] }
            .sorted { lhs, rhs in
                if isActionable(lhs) != isActionable(rhs) { return isActionable(lhs) }
                return lhs.createdAt > rhs.createdAt
            }
        guard let first = relatedItems.first else { return nil }

        let count = relatedItems.count
        let title = relatedItems.contains(where: isActionable)
            ? "\(count) things may still need your attention"
            : "\(count) things are still waiting in Later"
        let composer = IntentNotificationComposer(calendar: calendar)
        let namedItems = relatedItems.filter { $0.category != .other }
        let names = namedItems.prefix(2).map {
            composer.compose(for: $0, referenceDate: fireDate).title
        }
        let unclassifiedCount = relatedItems.filter { $0.category == .other }.count
        let body: String
        if names.isEmpty {
            body = count == 1
                ? "A screenshot you saved may be worth another look."
                : "\(count) screenshots you saved may be worth another look."
        } else if unclassifiedCount > 0 {
            let savedLabel = unclassifiedCount == 1
                ? "1 more saved screenshot"
                : "\(unclassifiedCount) more saved screenshots"
            body = names.joined(separator: ", ") + ", and " + savedLabel + "."
        } else if count > 2 {
            body = names.joined(separator: ", ") + ", and \(count - 2) more."
        } else {
            body = names.joined(separator: " and ")
        }

        return LaterNotificationPlan(
            identifier: "later.summary.\(dayKey(fireDate))",
            itemID: first.id,
            relatedItemIDs: relatedItems.map(\.id),
            fireDate: fireDate,
            title: title,
            body: body,
            isUrgent: false,
            isSummary: true
        )
    }

    private func isActionable(_ item: LaterItem) -> Bool {
        if item.category == .doItem || item.category == .offer { return true }
        guard let role = item.importantDateRole else { return false }
        return role != .unspecified && role != .delivery
    }

    private func preferredCategories(forSlot slot: Int) -> Set<LaterCategory> {
        switch slot {
        case 0: [.doItem, .remember, .read]
        case 1: [.buy, .doItem, .read, .offer]
        case 2: [.eat, .go, .buy, .offer]
        case 3: [.watch, .eat, .go]
        default: [.read, .watch, .inspire, .photo]
        }
    }

    private func dayKey(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private static let dailySlots = [
        (hour: 9, minute: 0),
        (hour: 12, minute: 30),
        (hour: 16, minute: 30),
        (hour: 19, minute: 0)
    ]
}

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private enum Action {
        static let done = "later.action.done"
        static let remindLater = "later.action.remindLater"
        static let review = "later.action.review"
    }

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private var container: ModelContainer?
    private var isReconciling = false
    private var needsAnotherReconcile = false

    private override init() {
        super.init()
    }

    func configure(container: ModelContainer) {
        self.container = container
        center.delegate = self
        registerActions()
    }

    func activate() async {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        await reconcile()
    }

    func handleProcessed(
        item: LaterItem,
        captureDate: Date,
        isNew: Bool
    ) async {
        if isNew { await deliverImmediateIfEligible(item: item, captureDate: captureDate) }
        await reconcile()
    }

    func reconcile() async {
        guard container != nil else { return }
        if isReconciling {
            needsAnotherReconcile = true
            return
        }
        isReconciling = true

        repeat {
            needsAnotherReconcile = false
            await performReconciliation()
        } while needsAnotherReconcile

        isReconciling = false
    }

    private func performReconciliation() async {
        guard let container else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let context = ModelContext(container)
        let items = (try? context.fetch(FetchDescriptor<LaterItem>())) ?? []
        let plans = NotificationPlanner().plans(
            for: items,
            currentDayImmediateCount: currentImmediateCount()
        )
        let existing = await center.pendingNotificationRequests()
        let managedIdentifiers = existing.map(\.identifier).filter {
            $0.hasPrefix("later.") && !$0.hasPrefix("later.immediate.")
        }
        center.removePendingNotificationRequests(withIdentifiers: managedIdentifiers)

        for plan in plans {
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.body
            content.sound = .default
            content.categoryIdentifier = plan.isSummary ? "later.summary" : "later.item"
            content.userInfo = [
                "itemID": plan.itemID.uuidString,
                "itemIDs": plan.relatedItemIDs.map(\.uuidString)
            ]
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: plan.fireDate
            )
            let request = UNNotificationRequest(
                identifier: plan.identifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await center.add(request)
        }
    }

    private func registerActions() {
        let done = UNNotificationAction(identifier: Action.done, title: "Done", options: [])
        let remindLater = UNNotificationAction(
            identifier: Action.remindLater,
            title: "Remind Later",
            options: []
        )
        let remindTomorrow = UNNotificationAction(
            identifier: Action.remindLater,
            title: "Remind Tomorrow",
            options: []
        )
        let review = UNNotificationAction(
            identifier: Action.review,
            title: "Review",
            options: [.foreground]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "later.item",
                actions: [done, remindLater],
                intentIdentifiers: [],
                options: [.customDismissAction]
            ),
            UNNotificationCategory(
                identifier: "later.summary",
                actions: [review, remindTomorrow],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    private func deliverImmediateIfEligible(item: LaterItem, captureDate: Date) async {
        let now = Date.now
        let age = now.timeIntervalSince(captureDate)
        guard !item.isCompleted,
              !item.isDuplicateCopy,
              item.screenSurface != .lockScreen,
              age >= -60,
              age <= 10 * 60,
              currentImmediateCount() < 2 else { return }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let copy = IntentNotificationComposer().compose(for: item, referenceDate: now)
        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.body = copy.body
        content.sound = .default
        content.categoryIdentifier = "later.item"
        content.userInfo = [
            "itemID": item.id.uuidString,
            "itemIDs": [item.id.uuidString]
        ]
        let request = UNNotificationRequest(
            identifier: "later.immediate.\(item.id.uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            setCurrentImmediateCount(currentImmediateCount() + 1)
        } catch {
            // Future resurfacing remains scheduled even if immediate delivery fails.
        }
    }

    private func currentImmediateCount(now: Date = .now) -> Int {
        let key = immediateDayKey(now)
        guard defaults.string(forKey: "notification.immediateDay") == key else {
            defaults.set(key, forKey: "notification.immediateDay")
            defaults.set(0, forKey: "notification.immediateCount")
            return 0
        }
        return defaults.integer(forKey: "notification.immediateCount")
    }

    private func setCurrentImmediateCount(_ value: Int) {
        defaults.set(immediateDayKey(.now), forKey: "notification.immediateDay")
        defaults.set(value, forKey: "notification.immediateCount")
    }

    private func immediateDayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let itemIDs = (userInfo["itemIDs"] as? [String] ?? [])
            .compactMap(UUID.init(uuidString:))
        let itemID = (userInfo["itemID"] as? String).flatMap(UUID.init(uuidString:))

        switch response.actionIdentifier {
        case Action.done:
            if let itemID { await complete(itemID: itemID) }
        case Action.remindLater:
            await snooze(itemIDs: itemIDs.isEmpty ? [itemID].compactMap { $0 } : itemIDs)
        case Action.review:
            break
        default:
            break
        }
    }

    private func complete(itemID: UUID) async {
        guard let container else { return }
        let context = ModelContext(container)
        let id = itemID
        var descriptor = FetchDescriptor<LaterItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let item = try? context.fetch(descriptor).first else { return }
        item.completedAt = .now
        item.statusRaw = "completed"
        item.updatedAt = .now
        try? context.save()
        await reconcile()
    }

    private func snooze(itemIDs: [UUID]) async {
        guard let container else { return }
        let context = ModelContext(container)
        let calendar = Calendar.current
        let snoozedUntil = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: .now)
        )
        let items = (try? context.fetch(FetchDescriptor<LaterItem>())) ?? []
        for item in items where itemIDs.contains(item.id) {
            item.snoozedUntil = snoozedUntil
            item.updatedAt = .now
        }
        try? context.save()
        await reconcile()
    }
}
