@preconcurrency import EventKit
import Foundation

struct ReminderPermissionService {
    private let store = EKEventStore()

    func requestAccess() async -> Bool {
        if #available(iOS 17.0, *) {
            do {
                return try await store.requestFullAccessToReminders()
            } catch {
                return false
            }
        } else {
            return await withCheckedContinuation { continuation in
                store.requestAccess(to: .reminder) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}

struct ReminderListInfo: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

struct ReminderItemInfo: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let notes: String
    let dueDate: Date?
    let listTitle: String
    let isCompleted: Bool
}

struct ReminderCreateInput: Sendable {
    let title: String
    let notes: String
    let dueDate: Date?
    let preferredListName: String?
}

private struct ReminderLookupCandidate: Sendable {
    let identifier: String
    let normalizedTitle: String
    let displayTitle: String
}

enum ReminderStoreError: LocalizedError {
    case permissionNotGranted
    case sourceUnavailable
    case defaultCalendarUnavailable
    case reminderNotFound(String)
    case reminderAmbiguous(String, [String])
    case listNotFound(String)

    var errorDescription: String? {
        switch self {
        case .permissionNotGranted:
            return "提醒事项权限未开启。"
        case .sourceUnavailable:
            return "暂时找不到可用的提醒事项来源。"
        case .defaultCalendarUnavailable:
            return "暂时找不到可用的提醒事项列表来保存任务。"
        case let .reminderNotFound(target):
            return "没有找到匹配“\(target)”的提醒事项。"
        case let .reminderAmbiguous(target, candidates):
            let preview = candidates.prefix(3).joined(separator: "、")
            if candidates.count > 3 {
                return "找到了多个匹配“\(target)”的提醒事项：\(preview) 等。请说得更具体一点。"
            }
            return "找到了多个匹配“\(target)”的提醒事项：\(preview)。请说得更具体一点。"
        case let .listNotFound(target):
            return "没有找到目标列表“\(target)”。"
        }
    }
}

struct ReminderStoreService {
    func fetchReminderLists() throws -> [ReminderListInfo] {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .reminder)
        let hasAccess: Bool
        if #available(iOS 17.0, *) {
            hasAccess = status == .fullAccess || status == .writeOnly
        } else {
            hasAccess = status == .authorized
        }
        guard hasAccess else {
            throw ReminderStoreError.permissionNotGranted
        }

        store.refreshSourcesIfNecessary()
        return store.calendars(for: .reminder)
            .map { ReminderListInfo(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    func fetchReminderItems(limit: Int = 50) async throws -> [ReminderItemInfo] {
        let store = try authorizedStore()
        store.refreshSourcesIfNecessary()

        let predicate = store.predicateForReminders(in: nil)
        let items = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[ReminderItemInfo], Error>) in
            store.fetchReminders(matching: predicate) { reminders in
                let mapped = (reminders ?? []).map { reminder in
                    ReminderItemInfo(
                        id: reminder.calendarItemIdentifier,
                        title: reminder.title,
                        notes: reminder.notes ?? "",
                        dueDate: reminder.dueDateComponents?.date,
                        listTitle: reminder.calendar.title,
                        isCompleted: reminder.isCompleted
                    )
                }
                continuation.resume(returning: mapped)
            }
        }

        return items
            .sorted(by: reminderSort)
            .prefix(limit)
            .map { $0 }
    }

    @discardableResult
    func createLists(named titles: [String]) throws -> [ReminderListInfo] {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .reminder)
        let hasAccess: Bool
        if #available(iOS 17.0, *) {
            hasAccess = status == .fullAccess || status == .writeOnly
        } else {
            hasAccess = status == .authorized
        }
        guard hasAccess else {
            throw ReminderStoreError.permissionNotGranted
        }

        store.refreshSourcesIfNecessary()
        let existing = store.calendars(for: .reminder)
        let normalizedExisting = Set(existing.map { normalize($0.title) })
        let source = store.defaultCalendarForNewReminders()?.source
            ?? existing.first?.source
            ?? store.sources.first(where: { $0.sourceType != .subscribed })

        guard let source else {
            throw ReminderStoreError.sourceUnavailable
        }

        for title in titles where normalizedExisting.contains(normalize(title)) == false {
            let calendar = EKCalendar(for: .reminder, eventStore: store)
            calendar.title = title
            calendar.source = source
            try store.saveCalendar(calendar, commit: true)
        }

        return try fetchReminderLists()
    }

    @discardableResult
    func createReminder(input: ReminderCreateInput) throws -> String {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .reminder)
        let hasAccess: Bool
        if #available(iOS 17.0, *) {
            hasAccess = status == .fullAccess || status == .writeOnly
        } else {
            hasAccess = status == .authorized
        }
        guard hasAccess else {
            throw ReminderStoreError.permissionNotGranted
        }

        store.refreshSourcesIfNecessary()
        let calendars = store.calendars(for: .reminder)
        let calendar = resolveCalendar(
            preferredListName: input.preferredListName,
            calendars: calendars,
            store: store
        )

        guard let calendar else {
            throw ReminderStoreError.defaultCalendarUnavailable
        }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = input.title
        let trimmedNotes = input.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        reminder.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        if let dueDate = input.dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                in: .current,
                from: dueDate
            )
        }

        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    @discardableResult
    func moveReminder(targetText: String, destinationListName: String) async throws -> String {
        let store = try authorizedStore()
        store.refreshSourcesIfNecessary()

        let calendars = store.calendars(for: .reminder)
        guard let destination = calendars.first(where: { normalize($0.title) == normalize(destinationListName) }) else {
            throw ReminderStoreError.listNotFound(destinationListName)
        }

        guard let reminderID = try await findReminderIdentifier(matching: targetText, store: store),
              let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            throw ReminderStoreError.reminderNotFound(targetText)
        }

        reminder.calendar = destination
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    @discardableResult
    func completeReminder(targetText: String) async throws -> String {
        let store = try authorizedStore()
        store.refreshSourcesIfNecessary()

        guard let reminderID = try await findReminderIdentifier(matching: targetText, store: store),
              let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            throw ReminderStoreError.reminderNotFound(targetText)
        }

        reminder.isCompleted = true
        reminder.completionDate = Date()
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    private func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func authorizedStore() throws -> EKEventStore {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .reminder)
        let hasAccess: Bool
        if #available(iOS 17.0, *) {
            hasAccess = status == .fullAccess || status == .writeOnly
        } else {
            hasAccess = status == .authorized
        }
        guard hasAccess else {
            throw ReminderStoreError.permissionNotGranted
        }
        return store
    }

    private func findReminderIdentifier(
        matching targetText: String,
        store: EKEventStore
    ) async throws -> String? {
        let trimmed = normalizeQuery(targetText)
        guard trimmed.isEmpty == false, trimmed != "当前这条" else {
            return nil
        }

        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        let candidates = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[ReminderLookupCandidate], Error>) in
            store.fetchReminders(matching: predicate) { reminders in
                let mapped = (reminders ?? []).map { reminder in
                    ReminderLookupCandidate(
                        identifier: reminder.calendarItemIdentifier,
                        normalizedTitle: normalize(reminder.title),
                        displayTitle: reminder.title
                    )
                }
                continuation.resume(returning: mapped)
            }
        }

        let normalizedTarget = normalize(trimmed)
        let quotedTarget = quotedText(in: trimmed).map(normalize)

        if let quotedTarget,
           let exactQuoted = candidates.first(where: { $0.normalizedTitle == quotedTarget }) {
            return exactQuoted.identifier
        }

        if let exact = candidates.first(where: { $0.normalizedTitle == normalizedTarget }) {
            return exact.identifier
        }

        let containsMatches = candidates.filter { candidate in
            candidate.normalizedTitle.contains(normalizedTarget) || normalizedTarget.contains(candidate.normalizedTitle)
        }
        if containsMatches.count == 1 {
            return containsMatches[0].identifier
        }
        if containsMatches.count > 1 {
            throw ReminderStoreError.reminderAmbiguous(
                targetText,
                containsMatches.map(\.displayTitle)
            )
        }

        return nil
    }

    private func resolveCalendar(
        preferredListName: String?,
        calendars: [EKCalendar],
        store: EKEventStore
    ) -> EKCalendar? {
        if let preferredListName,
           let matched = calendars.first(where: { normalize($0.title) == normalize(preferredListName) }) {
            return matched
        }

        return store.defaultCalendarForNewReminders() ?? calendars.first
    }

    private func reminderSort(lhs: ReminderItemInfo, rhs: ReminderItemInfo) -> Bool {
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
        case ( _?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        if lhs.listTitle != rhs.listTitle {
            return lhs.listTitle.localizedCompare(rhs.listTitle) == .orderedAscending
        }
        return lhs.title.localizedCompare(rhs.title) == .orderedAscending
    }

    private func normalizeQuery(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "　", with: " ")
    }

    private func quotedText(in text: String) -> String? {
        let pairs: [(String, String)] = [("“", "”"), ("\"", "\""), ("‘", "’")]
        for pair in pairs {
            if let range = text.range(of: pair.0),
               let endRange = text[range.upperBound...].range(of: pair.1) {
                let value = String(text[range.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty == false {
                    return value
                }
            }
        }
        return nil
    }
}
