import EventKit
import Foundation
import Observation

enum AppTab: Hashable {
    case chat
    case reminders
    case agent
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
    var reminderPermissionStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    let starterLists = ["收集箱", "项目", "下一步行动", "等待中", "也许以后"]
    var reminderLists: [ReminderListInfo] = []
    var reminderItems: [ReminderItemInfo] = []
    var reminderListsErrorMessage = ""
    var isLoadingReminderLists = false
    var lastReminderSyncAt: Date?
    var pendingReminderFocusIdentifier: String?
    private var hasBootstrappedAfterLaunch = false

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
        let grouped = Dictionary(grouping: reminderItems, by: \.listTitle)
        let listOrder = Dictionary(uniqueKeysWithValues: reminderLists.enumerated().map { ($0.element.title, $0.offset) })

        return grouped
            .map { key, value in
                let items = value.sorted(by: reminderItemSort)
                return (listTitle: key, items: items)
            }
            .sorted { lhs, rhs in
                let leftOrder = listOrder[lhs.listTitle] ?? .max
                let rightOrder = listOrder[rhs.listTitle] ?? .max
                if leftOrder != rightOrder {
                    return leftOrder < rightOrder
                }
                return lhs.listTitle.localizedCompare(rhs.listTitle) == .orderedAscending
            }
    }

    func bootstrapAfterLaunch() async {
        guard hasBootstrappedAfterLaunch == false else { return }
        hasBootstrappedAfterLaunch = true
        await refreshReminderPermission()
    }

    func refreshReminderPermission() async {
        reminderPermissionStatus = EKEventStore.authorizationStatus(for: .reminder)
        guard remindersAccessGranted else {
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
            reminderLists = []
            reminderItems = []
            reminderListsErrorMessage = ""
            lastReminderSyncAt = nil
            return
        }

        isLoadingReminderLists = true
        defer { isLoadingReminderLists = false }

        do {
            reminderLists = try ReminderStoreService().fetchReminderLists()
            reminderItems = try await ReminderStoreService().fetchReminderItems()
            reminderListsErrorMessage = ""
            lastReminderSyncAt = .now
        } catch {
            reminderLists = []
            reminderItems = []
            reminderListsErrorMessage = error.localizedDescription
        }
    }

    func createStarterTemplate() async -> Bool {
        guard remindersAccessGranted else { return false }
        isLoadingReminderLists = true
        defer { isLoadingReminderLists = false }

        do {
            reminderLists = try ReminderStoreService().createLists(named: starterLists)
            reminderItems = try await ReminderStoreService().fetchReminderItems()
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
            reminderItems = try await ReminderStoreService().fetchReminderItems()
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
            reminderItems = try await ReminderStoreService().fetchReminderItems()
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
            reminderItems = try await ReminderStoreService().fetchReminderItems()
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
        shouldResumeChatComposer = true
        selectedTab = .chat
    }

    func consumePendingChatDraft() -> String {
        let draft = pendingChatDraftAfterModelSetup
        pendingChatDraftAfterModelSetup = ""
        return draft
    }

    func clearPendingChatDraft() {
        pendingChatDraftAfterModelSetup = ""
        shouldResumeChatComposer = false
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

    private func reminderItemSort(lhs: ReminderItemInfo, rhs: ReminderItemInfo) -> Bool {
        switch (lhs.isCompleted, rhs.isCompleted) {
        case (false, true):
            return true
        case (true, false):
            return false
        default:
            break
        }

        switch (lhs.dueDate, rhs.dueDate) {
        case let (left?, right?):
            if left != right { return left < right }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        return lhs.title.localizedCompare(rhs.title) == .orderedAscending
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
