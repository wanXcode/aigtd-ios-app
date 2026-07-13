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

struct ReschedulePlanItem: Codable, Hashable, Sendable {
    let reminderID: String
    let title: String
    let listTitle: String
    let dueDateISO8601: String
}

struct ReschedulePlan: Codable, Hashable, Sendable {
    let scope: String
    let scopeLabel: String
    let strategy: String
    let ordering: String
    let windowDays: Int
    let startDateISO8601: String
    let endDateISO8601: String
    let items: [ReschedulePlanItem]
}

struct ReschedulePlanner {
    func makePlan(
        entities: [String: String],
        reminderItems: [ReminderItemInfo],
        now: Date = .now
    ) -> ReschedulePlan? {
        let openItems = reminderItems
            .filter { $0.isCompleted == false }
            .sorted(by: reminderSort)
        guard openItems.isEmpty == false else { return nil }

        let scope = nonEmptyValue(entities["scope"]) ?? "current_open_items"
        let scopeLabel = nonEmptyValue(entities["scope_label"]) ?? scopeLabel(for: scope)
        let sourceText = nonEmptyValue(entities["source_text"]) ?? ""
        let windowDays = inferredWindowDays(
            entityValue: entities["window_days"],
            sourceText: sourceText
        )
        let startDate = inferredStartDate(
            entityValue: entities["start_date"],
            sourceText: sourceText,
            now: now
        )
        let strategy = nonEmptyValue(entities["strategy"]) ?? "spread_within_window"
        let ordering = nonEmptyValue(entities["ordering"]) ?? "sequential"

        let selectedItems = selectItems(
            for: scope,
            target: nonEmptyValue(entities["target"]),
            from: openItems,
            now: now
        )
        guard selectedItems.isEmpty == false else { return nil }

        let offsets = dueDayOffsets(
            itemCount: selectedItems.count,
            windowDays: windowDays
        )
        let calendar = Calendar.current
        let formatter = ISO8601DateFormatter()
        let plannedItems = zip(selectedItems, offsets).compactMap { item, offset -> ReschedulePlanItem? in
            guard let dueDate = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }
            return ReschedulePlanItem(
                reminderID: item.id,
                title: item.title,
                listTitle: item.listTitle,
                dueDateISO8601: formatter.string(from: dueDate)
            )
        }
        guard plannedItems.isEmpty == false else { return nil }

        let endDate = calendar.date(byAdding: .day, value: max(windowDays - 1, 0), to: startDate) ?? startDate
        return ReschedulePlan(
            scope: scope,
            scopeLabel: scopeLabel,
            strategy: strategy,
            ordering: ordering,
            windowDays: windowDays,
            startDateISO8601: formatter.string(from: startDate),
            endDateISO8601: formatter.string(from: endDate),
            items: plannedItems
        )
    }

    private func selectItems(
        for scope: String,
        target: String?,
        from items: [ReminderItemInfo],
        now: Date
    ) -> [ReminderItemInfo] {
        if let target, target.isEmpty == false, isGenericReference(target) == false {
            let normalizedTarget = normalize(target)
            return items.filter { item in
                let normalizedTitle = normalize(item.title)
                return normalizedTitle == normalizedTarget ||
                    normalizedTitle.contains(normalizedTarget) ||
                    normalizedTarget.contains(normalizedTitle)
            }
        }

        if scope == "overdue_open_items" {
            return items.filter { item in
                guard let dueDate = item.dueDate else { return false }
                return dueDate < now
            }
        }

        if scope.hasPrefix("list:") {
            let listName = String(scope.dropFirst("list:".count))
            return items.filter { normalize($0.listTitle) == normalize(listName) }
        }

        return items
    }

    private func inferredWindowDays(entityValue: String?, sourceText: String) -> Int {
        if let entityValue,
           let days = Int(entityValue),
           days > 0 {
            return min(days, 30)
        }
        if sourceText.contains("2周") || sourceText.contains("两周") || sourceText.contains("二周") {
            return 14
        }
        if sourceText.contains("1周") || sourceText.contains("一周") || sourceText.contains("这周") {
            return 7
        }
        if let days = inferredDayCount(from: sourceText) {
            return min(days, 30)
        }
        return 14
    }

    private func inferredStartDate(entityValue: String?, sourceText: String, now: Date) -> Date {
        let formatter = ISO8601DateFormatter()
        if let entityValue,
           let parsed = formatter.date(from: entityValue) {
            return futureExecutionDate(for: parsed, now: now)
        }

        let calendar = Calendar.current
        let baseDate: Date
        if sourceText.contains("今天") && sourceText.contains("开始") {
            baseDate = now
        } else {
            baseDate = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        }
        return futureExecutionDate(for: baseDate, now: now)
    }

    private func futureExecutionDate(for date: Date, now: Date) -> Date {
        let normalized = normalizeToPreferredExecutionTime(date)
        guard normalized < now else { return normalized }
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
        return normalizeToPreferredExecutionTime(tomorrow)
    }

    private func normalizeToPreferredExecutionTime(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return calendar.date(
            from: DateComponents(
                timeZone: .current,
                year: components.year,
                month: components.month,
                day: components.day,
                hour: 9,
                minute: 0,
                second: 0
            )
        ) ?? date
    }

    private func dueDayOffsets(itemCount: Int, windowDays: Int) -> [Int] {
        guard itemCount > 0 else { return [] }
        if itemCount == 1 { return [0] }

        let maxOffset = max(windowDays - 1, 0)
        if maxOffset == 0 { return Array(repeating: 0, count: itemCount) }

        return (0..<itemCount).map { index in
            Int(round(Double(index) * Double(maxOffset) / Double(itemCount - 1)))
        }
    }

    private func scopeLabel(for scope: String) -> String {
        if scope == "overdue_open_items" {
            return "已过期事项"
        }
        if scope.hasPrefix("list:") {
            return String(scope.dropFirst("list:".count))
        }
        return "当前未完成事项"
    }

    private func inferredDayCount(from text: String) -> Int? {
        let pattern = #"(\d+)\s*天"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(String(text[range]))
    }

    private func reminderSort(lhs: ReminderItemInfo, rhs: ReminderItemInfo) -> Bool {
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

        if lhs.listTitle != rhs.listTitle {
            return lhs.listTitle.localizedCompare(rhs.listTitle) == .orderedAscending
        }
        return lhs.title.localizedCompare(rhs.title) == .orderedAscending
    }

    private func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func nonEmptyValue(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isGenericReference(_ text: String) -> Bool {
        let hints = ["当前这条", "这条", "那条", "这些", "这些任务", "当前未完成事项"]
        return hints.contains(where: { text.contains($0) })
    }
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

    @discardableResult
    func updateReminderCompletion(identifier: String, isCompleted: Bool) throws -> String {
        let store = try authorizedStore()
        store.refreshSourcesIfNecessary()

        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw ReminderStoreError.reminderNotFound(identifier)
        }

        reminder.isCompleted = isCompleted
        reminder.completionDate = isCompleted ? Date() : nil
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    @discardableResult
    func updateReminderDueDate(identifier: String, dueDate: Date?) throws -> String {
        let store = try authorizedStore()
        store.refreshSourcesIfNecessary()

        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw ReminderStoreError.reminderNotFound(identifier)
        }

        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                in: .current,
                from: dueDate
            )
        } else {
            reminder.dueDateComponents = nil
        }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    @discardableResult
    func updateReminderDueDate(targetText: String, dueDate: Date?) async throws -> String {
        let store = try authorizedStore()
        store.refreshSourcesIfNecessary()

        guard let reminderID = try await findReminderIdentifier(matching: targetText, store: store),
              let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            throw ReminderStoreError.reminderNotFound(targetText)
        }

        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                in: .current,
                from: dueDate
            )
        } else {
            reminder.dueDateComponents = nil
        }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    @discardableResult
    func deleteReminder(identifier: String) throws -> String {
        let store = try authorizedStore()
        store.refreshSourcesIfNecessary()

        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw ReminderStoreError.reminderNotFound(identifier)
        }

        try store.remove(reminder, commit: true)
        return identifier
    }

    @discardableResult
    func deleteReminder(targetText: String) async throws -> String {
        let store = try authorizedStore()
        store.refreshSourcesIfNecessary()

        guard let reminderID = try await findReminderIdentifier(matching: targetText, store: store),
              let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder else {
            throw ReminderStoreError.reminderNotFound(targetText)
        }

        try store.remove(reminder, commit: true)
        return reminderID
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
                    let title = reminder.title ?? "未命名任务"
                    let dueLabel = reminder.dueDateComponents
                        .flatMap { Calendar.current.date(from: $0) }
                        .map { $0.formatted(date: .abbreviated, time: .shortened) }
                    let context = [dueLabel, reminder.calendar?.title]
                        .compactMap { $0 }
                        .filter { $0.isEmpty == false }
                        .joined(separator: "，")
                    return ReminderLookupCandidate(
                        identifier: reminder.calendarItemIdentifier,
                        normalizedTitle: normalize(title),
                        displayTitle: context.isEmpty ? title : "\(title)（\(context)）"
                    )
                }
                continuation.resume(returning: mapped)
            }
        }

        let normalizedTarget = normalize(trimmed)
        let quotedTarget = quotedText(in: trimmed).map(normalize)

        if let quotedTarget {
            let exactQuoted = candidates.filter { $0.normalizedTitle == quotedTarget }
            if exactQuoted.count == 1 {
                return exactQuoted[0].identifier
            }
            if exactQuoted.count > 1 {
                throw ReminderStoreError.reminderAmbiguous(
                    targetText,
                    exactQuoted.map(\.displayTitle)
                )
            }
        }

        let exactMatches = candidates.filter { $0.normalizedTitle == normalizedTarget }
        if exactMatches.count == 1 {
            return exactMatches[0].identifier
        }
        if exactMatches.count > 1 {
            throw ReminderStoreError.reminderAmbiguous(
                targetText,
                exactMatches.map(\.displayTitle)
            )
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
