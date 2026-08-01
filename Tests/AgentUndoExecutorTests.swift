import Foundation
import XCTest
@testable import AIGTDReminders

final class AgentUndoExecutorTests: XCTestCase {
    func testActionCardCopyUsesTerminalUndoStatusInsteadOfPendingCopy() {
        XCTAssertEqual(AgentActionCardStatusCopy.title(for: "undone"), "已恢复")
        XCTAssertEqual(AgentActionCardStatusCopy.title(for: "undo_conflict"), "没有覆盖外部修改")
        XCTAssertEqual(AgentActionCardStatusCopy.title(for: "undo_partial"), "部分恢复")
        XCTAssertEqual(AgentActionCardStatusCopy.title(for: "undo_failed"), "未能恢复")
        XCTAssertEqual(
            AgentActionCardStatusCopy.subtitle(for: "undone", errorMessage: ""),
            "已经恢复到这次操作之前的状态"
        )
    }

    func testExecutesOperationsInStoreInverseOrder() async throws {
        let fixture = try makeFixture(operations: [
            createOperation(id: "created", callID: "first"),
            moveOperation(id: "moved", callID: "second"),
            completionOperation(id: "completed", callID: "third")
        ], records: [
            makeReminderRecord(id: "created"),
            makeReminderRecord(id: "moved", listID: "project"),
            makeReminderRecord(id: "completed", isCompleted: true)
        ])

        _ = try await fixture.executor.execute(recordID: fixture.recordID)

        let events = await fixture.state.events
        XCTAssertEqual(events, [
            "complete:completed:false",
            "move:moved:inbox",
            "delete:created"
        ])
    }

    func testRemovesCreatedReminderWhenStillUnchanged() async throws {
        let fixture = try makeFixture(
            operations: [createOperation(id: "created")],
            records: [makeReminderRecord(id: "created")]
        )

        let result = try await fixture.executor.execute(recordID: fixture.recordID)
        let created = await fixture.state.value(id: "created")

        XCTAssertEqual(result.record.status, .undone)
        XCTAssertNil(created)
    }

    func testRestoresTitleNotesAndDueDate() async throws {
        let oldDate = date(9, 0)
        let newDate = date(11, 0)
        let changes = [
            AgentUndoFieldChange(field: .title, originalValue: .string("Old"), forwardValue: .string("New")),
            AgentUndoFieldChange(field: .notes, originalValue: .none, forwardValue: .string("Forward note")),
            AgentUndoFieldChange(field: .dueDate, originalValue: .date(oldDate), forwardValue: .date(newDate))
        ]
        let fixture = try makeFixture(
            operations: [fieldsOperation(id: "task", changes: changes)],
            records: [makeReminderRecord(id: "task", title: "New", notes: "Forward note", dueDate: newDate)]
        )

        let result = try await fixture.executor.execute(recordID: fixture.recordID)
        let restored = await fixture.state.value(id: "task")

        XCTAssertEqual(result.record.status, .undone)
        XCTAssertEqual(restored?.title, "Old")
        XCTAssertNil(restored?.notes)
        XCTAssertEqual(restored?.dueDate, oldDate)
    }

    func testRestoresClearedDueDate() async throws {
        let forwardDate = date(10, 0)
        let fixture = try makeFixture(
            operations: [fieldsOperation(id: "task", changes: [
                AgentUndoFieldChange(field: .dueDate, originalValue: .none, forwardValue: .date(forwardDate))
            ])],
            records: [makeReminderRecord(id: "task", dueDate: forwardDate)]
        )

        _ = try await fixture.executor.execute(recordID: fixture.recordID)
        let restored = await fixture.state.value(id: "task")

        XCTAssertNil(restored?.dueDate)
    }

    func testDueDateComparisonUsesMinuteGranularity() async throws {
        let forwardDate = date(10, 0).addingTimeInterval(42)
        let fixture = try makeFixture(
            operations: [fieldsOperation(id: "task", changes: [
                AgentUndoFieldChange(field: .dueDate, originalValue: .none, forwardValue: .date(date(10, 0)))
            ])],
            records: [makeReminderRecord(id: "task", dueDate: forwardDate)]
        )

        let result = try await fixture.executor.execute(recordID: fixture.recordID)

        XCTAssertEqual(result.outcomes.first?.status, .undone)
    }

    func testRestoresIncludesTimeTogetherWithDueDate() async throws {
        let oldDate = date(0, 0)
        let forwardDate = date(10, 0)
        let fixture = try makeFixture(
            operations: [fieldsOperation(id: "task", changes: [
                AgentUndoFieldChange(field: .dueDate, originalValue: .date(oldDate), forwardValue: .date(forwardDate)),
                AgentUndoFieldChange(field: .includesTime, originalValue: .bool(false), forwardValue: .bool(true))
            ])],
            records: [makeReminderRecord(id: "task", dueDate: forwardDate, includesTime: true)]
        )

        _ = try await fixture.executor.execute(recordID: fixture.recordID)
        let restored = await fixture.state.value(id: "task")

        XCTAssertEqual(restored?.dueDate, oldDate)
        XCTAssertEqual(restored?.includesTime, false)
    }

    func testRestoresOriginalList() async throws {
        let fixture = try makeFixture(
            operations: [moveOperation(id: "task")],
            records: [makeReminderRecord(id: "task", listID: "project")]
        )

        _ = try await fixture.executor.execute(recordID: fixture.recordID)
        let restored = await fixture.state.value(id: "task")

        XCTAssertEqual(restored?.listID, "inbox")
    }

    func testRestoresOriginalCompletionState() async throws {
        let fixture = try makeFixture(
            operations: [completionOperation(id: "task")],
            records: [makeReminderRecord(id: "task", isCompleted: true)]
        )

        _ = try await fixture.executor.execute(recordID: fixture.recordID)
        let restored = await fixture.state.value(id: "task")

        XCTAssertEqual(restored?.isCompleted, false)
    }

    func testMissingTaskRecordsConflictWithoutWriting() async throws {
        let fixture = try makeFixture(operations: [moveOperation(id: "missing")], records: [])

        let result = try await fixture.executor.execute(recordID: fixture.recordID)
        let events = await fixture.state.events

        XCTAssertEqual(result.record.status, .conflict)
        XCTAssertEqual(result.outcomes.first?.reason, .taskMissing)
        XCTAssertTrue(events.isEmpty)
    }

    func testChangedFieldRecordsConflictWithoutOverwriting() async throws {
        let fixture = try makeFixture(
            operations: [fieldsOperation(id: "task", changes: [
                AgentUndoFieldChange(field: .title, originalValue: .string("Old"), forwardValue: .string("Forward"))
            ])],
            records: [makeReminderRecord(id: "task", title: "External edit")]
        )

        let result = try await fixture.executor.execute(recordID: fixture.recordID)
        let current = await fixture.state.value(id: "task")

        XCTAssertEqual(result.outcomes.first, AgentUndoOperationOutcome(
            operationID: result.outcomes[0].operationID,
            status: .conflict,
            reason: .taskChanged
        ))
        XCTAssertEqual(current?.title, "External edit")
    }

    func testChangedListRecordsConflict() async throws {
        let fixture = try makeFixture(
            operations: [moveOperation(id: "task")],
            records: [makeReminderRecord(id: "task", listID: "external")]
        )

        let result = try await fixture.executor.execute(recordID: fixture.recordID)

        XCTAssertEqual(result.outcomes.first?.status, .conflict)
        XCTAssertEqual(result.outcomes.first?.reason, .taskChanged)
    }

    func testChangedCompletionRecordsConflict() async throws {
        let fixture = try makeFixture(
            operations: [completionOperation(id: "task")],
            records: [makeReminderRecord(id: "task", isCompleted: false)]
        )

        let result = try await fixture.executor.execute(recordID: fixture.recordID)

        XCTAssertEqual(result.outcomes.first?.status, .conflict)
        XCTAssertEqual(result.outcomes.first?.reason, .taskChanged)
    }

    func testChangedNotesRecordsConflictWithoutDeletingCreatedReminder() async throws {
        let snapshot = AgentUndoTaskVersion(
            reminderID: "created",
            notesDigest: AgentUndoNotesDigest.digest("original")
        )
        let fixture = try makeFixture(
            operations: [AgentUndoOperation(
                forwardCallID: "create",
                inverseOperation: .removeCreatedReminder(taskVersion: snapshot)
            )],
            records: [makeReminderRecord(id: "created", notes: "changed later")]
        )

        let result = try await fixture.executor.execute(recordID: fixture.recordID)
        let events = await fixture.state.events

        XCTAssertEqual(result.outcomes.first?.status, .conflict)
        XCTAssertTrue(events.isEmpty)
    }

    func testSmallLastModifiedPrecisionDifferenceDoesNotConflict() async throws {
        let fixture = try makeFixture(
            operations: [createOperation(id: "task")],
            records: [makeReminderRecord(id: "task", lastModifiedAt: snapshotDate.addingTimeInterval(45))]
        )

        let result = try await fixture.executor.execute(recordID: fixture.recordID)

        XCTAssertEqual(result.outcomes.first?.status, .undone)
    }

    func testClearlyNewerLastModifiedDateRecordsConflict() async throws {
        let fixture = try makeFixture(
            operations: [createOperation(id: "task")],
            records: [makeReminderRecord(id: "task", lastModifiedAt: snapshotDate.addingTimeInterval(61))]
        )

        let result = try await fixture.executor.execute(recordID: fixture.recordID)
        let current = await fixture.state.value(id: "task")

        XCTAssertEqual(result.outcomes.first?.status, .conflict)
        XCTAssertNotNil(current)
    }

    func testWriteFailureIsRecordedAndOtherOperationsContinue() async throws {
        let fixture = try makeFixture(
            operations: [
                createOperation(id: "first", callID: "create-first"),
                createOperation(id: "second", callID: "create-second")
            ],
            records: [makeReminderRecord(id: "first"), makeReminderRecord(id: "second")],
            failures: ["delete:second": .operationFailed]
        )

        let result = try await fixture.executor.execute(recordID: fixture.recordID)
        let first = await fixture.state.value(id: "first")
        let second = await fixture.state.value(id: "second")

        XCTAssertEqual(result.record.status, .partiallyFailed)
        XCTAssertEqual(result.outcomes.map(\.status), [.failed, .undone])
        XCTAssertNil(first)
        XCTAssertNotNil(second)
    }

    func testMissingOriginalListIsRecordedAsConflict() async throws {
        let fixture = try makeFixture(
            operations: [moveOperation(id: "task")],
            records: [makeReminderRecord(id: "task", listID: "project")],
            failures: ["move:task": .listNotFound("inbox")]
        )

        let result = try await fixture.executor.execute(recordID: fixture.recordID)

        XCTAssertEqual(result.outcomes.first?.status, .conflict)
        XCTAssertEqual(result.outcomes.first?.reason, .listMissing)
    }

    func testReadOrWritePermissionFailureIsRecordedAsFailed() async throws {
        let fixture = try makeFixture(
            operations: [createOperation(id: "task")],
            records: [makeReminderRecord(id: "task")],
            canWrite: false
        )

        let result = try await fixture.executor.execute(recordID: fixture.recordID)

        XCTAssertEqual(result.outcomes.first?.status, .failed)
        XCTAssertEqual(result.outcomes.first?.reason, .operationFailed)
    }

    func testExpiredRecordIsRejectedWithoutWrites() async throws {
        let clock = UndoExecutorClock()
        let fixture = try makeFixture(
            operations: [createOperation(id: "task")],
            records: [makeReminderRecord(id: "task")],
            clock: clock,
            availabilityInterval: 1
        )
        clock.now.addTimeInterval(2)

        do {
            _ = try await fixture.executor.execute(recordID: fixture.recordID)
            XCTFail("Expected expired record rejection")
        } catch {
            XCTAssertEqual(error as? AgentUndoRecordStoreError, .unavailable(.expired))
        }
        let events = await fixture.state.events
        XCTAssertTrue(events.isEmpty)
    }

    private func makeFixture(
        operations: [AgentUndoOperation],
        records: [ReminderStoreRecord],
        failures: [String: ReminderGatewayError] = [:],
        canRead: Bool = true,
        canWrite: Bool = true,
        clock: UndoExecutorClock = UndoExecutorClock(),
        availabilityInterval: TimeInterval = 600
    ) throws -> UndoExecutorFixture {
        let defaults = UserDefaults(suiteName: "AgentUndoExecutorTests.\(UUID().uuidString)")!
        let store = AgentUndoRecordStore(defaults: defaults, storageKey: "undo", now: { clock.now })
        let undoRecord = try store.record(
            forwardRunID: UUID(),
            successfulOperations: operations,
            availabilityInterval: availabilityInterval
        )
        let state = UndoReminderState(records: records, failures: failures)
        return UndoExecutorFixture(
            executor: AgentUndoExecutor(
                gateway: UndoGateway(state: state, canRead: canRead, canWrite: canWrite),
                writer: UndoWriter(state: state, canWrite: canWrite),
                store: store,
                calendar: utcCalendar
            ),
            state: state,
            recordID: undoRecord.id
        )
    }
}

private struct UndoExecutorFixture {
    let executor: AgentUndoExecutor
    let state: UndoReminderState
    let recordID: UUID
}

private actor UndoReminderState {
    private var records: [String: ReminderStoreRecord]
    private let failures: [String: ReminderGatewayError]
    private(set) var events: [String] = []

    init(records: [ReminderStoreRecord], failures: [String: ReminderGatewayError]) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        self.failures = failures
    }

    func value(id: String) -> ReminderStoreRecord? { records[id] }

    func fetch(id: String) throws -> ReminderStoreRecord? {
        if let error = failures["fetch:\(id)"] { throw error }
        return records[id]
    }

    func delete(id: String) throws {
        if let error = failures["delete:\(id)"] { throw error }
        guard records.removeValue(forKey: id) != nil else { throw ReminderGatewayError.reminderNotFound(id) }
        events.append("delete:\(id)")
    }

    func update(id: String, mutation: ReminderToolMutation) throws {
        if let error = failures["update:\(id)"] { throw error }
        guard let current = records[id] else { throw ReminderGatewayError.reminderNotFound(id) }
        let dueDate = mutation.clearsDueDate ? nil : (mutation.dueDate ?? current.dueDate)
        let notes: String??
        if let value = mutation.notes {
            notes = .some(value.isEmpty ? nil : value)
        } else {
            notes = nil
        }
        records[id] = copy(
            current,
            title: mutation.title ?? current.title,
            notes: notes,
            dueDate: .some(dueDate),
            includesTime: mutation.includesTime
        )
        events.append("update:\(id)")
    }

    func move(id: String, listID: String?) throws {
        if let error = failures["move:\(id)"] { throw error }
        guard let current = records[id], let listID else { throw ReminderGatewayError.reminderNotFound(id) }
        records[id] = copy(current, listID: listID)
        events.append("move:\(id):\(listID)")
    }

    func complete(id: String, isCompleted: Bool) throws {
        if let error = failures["complete:\(id)"] { throw error }
        guard let current = records[id] else { throw ReminderGatewayError.reminderNotFound(id) }
        records[id] = copy(current, isCompleted: isCompleted)
        events.append("complete:\(id):\(isCompleted)")
    }

    private func copy(
        _ record: ReminderStoreRecord,
        title: String? = nil,
        notes: String?? = nil,
        dueDate: Date?? = nil,
        includesTime: Bool? = nil,
        listID: String? = nil,
        isCompleted: Bool? = nil
    ) -> ReminderStoreRecord {
        let resolvedNotes: String?
        switch notes {
        case let .some(value): resolvedNotes = value
        case .none: resolvedNotes = record.notes
        }
        let resolvedDueDate: Date?
        switch dueDate {
        case let .some(value): resolvedDueDate = value
        case .none: resolvedDueDate = record.dueDate
        }
        return ReminderStoreRecord(
            id: record.id,
            title: title ?? record.title,
            notes: resolvedNotes,
            dueDate: resolvedDueDate,
            includesTime: includesTime ?? record.includesTime,
            listID: listID ?? record.listID,
            listTitle: listID ?? record.listTitle,
            isCompleted: isCompleted ?? record.isCompleted,
            lastModifiedAt: record.lastModifiedAt
        )
    }
}

private actor UndoGateway: ReminderStoreGateway {
    let state: UndoReminderState
    let canRead: Bool
    let canWrite: Bool

    init(state: UndoReminderState, canRead: Bool, canWrite: Bool) {
        self.state = state
        self.canRead = canRead
        self.canWrite = canWrite
    }

    func fetchReminders() async throws -> [ReminderStoreRecord] { [] }

    func reminder(withID identifier: String) async throws -> ReminderStoreRecord? {
        guard canRead else { throw ReminderGatewayError.readNotAuthorized }
        return try await state.fetch(id: identifier)
    }
}

private actor UndoWriter: ReminderToolWriter {
    let state: UndoReminderState
    let canWrite: Bool

    init(state: UndoReminderState, canWrite: Bool) {
        self.state = state
        self.canWrite = canWrite
    }

    func create(title: String, notes: String?, dueDate: Date?, includesTime: Bool, listID: String?, listTitle: String?) async throws -> String {
        throw ReminderGatewayError.invalidRequest("undo never creates reminders")
    }

    func createList(title: String) async throws -> ReminderListCreationResult {
        throw ReminderGatewayError.invalidRequest("undo never creates lists")
    }

    func update(id: String, mutation: ReminderToolMutation) async throws {
        guard canWrite else { throw ReminderGatewayError.writeNotAuthorized }
        try await state.update(id: id, mutation: mutation)
    }

    func move(id: String, listID: String?, listTitle: String?) async throws {
        guard canWrite else { throw ReminderGatewayError.writeNotAuthorized }
        try await state.move(id: id, listID: listID)
    }

    func setCompleted(id: String, isCompleted: Bool) async throws {
        guard canWrite else { throw ReminderGatewayError.writeNotAuthorized }
        try await state.complete(id: id, isCompleted: isCompleted)
    }

    func delete(id: String) async throws {
        guard canWrite else { throw ReminderGatewayError.writeNotAuthorized }
        try await state.delete(id: id)
    }
}

private final class UndoExecutorClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 2_100_000_000)
}

private let snapshotDate = Date(timeIntervalSince1970: 2_000_000_000)

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func date(_ hour: Int, _ minute: Int) -> Date {
    utcCalendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: hour, minute: minute))!
}

private func makeReminderRecord(
    id: String,
    title: String = "Task",
    notes: String? = nil,
    dueDate: Date? = nil,
    includesTime: Bool? = nil,
    listID: String = "inbox",
    isCompleted: Bool = false,
    lastModifiedAt: Date? = snapshotDate
) -> ReminderStoreRecord {
    ReminderStoreRecord(
        id: id,
        title: title,
        notes: notes,
        dueDate: dueDate,
        includesTime: includesTime ?? (dueDate != nil),
        listID: listID,
        listTitle: listID,
        isCompleted: isCompleted,
        lastModifiedAt: lastModifiedAt
    )
}

private func version(_ id: String) -> AgentUndoTaskVersion {
    AgentUndoTaskVersion(reminderID: id, lastModifiedAt: snapshotDate)
}

private func createOperation(id: String, callID: String = "create") -> AgentUndoOperation {
    AgentUndoOperation(forwardCallID: callID, inverseOperation: .removeCreatedReminder(taskVersion: version(id)))
}

private func fieldsOperation(
    id: String,
    callID: String = "update",
    changes: [AgentUndoFieldChange]
) -> AgentUndoOperation {
    AgentUndoOperation(
        forwardCallID: callID,
        inverseOperation: .restoreFields(taskVersion: version(id), changes: changes)
    )
}

private func moveOperation(id: String, callID: String = "move") -> AgentUndoOperation {
    AgentUndoOperation(
        forwardCallID: callID,
        inverseOperation: .restoreList(taskVersion: version(id), originalListID: "inbox", forwardListID: "project")
    )
}

private func completionOperation(id: String, callID: String = "complete") -> AgentUndoOperation {
    AgentUndoOperation(
        forwardCallID: callID,
        inverseOperation: .restoreCompletion(
            taskVersion: version(id),
            originalIsCompleted: false,
            forwardIsCompleted: true
        )
    )
}
