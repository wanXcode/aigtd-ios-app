@preconcurrency import EventKit
import Foundation
import Observation

enum AppTab: Hashable {
    case chat
    case reminders
    case agent
}

enum ChatComposerResumeSource: Hashable {
    case modelSetup
    case reminderAdjustment
}

struct ReminderOverviewSection: Identifiable, Hashable {
    let id: String
    let title: String
    let items: [ReminderItemInfo]
}

struct ReminderOverviewOrderState: Equatable {
    static let empty = ReminderOverviewOrderState(itemIDsByListKey: [:])

    fileprivate let itemIDsByListKey: [String: [String]]
}

enum ReminderOverviewPolicy {
    static func sections(
        lists: [ReminderListInfo],
        items: [ReminderItemInfo]
    ) -> [ReminderOverviewSection] {
        var remainingItems = items.filter { $0.isCompleted == false }
        var claimedListKeys = Set<String>()
        let fallbackListKeysByTitle = uniqueListKeysByTitle(lists)

        let knownSections = lists.map { list in
            let key = listKey(id: list.id, title: list.title)
            let sectionItems: [ReminderItemInfo]

            if claimedListKeys.insert(key).inserted {
                sectionItems = remainingItems.filter {
                    itemKey($0, fallbackListKeysByTitle: fallbackListKeysByTitle) == key
                }
                remainingItems.removeAll {
                    itemKey($0, fallbackListKeysByTitle: fallbackListKeysByTitle) == key
                }
            } else {
                sectionItems = []
            }

            return ReminderOverviewSection(
                id: list.id,
                title: displayListTitle(list.title),
                items: sectionItems
            )
        }

        var unknownSections: [ReminderOverviewSection] = []
        while let first = remainingItems.first {
            let key = itemKey(first, fallbackListKeysByTitle: fallbackListKeysByTitle)
            let matching = remainingItems.filter {
                itemKey($0, fallbackListKeysByTitle: fallbackListKeysByTitle) == key
            }
            remainingItems.removeAll {
                itemKey($0, fallbackListKeysByTitle: fallbackListKeysByTitle) == key
            }
            unknownSections.append(
                ReminderOverviewSection(
                    id: "unlisted-\(first.id)",
                    title: displayListTitle(first.listTitle),
                    items: matching
                )
            )
        }

        return knownSections + unknownSections
    }

    static func stabilizedItems(
        _ items: [ReminderItemInfo],
        previousState: ReminderOverviewOrderState
    ) -> (items: [ReminderItemInfo], state: ReminderOverviewOrderState) {
        var incomingItemsByListKey: [String: [ReminderItemInfo]] = [:]
        var incomingListKeys: [String] = []

        for item in items {
            let key = itemKey(item)
            if incomingItemsByListKey[key] == nil {
                incomingListKeys.append(key)
            }
            incomingItemsByListKey[key, default: []].append(item)
        }

        var stabilizedItemsByListKey: [String: [ReminderItemInfo]] = [:]
        var updatedItemIDsByListKey: [String: [String]] = [:]

        for key in incomingListKeys {
            let incomingItems = incomingItemsByListKey[key] ?? []
            var incomingItemByID: [String: ReminderItemInfo] = [:]
            var incomingIDs: [String] = []

            for item in incomingItems where incomingItemByID[item.id] == nil {
                incomingItemByID[item.id] = item
                incomingIDs.append(item.id)
            }

            let retainedIDs = (previousState.itemIDsByListKey[key] ?? []).filter {
                incomingItemByID[$0] != nil
            }
            var seenIDs = Set(retainedIDs)
            let appendedIDs = incomingIDs.filter { seenIDs.insert($0).inserted }
            let stabilizedIDs = retainedIDs + appendedIDs

            updatedItemIDsByListKey[key] = stabilizedIDs
            stabilizedItemsByListKey[key] = stabilizedIDs.compactMap { incomingItemByID[$0] }
        }

        var nextItemIndexByListKey: [String: Int] = [:]
        let stabilizedItems = items.compactMap { item -> ReminderItemInfo? in
            let key = itemKey(item)
            let index = nextItemIndexByListKey[key, default: 0]
            guard let orderedItems = stabilizedItemsByListKey[key], index < orderedItems.count else {
                return nil
            }
            nextItemIndexByListKey[key] = index + 1
            return orderedItems[index]
        }

        return (
            stabilizedItems,
            ReminderOverviewOrderState(itemIDsByListKey: updatedItemIDsByListKey)
        )
    }

    static func syncDescription(
        isLoading: Bool,
        lastSyncAt: Date?,
        now: Date
    ) -> String {
        if isLoading {
            return "正在同步提醒事项…"
        }

        guard let lastSyncAt else {
            return "还没有同步过提醒事项"
        }

        let elapsed = max(0, now.timeIntervalSince(lastSyncAt))
        if elapsed < 5 {
            return "刚刚同步"
        }
        if elapsed < 60 {
            return "最新同步 \(Int(elapsed)) 秒前"
        }
        if elapsed < 3_600 {
            return "最新同步 \(Int(elapsed / 60)) 分钟前"
        }
        if elapsed < 86_400 {
            return "最新同步 \(Int(elapsed / 3_600)) 小时前"
        }
        return "最新同步 \(Int(elapsed / 86_400)) 天前"
    }

    static func adjustmentDraft(for item: ReminderItemInfo) -> String {
        "请帮我调整“\(item.title)”这条任务："
    }

    private static func normalizedListTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func listKey(id: String, title: String) -> String {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedID.isEmpty ? "title:\(normalizedListTitle(title))" : "id:\(trimmedID)"
    }

    private static func itemKey(
        _ item: ReminderItemInfo,
        fallbackListKeysByTitle: [String: String] = [:]
    ) -> String {
        let trimmedID = item.listID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedID.isEmpty == false {
            return listKey(id: trimmedID, title: item.listTitle)
        }

        let normalizedTitle = normalizedListTitle(item.listTitle)
        return fallbackListKeysByTitle[normalizedTitle]
            ?? listKey(id: "", title: item.listTitle)
    }

    private static func uniqueListKeysByTitle(_ lists: [ReminderListInfo]) -> [String: String] {
        let groupedLists = Dictionary(grouping: lists) { normalizedListTitle($0.title) }
        return groupedLists.reduce(into: [:]) { result, entry in
            guard entry.value.count == 1, let list = entry.value.first else { return }
            result[entry.key] = listKey(id: list.id, title: list.title)
        }
    }

    private static func displayListTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未分类" : trimmed
    }
}

@MainActor
@Observable
final class AppModel {
    private static let onboardingStateStorageKey = "aigtd.onboarding.state.v1"
    var onboardingState = AppModel.loadOnboardingState() {
        didSet {
            persistOnboardingState()
        }
    }
    var selectedTab: AppTab = .chat
    var pendingChatDraftAfterModelSetup = ""
    var shouldResumeChatComposer = false
    var chatComposerResumeSource: ChatComposerResumeSource?
    var pendingReminderAdjustmentContext: ReminderItemInfo?
    var reminderPermissionStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    let starterLists = ["收集箱", "项目", "下一步行动", "等待中", "也许以后"]
    var reminderLists: [ReminderListInfo] = []
    var reminderItems: [ReminderItemInfo] = []
    var reminderListsErrorMessage = ""
    var isLoadingReminderLists = false
    var lastReminderSyncAt: Date?
    var pendingReminderFocusIdentifier: String?
    private var hasBootstrappedAfterLaunch = false
    private var reminderOverviewOrderState = ReminderOverviewOrderState.empty
    private var reminderRefreshGeneration = 0

    var remindersAccessGranted: Bool {
        if #available(iOS 17.0, *) {
            reminderPermissionStatus == .fullAccess || reminderPermissionStatus == .writeOnly
        } else {
            reminderPermissionStatus == .authorized
        }
    }

    var isReminderStoreEmpty: Bool {
        reminderLists.isEmpty
    }

    var groupedReminderItems: [(listTitle: String, items: [ReminderItemInfo])] {
        ReminderOverviewPolicy.sections(lists: reminderLists, items: reminderItems)
            .map { (listTitle: $0.title, items: $0.items) }
    }

    func bootstrapAfterLaunch() async {
        guard hasBootstrappedAfterLaunch == false else { return }
        hasBootstrappedAfterLaunch = true
        await refreshReminderPermission()
    }

    func refreshReminderPermission() async {
        reminderPermissionStatus = EKEventStore.authorizationStatus(for: .reminder)
        guard remindersAccessGranted else {
            reminderRefreshGeneration += 1
            reminderLists = []
            reminderItems = []
            reminderListsErrorMessage = ""
            isLoadingReminderLists = false
            lastReminderSyncAt = nil
            pendingReminderFocusIdentifier = nil
            return
        }

        await refreshReminderLists()
    }

    func requestReminderPermission() async {
        let granted = await ReminderPermissionService().requestAccess()
        reminderPermissionStatus = EKEventStore.authorizationStatus(for: .reminder)
        if granted {
            onboardingState.hasRequestedReminderPermission = true
            await refreshReminderLists()
        }
    }

    func refreshReminderLists() async {
        guard remindersAccessGranted else {
            reminderRefreshGeneration += 1
            reminderLists = []
            reminderItems = []
            reminderListsErrorMessage = ""
            lastReminderSyncAt = nil
            return
        }

        reminderRefreshGeneration += 1
        let refreshGeneration = reminderRefreshGeneration
        isLoadingReminderLists = true
        defer {
            if refreshGeneration == reminderRefreshGeneration {
                isLoadingReminderLists = false
            }
        }

        do {
            let refreshedLists = try ReminderStoreService().fetchReminderLists()
            let refreshedItems = try await fetchReminderItemsInSystemOrder()
            guard refreshGeneration == reminderRefreshGeneration else { return }
            reminderLists = refreshedLists
            reminderItems = refreshedItems
            reminderListsErrorMessage = ""
            lastReminderSyncAt = .now
        } catch {
            guard refreshGeneration == reminderRefreshGeneration else { return }
            reminderListsErrorMessage = error.localizedDescription
        }
    }

    func createStarterTemplate() async -> Bool {
        guard remindersAccessGranted else { return false }
        isLoadingReminderLists = true
        defer { isLoadingReminderLists = false }

        do {
            reminderLists = try ReminderStoreService().createLists(named: starterLists)
            reminderItems = try await fetchReminderItemsInSystemOrder()
            reminderListsErrorMessage = ""
            lastReminderSyncAt = .now
            return true
        } catch {
            reminderListsErrorMessage = error.localizedDescription
            return false
        }
    }

    func prepareReminderFocus(identifier: String?) {
        pendingReminderFocusIdentifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func consumePendingReminderFocusIdentifier() -> String? {
        let identifier = pendingReminderFocusIdentifier
        pendingReminderFocusIdentifier = nil
        return identifier?.isEmpty == false ? identifier : nil
    }

    func createReminderList(named listName: String) async -> Bool {
        guard remindersAccessGranted else { return false }
        isLoadingReminderLists = true
        defer { isLoadingReminderLists = false }

        do {
            reminderLists = try ReminderStoreService().createLists(named: [listName])
            reminderItems = try await fetchReminderItemsInSystemOrder()
            reminderListsErrorMessage = ""
            lastReminderSyncAt = .now
            return true
        } catch {
            reminderListsErrorMessage = error.localizedDescription
            return false
        }
    }

    func setReminderCompletion(identifier: String, isCompleted: Bool) async -> Bool {
        guard remindersAccessGranted else { return false }

        do {
            _ = try ReminderStoreService().updateReminderCompletion(identifier: identifier, isCompleted: isCompleted)
            reminderItems = try await fetchReminderItemsInSystemOrder()
            reminderListsErrorMessage = ""
            lastReminderSyncAt = .now
            return true
        } catch {
            reminderListsErrorMessage = error.localizedDescription
            return false
        }
    }

    func deleteReminder(identifier: String) async -> Bool {
        guard remindersAccessGranted else { return false }

        do {
            _ = try ReminderStoreService().deleteReminder(identifier: identifier)
            reminderItems = try await fetchReminderItemsInSystemOrder()
            reminderListsErrorMessage = ""
            lastReminderSyncAt = .now
            return true
        } catch {
            reminderListsErrorMessage = error.localizedDescription
            return false
        }
    }

    func markModelSetupComplete() {
        onboardingState.hasConfiguredModel = true
    }

    func preparePendingChatDraft(_ draft: String) {
        pendingChatDraftAfterModelSetup = draft
    }

    func routeToAgentSetup(with draft: String) {
        preparePendingChatDraft(draft)
        selectedTab = .agent
    }

    func returnToChatAfterModelSetup() {
        markModelSetupComplete()
        chatComposerResumeSource = .modelSetup
        shouldResumeChatComposer = true
        selectedTab = .chat
    }

    func routeToChatForReminderAdjustment(_ item: ReminderItemInfo) {
        pendingReminderAdjustmentContext = item
        preparePendingChatDraft(ReminderOverviewPolicy.adjustmentDraft(for: item))
        chatComposerResumeSource = .reminderAdjustment
        shouldResumeChatComposer = true
        selectedTab = .chat
    }

    func consumePendingReminderAdjustmentContext() -> ReminderItemInfo? {
        let context = pendingReminderAdjustmentContext
        pendingReminderAdjustmentContext = nil
        return context
    }

    func consumePendingChatDraft() -> String {
        let draft = pendingChatDraftAfterModelSetup
        pendingChatDraftAfterModelSetup = ""
        return draft
    }

    func clearPendingChatDraft() {
        pendingChatDraftAfterModelSetup = ""
        shouldResumeChatComposer = false
        chatComposerResumeSource = nil
        pendingReminderAdjustmentContext = nil
    }

    func finishOnboarding() {
        onboardingState.hasEnteredChat = true
    }

    private static func loadOnboardingState() -> OnboardingState {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: onboardingStateStorageKey),
              let state = try? JSONDecoder().decode(OnboardingState.self, from: data) else {
            return OnboardingState()
        }
        return state
    }

    private func persistOnboardingState() {
        guard let data = try? JSONEncoder().encode(onboardingState) else { return }
        UserDefaults.standard.set(data, forKey: Self.onboardingStateStorageKey)
    }

    private func fetchReminderItemsInSystemOrder() async throws -> [ReminderItemInfo] {
        let fetchedItems = try await Self.loadReminderItemsInSystemOrder()

        let stabilized = ReminderOverviewPolicy.stabilizedItems(
            fetchedItems,
            previousState: reminderOverviewOrderState
        )
        reminderOverviewOrderState = stabilized.state
        return stabilized.items
    }

    nonisolated private static func loadReminderItemsInSystemOrder() async throws -> [ReminderItemInfo] {
        let store = EKEventStore()
        store.refreshSourcesIfNecessary()
        let predicate = store.predicateForReminders(in: nil)

        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).map { reminder in
                    ReminderItemInfo(
                        id: reminder.calendarItemIdentifier,
                        title: reminder.title,
                        notes: reminder.notes ?? "",
                        dueDate: reminder.dueDateComponents?.date,
                        listID: reminder.calendar.calendarIdentifier,
                        listTitle: reminder.calendar.title,
                        isCompleted: reminder.isCompleted
                    )
                }
                continuation.resume(returning: items)
            }
        }
    }

}

extension AppModel {
    static var previewFinished: AppModel {
        let model = AppModel()
        model.onboardingState.hasEnteredChat = true
        model.reminderLists = [
            ReminderListInfo(id: "1", title: "收集箱"),
            ReminderListInfo(id: "2", title: "项目"),
            ReminderListInfo(id: "3", title: "下一步行动")
        ]
        model.reminderItems = [
            ReminderItemInfo(id: "r1", title: "跟进合作邮件", notes: "确认本周是否推进", dueDate: .now, listTitle: "收集箱", isCompleted: false),
            ReminderItemInfo(id: "r2", title: "整理报销材料", notes: "", dueDate: nil, listTitle: "项目", isCompleted: false),
            ReminderItemInfo(id: "r3", title: "检查演示版本", notes: "", dueDate: .now.addingTimeInterval(-86_400), listTitle: "下一步行动", isCompleted: false),
            ReminderItemInfo(id: "r4", title: "归档旧记录", notes: "", dueDate: nil, listTitle: "收集箱", isCompleted: true)
        ]
        model.lastReminderSyncAt = .now
        model.pendingReminderFocusIdentifier = nil
        return model
    }
}

struct OnboardingState: Codable {
    var hasSeenWelcome = false
    var hasRequestedReminderPermission = false
    var hasConfiguredModel = false
    var hasSeenStarterTemplate = false
    var hasEnteredChat = false

    var isFinished: Bool {
        hasEnteredChat
    }
}
