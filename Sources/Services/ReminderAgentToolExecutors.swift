@preconcurrency import EventKit
import Foundation

struct ReminderToolMutation: Sendable {
    var title: String?
    var notes: String?
    var dueDate: Date?
    var clearsDueDate: Bool
    var includesTime: Bool?

    init(
        title: String? = nil,
        notes: String? = nil,
        dueDate: Date? = nil,
        clearsDueDate: Bool = false,
        includesTime: Bool? = nil
    ) {
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.clearsDueDate = clearsDueDate
        self.includesTime = includesTime
    }
}

struct ReminderListCreationResult: Sendable {
    let id: String
    let title: String
    let created: Bool
}

protocol ReminderToolWriter: Sendable {
    var canWrite: Bool { get async }
    func create(title: String, notes: String?, dueDate: Date?, includesTime: Bool, listID: String?, listTitle: String?) async throws -> String
    func createList(title: String) async throws -> ReminderListCreationResult
    func update(id: String, mutation: ReminderToolMutation) async throws
    func move(id: String, listID: String?, listTitle: String?) async throws
    func setCompleted(id: String, isCompleted: Bool) async throws
    func delete(id: String) async throws
}

actor EventKitReminderToolWriter: ReminderToolWriter {
    var canWrite: Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        return status == .fullAccess || status == .writeOnly
    }

    func create(
        title: String,
        notes: String?,
        dueDate: Date?,
        includesTime: Bool,
        listID: String?,
        listTitle: String?
    ) throws -> String {
        let store = try writableStore()
        let calendars = store.calendars(for: .reminder)
        let calendar: EKCalendar?
        if let listID {
            calendar = calendars.first { $0.calendarIdentifier == listID }
        } else if let listTitle {
            let normalized = normalize(listTitle)
            calendar = calendars.first { normalize($0.title) == normalized }
        } else {
            calendar = store.defaultCalendarForNewReminders()
        }
        guard let calendar else { throw ReminderGatewayError.listNotFound(listID ?? listTitle ?? "") }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = notes
        reminder.dueDateComponents = dueComponents(dueDate, includesTime: includesTime)
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    func createList(title: String) throws -> ReminderListCreationResult {
        let store = try writableStore()
        let normalizedTitle = normalize(title)
        if let existing = store.calendars(for: .reminder).first(where: { normalize($0.title) == normalizedTitle }) {
            return ReminderListCreationResult(id: existing.calendarIdentifier, title: existing.title, created: false)
        }
        let calendars = store.calendars(for: .reminder)
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? calendars.first?.source
            ?? store.sources.first(where: { $0.sourceType != .subscribed }) else {
            throw ReminderGatewayError.storeUnavailable
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = title
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return ReminderListCreationResult(id: calendar.calendarIdentifier, title: title, created: true)
    }

    func update(id: String, mutation: ReminderToolMutation) throws {
        let store = try writableStore()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderGatewayError.reminderNotFound(id)
        }
        if let title = mutation.title { reminder.title = title }
        if let notes = mutation.notes { reminder.notes = notes.isEmpty ? nil : notes }
        if mutation.clearsDueDate {
            reminder.dueDateComponents = nil
        } else if let dueDate = mutation.dueDate {
            reminder.dueDateComponents = dueComponents(dueDate, includesTime: mutation.includesTime ?? true)
        }
        try store.save(reminder, commit: true)
    }

    func move(id: String, listID: String?, listTitle: String?) throws {
        let store = try writableStore()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderGatewayError.reminderNotFound(id)
        }
        let calendars = store.calendars(for: .reminder)
        let destination: EKCalendar?
        if let listID {
            destination = calendars.first { $0.calendarIdentifier == listID }
        } else if let listTitle {
            let normalized = normalize(listTitle)
            destination = calendars.first { normalize($0.title) == normalized }
        } else {
            destination = nil
        }
        guard let destination else { throw ReminderGatewayError.listNotFound(listID ?? listTitle ?? "") }
        reminder.calendar = destination
        try store.save(reminder, commit: true)
    }

    func setCompleted(id: String, isCompleted: Bool) throws {
        let store = try writableStore()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderGatewayError.reminderNotFound(id)
        }
        if reminder.isCompleted == isCompleted { return }
        reminder.isCompleted = isCompleted
        reminder.completionDate = isCompleted ? .now : nil
        try store.save(reminder, commit: true)
    }

    func delete(id: String) throws {
        let store = try writableStore()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ReminderGatewayError.reminderNotFound(id)
        }
        try store.remove(reminder, commit: true)
    }

    private func writableStore() throws -> EKEventStore {
        guard canWrite else { throw ReminderGatewayError.writeNotAuthorized }
        let store = EKEventStore()
        store.refreshSourcesIfNecessary()
        return store
    }

    private func dueComponents(_ date: Date?, includesTime: Bool) -> DateComponents? {
        guard let date else { return nil }
        return includesTime
            ? Calendar.current.dateComponents(in: .current, from: date)
            : Calendar.current.dateComponents([.year, .month, .day], from: date)
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct ReminderAgentToolExecutor: AgentToolExecutor {
    let toolName: AgentToolName
    let riskLevel: AgentToolRiskLevel

    private let queryService: ReminderQueryService
    private let writer: any ReminderToolWriter
    private let ledger: AgentToolExecutionLedger
    private let schedulePlanStore: AgentSchedulePlanStore

    init(
        toolName: AgentToolName,
        queryService: ReminderQueryService,
        writer: any ReminderToolWriter,
        ledger: AgentToolExecutionLedger,
        schedulePlanStore: AgentSchedulePlanStore = .shared
    ) {
        self.toolName = toolName
        self.riskLevel = Self.risk(for: toolName)
        self.queryService = queryService
        self.writer = writer
        self.ledger = ledger
        self.schedulePlanStore = schedulePlanStore
    }

    static func standardExecutors(
        gateway: any ReminderStoreGateway = EventKitReminderStoreGateway(),
        writer: any ReminderToolWriter = EventKitReminderToolWriter(),
        ledger: AgentToolExecutionLedger = .shared,
        schedulePlanStore: AgentSchedulePlanStore = .shared
    ) -> [ReminderAgentToolExecutor] {
        let query = ReminderQueryService(gateway: gateway)
        return [
            .searchReminders, .getReminderDetails, .createList, .createReminder, .updateReminder,
            .moveReminder, .completeReminder, .deleteReminder, .proposeSchedule, .applySchedule
        ].map {
            Self(
                toolName: $0,
                queryService: query,
                writer: writer,
                ledger: ledger,
                schedulePlanStore: schedulePlanStore
            )
        }
    }

    func execute(
        arguments: AgentToolArguments,
        runID: UUID,
        callID: String
    ) async throws -> AgentToolExecutionOutput {
        if let replay = ledger.replay(runID: runID.uuidString, callID: callID) {
            return try replayOutput(replay.result)
        }

        let output: AgentToolExecutionOutput
        switch toolName {
        case .searchReminders:
            output = try await search(arguments)
        case .getReminderDetails:
            output = try await details(arguments)
        case .createReminder:
            output = try await create(arguments)
        case .createList:
            output = try await createList(arguments)
        case .updateReminder:
            output = try await update(arguments)
        case .moveReminder:
            output = try await move(arguments)
        case .completeReminder:
            output = try await complete(arguments)
        case .deleteReminder:
            output = try await delete(arguments)
        case .proposeSchedule:
            output = try await proposeSchedule(arguments, runID: runID)
        case .applySchedule:
            output = try await applySchedule(arguments, runID: runID)
        default:
            throw AgentToolError(category: .unknownTool, userVisibleMessage: "不支持该工具。")
        }

        let encoded = try JSONEncoder().encode(output.result)
        let replayStatus: AgentToolExecutionReplayStatus
        switch output.status {
        case .unchanged: replayStatus = .unchanged
        case .alreadyApplied: replayStatus = .alreadyApplied
        default: replayStatus = .success
        }
        ledger.record(
            runID: runID.uuidString,
            callID: callID,
            result: AgentToolExecutionResult(status: replayStatus, resultJSON: String(decoding: encoded, as: UTF8.self))
        )
        return output
    }

    private func search(_ arguments: AgentToolArguments) async throws -> AgentToolExecutionOutput {
        let request = ReminderSearchRequest(
            query: arguments.string("query"),
            listID: arguments.string("list_id"),
            listTitle: arguments.string("list_title"),
            dateFrom: try arguments.date("date_from"),
            dateTo: try arguments.date("date_to"),
            includeCompleted: arguments.bool("include_completed") ?? false,
            limit: arguments.integer("limit") ?? 50
        )
        let privacy = ReminderQueryPrivacy(
            allowsNotes: arguments.bool("allow_notes") ?? false,
            allowsCompletedReminders: arguments.bool("allow_completed") ?? false
        )
        return .init(result: .init(["items": .array(try await queryService.search(request, privacy: privacy).map(json))]))
    }

    private func details(_ arguments: AgentToolArguments) async throws -> AgentToolExecutionOutput {
        let ids = try arguments.requiredStrings("reminder_ids")
        let privacy = ReminderQueryPrivacy(
            allowsNotes: arguments.bool("allow_notes") ?? false,
            allowsCompletedReminders: arguments.bool("allow_completed") ?? false
        )
        let records = try await queryService.details(forIDs: ids, privacy: privacy)
        guard records.count == ids.count else { throw toolError(.notFound, "没有找到指定任务。") }
        return .init(result: .init(["items": .array(records.map(json))]))
    }

    private func create(_ arguments: AgentToolArguments) async throws -> AgentToolExecutionOutput {
        try await requireWriteAccess()
        let title = try arguments.requiredString("title")
        let dueDate = try arguments.date("due_date")
        let id = try await writer.create(
            title: title,
            notes: arguments.string("notes"),
            dueDate: dueDate,
            includesTime: arguments.bool("includes_time") ?? (dueDate != nil),
            listID: arguments.string("list_id"),
            listTitle: arguments.string("list_title")
        )
        return .init(result: .init(["reminder_id": .string(id), "title": .string(title)]))
    }

    private func createList(_ arguments: AgentToolArguments) async throws -> AgentToolExecutionOutput {
        try await requireWriteAccess()
        let title = try arguments.requiredString("title")
        let creation = try await writer.createList(title: title)
        return .init(
            status: creation.created ? .success : .unchanged,
            result: .init([
                "list_id": .string(creation.id),
                "title": .string(creation.title)
            ])
        )
    }

    private func update(_ arguments: AgentToolArguments) async throws -> AgentToolExecutionOutput {
        let id = try arguments.requiredString("reminder_id")
        let current = try await checkedRecord(id: id, arguments: arguments)
        let mutation = ReminderToolMutation(
            title: arguments.string("title"),
            notes: arguments.string("notes"),
            dueDate: try arguments.date("due_date"),
            clearsDueDate: arguments.bool("clear_due_date") ?? false,
            includesTime: arguments.bool("includes_time")
        )
        guard mutation.title != nil || mutation.notes != nil || mutation.dueDate != nil || mutation.clearsDueDate else {
            throw toolError(.invalidArguments, "没有提供要修改的字段。")
        }
        if isUnchanged(current, mutation: mutation) {
            return .init(status: .unchanged, result: .init(["reminder_id": .string(id)]))
        }
        try await writer.update(id: id, mutation: mutation)
        return .init(result: .init(["reminder_id": .string(id)]))
    }

    private func move(_ arguments: AgentToolArguments) async throws -> AgentToolExecutionOutput {
        let id = try arguments.requiredString("reminder_id")
        let current = try await checkedRecord(id: id, arguments: arguments)
        let listID = arguments.string("list_id")
        let listTitle = arguments.string("list_title")
        guard listID != nil || listTitle != nil else { throw toolError(.invalidArguments, "缺少目标清单。") }
        if listID == current.listID || (listID == nil && normalized(listTitle) == normalized(current.listTitle)) {
            return .init(status: .unchanged, result: .init(["reminder_id": .string(id)]))
        }
        try await writer.move(id: id, listID: listID, listTitle: listTitle)
        return .init(result: .init(["reminder_id": .string(id)]))
    }

    private func complete(_ arguments: AgentToolArguments) async throws -> AgentToolExecutionOutput {
        let id = try arguments.requiredString("reminder_id")
        let desired = arguments.bool("is_completed") ?? true
        let current = try await checkedRecord(id: id, arguments: arguments)
        if current.isCompleted == desired {
            return .init(status: .unchanged, result: .init(["reminder_id": .string(id), "is_completed": .bool(desired)]))
        }
        try await writer.setCompleted(id: id, isCompleted: desired)
        return .init(result: .init(["reminder_id": .string(id), "is_completed": .bool(desired)]))
    }

    private func delete(_ arguments: AgentToolArguments) async throws -> AgentToolExecutionOutput {
        guard arguments.bool("confirmed") == true else {
            throw toolError(.confirmationRequired, "删除任务前需要确认。")
        }
        let id = try arguments.requiredString("reminder_id")
        _ = try await checkedRecord(id: id, arguments: arguments)
        try await writer.delete(id: id)
        return .init(result: .init(["reminder_id": .string(id)]))
    }

    private func proposeSchedule(
        _ arguments: AgentToolArguments,
        runID: UUID
    ) async throws -> AgentToolExecutionOutput {
        let rawItems = try arguments.requiredObjects("items")
        guard rawItems.count <= 50 else {
            throw toolError(.invalidArguments, "单个排期方案最多包含 50 个任务。")
        }

        var items: [AgentSchedulePlanItem] = []
        for (index, itemArguments) in rawItems.enumerated() {
            let reminderID = try itemArguments.requiredString("reminder_id")
            let records = try await queryService.details(
                forIDs: [reminderID],
                privacy: ReminderQueryPrivacy(allowsNotes: false, allowsCompletedReminders: true)
            )
            guard let current = records.first else {
                throw toolError(.notFound, "排期中的任务不存在，请重新生成方案。")
            }
            guard current.isCompleted != true else {
                throw toolError(.preconditionConflict, "已完成任务不能加入新的排期方案。")
            }
            let target = try itemArguments.requiredDate("target_due_date")
            items.append(
                AgentSchedulePlanItem(
                    id: itemArguments.string("item_id") ?? "item-\(index + 1)",
                    reminderID: reminderID,
                    title: current.title,
                    originalDueDate: current.dueDate,
                    targetDueDate: target,
                    includesTime: itemArguments.bool("includes_time") ?? current.includesTime,
                    dependencyIDs: itemArguments.strings("dependency_ids") ?? []
                )
            )
        }

        let plan = try schedulePlanStore.create(runID: runID, items: items)
        return .init(result: scheduleResult(plan))
    }

    private func applySchedule(
        _ arguments: AgentToolArguments,
        runID: UUID
    ) async throws -> AgentToolExecutionOutput {
        guard arguments.bool("confirmed") == true else {
            throw toolError(.confirmationRequired, "执行排期方案前需要确认。")
        }
        try await requireWriteAccess()
        guard let planID = UUID(uuidString: try arguments.requiredString("plan_id")) else {
            throw toolError(.invalidArguments, "plan_id 不是有效的 UUID。")
        }
        var plan = try schedulePlanStore.load(id: planID, runID: runID)
        if plan.status == .succeeded {
            return .init(status: .alreadyApplied, result: scheduleResult(plan))
        }
        plan = try schedulePlanStore.markExecuting(id: planID)

        for item in plan.items where item.status != .applied && item.status != .unchanged {
            try Task.checkCancellation()
            let currentPlan = try schedulePlanStore.load(id: planID, runID: runID)
            let blockedDependencies = item.dependencyIDs.filter { dependencyID in
                guard let dependency = currentPlan.items.first(where: { $0.id == dependencyID }) else { return true }
                return dependency.status != .applied && dependency.status != .unchanged
            }
            if blockedDependencies.isEmpty == false {
                plan = try schedulePlanStore.record(planID: planID, itemID: item.id, status: .skipped)
                continue
            }

            do {
                let records = try await queryService.details(
                    forIDs: [item.reminderID],
                    privacy: ReminderQueryPrivacy(allowsNotes: false, allowsCompletedReminders: true)
                )
                guard let current = records.first else {
                    throw toolError(.notFound, "任务已不存在。")
                }
                guard sameMinute(item.originalDueDate, current.dueDate) else {
                    throw toolError(.preconditionConflict, "任务时间已被修改，已跳过该项。")
                }
                if sameMinute(item.targetDueDate, current.dueDate), item.includesTime == current.includesTime {
                    plan = try schedulePlanStore.record(planID: planID, itemID: item.id, status: .unchanged)
                } else {
                    try await writer.update(
                        id: item.reminderID,
                        mutation: ReminderToolMutation(dueDate: item.targetDueDate, includesTime: item.includesTime)
                    )
                    plan = try schedulePlanStore.record(planID: planID, itemID: item.id, status: .applied)
                }
            } catch is CancellationError {
                _ = try? schedulePlanStore.record(planID: planID, itemID: item.id, status: .cancelled)
                throw CancellationError()
            } catch let error as AgentToolError {
                plan = try schedulePlanStore.record(
                    planID: planID,
                    itemID: item.id,
                    status: .failed,
                    error: error
                )
            } catch {
                plan = try schedulePlanStore.record(
                    planID: planID,
                    itemID: item.id,
                    status: .failed,
                    error: toolError(.eventKitError, "任务写入失败。")
                )
            }
        }

        let outputStatus: AgentToolExecutionStatus = switch plan.status {
        case .succeeded: .success
        case .partial: .success
        case .cancelled: .cancelled
        default: .failed
        }
        return .init(status: outputStatus, result: scheduleResult(plan))
    }

    private func scheduleResult(_ plan: AgentSchedulePlan) -> AgentToolArguments {
        let formatter = ISO8601DateFormatter()
        let items = plan.items.map { item -> AgentJSONValue in
            var value: [String: AgentJSONValue] = [
                "item_id": .string(item.id),
                "reminder_id": .string(item.reminderID),
                "target_due_date": .string(formatter.string(from: item.targetDueDate)),
                "includes_time": .bool(item.includesTime),
                "status": .string(item.status.rawValue)
            ]
            if let title = item.title {
                value["title"] = .string(title)
            }
            if let original = item.originalDueDate {
                value["original_due_date"] = .string(formatter.string(from: original))
            }
            if let category = item.errorCategory { value["error_category"] = .string(category.rawValue) }
            if let message = item.userVisibleError { value["error_message"] = .string(message) }
            return .object(value)
        }
        return AgentToolArguments([
            "plan_id": .string(plan.id.uuidString),
            "plan_status": .string(plan.status.rawValue),
            "successful_count": .integer(plan.successfulCount),
            "failed_count": .integer(plan.failedCount),
            "items": .array(items)
        ])
    }

    private func checkedRecord(id: String, arguments: AgentToolArguments) async throws -> ReminderQueryResult {
        try await requireWriteAccess()
        let records = try await queryService.details(
            forIDs: [id],
            privacy: ReminderQueryPrivacy(allowsNotes: false, allowsCompletedReminders: true)
        )
        guard let record = records.first else { throw toolError(.notFound, "没有找到指定任务。") }
        let expected = ReminderWritePreconditions(
            expectedListID: arguments.string("expected_list_id"),
            expectedDueDate: try arguments.date("expected_due_date"),
            expectedCompletion: arguments.bool("expected_completion"),
            mustExist: arguments.bool("must_exist") ?? true
        )
        let storeRecord = ReminderStoreRecord(
            id: record.id,
            title: record.title,
            notes: record.notes,
            dueDate: record.dueDate,
            includesTime: record.includesTime,
            listID: record.listID,
            listTitle: record.listTitle,
            isCompleted: record.isCompleted ?? false,
            lastModifiedAt: record.lastModifiedAt
        )
        guard expected.conflicts(with: storeRecord).isEmpty else {
            throw toolError(.preconditionConflict, "任务已发生变化，请重新确认后再操作。")
        }
        return record
    }

    private func requireWriteAccess() async throws {
        guard await writer.canWrite else { throw toolError(.permissionDenied, "没有 Reminders 写入权限。") }
    }

    private func replayOutput(_ result: AgentToolExecutionResult) throws -> AgentToolExecutionOutput {
        let arguments: AgentToolArguments
        if let json = result.resultJSON, let data = json.data(using: .utf8) {
            arguments = (try? JSONDecoder().decode(AgentToolArguments.self, from: data)) ?? .init()
        } else {
            arguments = .init()
        }
        let status: AgentToolExecutionStatus
        switch result.status {
        case .unchanged:
            status = .unchanged
        case .success:
            status = riskLevel == .readOnly ? .success : .alreadyApplied
        case .alreadyApplied:
            status = .alreadyApplied
        }
        return .init(status: status, result: arguments)
    }

    private func json(_ record: ReminderQueryResult) -> AgentJSONValue {
        var value: [String: AgentJSONValue] = [
            "reminder_id": .string(record.id),
            "title": .string(record.title),
            "includes_time": .bool(record.includesTime),
            "list_id": .string(record.listID),
            "list_title": .string(record.listTitle)
        ]
        if let notes = record.notes { value["notes"] = .string(notes) }
        if let dueDate = record.dueDate { value["due_date"] = .string(ISO8601DateFormatter().string(from: dueDate)) }
        if let isCompleted = record.isCompleted { value["is_completed"] = .bool(isCompleted) }
        return .object(value)
    }

    private func isUnchanged(_ current: ReminderQueryResult, mutation: ReminderToolMutation) -> Bool {
        if let title = mutation.title, title != current.title { return false }
        if mutation.clearsDueDate, current.dueDate != nil { return false }
        if let date = mutation.dueDate,
           current.dueDate.map({ Calendar.current.isDate($0, equalTo: date, toGranularity: .minute) }) != true { return false }
        if let includesTime = mutation.includesTime, includesTime != current.includesTime { return false }
        return mutation.notes == nil
    }

    private func sameMinute(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (left?, right?): Calendar.current.isDate(left, equalTo: right, toGranularity: .minute)
        default: false
        }
    }

    private func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func toolError(_ category: AgentToolErrorCategory, _ message: String) -> AgentToolError {
        AgentToolError(category: category, userVisibleMessage: message)
    }

    private static func risk(for tool: AgentToolName) -> AgentToolRiskLevel {
        switch tool {
        case .searchReminders, .getReminderDetails, .proposeSchedule: return .readOnly
        case .createReminder, .updateReminder, .moveReminder, .completeReminder: return .lowRiskWrite
        case .createList, .applySchedule: return .mediumRiskWrite
        case .deleteReminder: return .highRiskWrite
        default: return .highRiskWrite
        }
    }
}

private extension AgentToolArguments {
    func string(_ key: String) -> String? {
        guard case let .string(value)? = self[key] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func bool(_ key: String) -> Bool? {
        guard case let .bool(value)? = self[key] else { return nil }
        return value
    }

    func integer(_ key: String) -> Int? {
        guard case let .integer(value)? = self[key] else { return nil }
        return value
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else {
            throw AgentToolError(category: .invalidArguments, userVisibleMessage: "缺少参数：\(key)。")
        }
        return value
    }

    func requiredStrings(_ key: String) throws -> [String] {
        guard case let .array(values)? = self[key] else {
            throw AgentToolError(category: .invalidArguments, userVisibleMessage: "缺少参数：\(key)。")
        }
        let strings = values.compactMap { value -> String? in
            guard case let .string(string) = value else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard strings.count == values.count, strings.isEmpty == false else {
            throw AgentToolError(category: .invalidArguments, userVisibleMessage: "参数 \(key) 必须是非空字符串数组。")
        }
        return strings
    }

    func strings(_ key: String) -> [String]? {
        guard case let .array(values)? = self[key] else { return nil }
        let strings = values.compactMap { value -> String? in
            guard case let .string(string) = value else { return nil }
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return strings.count == values.count ? strings : nil
    }

    func requiredObjects(_ key: String) throws -> [AgentToolArguments] {
        guard case let .array(values)? = self[key] else {
            throw AgentToolError(category: .invalidArguments, userVisibleMessage: "缺少参数：\(key)。")
        }
        let objects = values.compactMap { value -> AgentToolArguments? in
            guard case let .object(object) = value else { return nil }
            return AgentToolArguments(object)
        }
        guard objects.count == values.count, objects.isEmpty == false else {
            throw AgentToolError(category: .invalidArguments, userVisibleMessage: "参数 \(key) 必须是非空对象数组。")
        }
        return objects
    }

    func date(_ key: String) throws -> Date? {
        guard let value = self[key] else { return nil }
        guard case let .string(string) = value,
              let date = ISO8601DateFormatter().date(from: string) else {
            throw AgentToolError(category: .invalidArguments, userVisibleMessage: "参数 \(key) 不是有效的 ISO 8601 日期。")
        }
        return date
    }

    func requiredDate(_ key: String) throws -> Date {
        guard let date = try date(key) else {
            throw AgentToolError(category: .invalidArguments, userVisibleMessage: "缺少参数：\(key)。")
        }
        return date
    }
}
