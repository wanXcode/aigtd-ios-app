import Foundation
import XCTest
@testable import AIGTDReminders

final class ReminderAgentToolExecutorsTests: XCTestCase {
    func testSearchReturnsStableIDsWithoutNotesByDefault() async throws {
        let environment = makeEnvironment(records: [makeToolRecord(id: "one", notes: "secret")])
        let output = try await environment.executor(.searchReminders).execute(
            arguments: .init(["query": .string("Task")]),
            runID: UUID(),
            callID: "search"
        )

        guard case let .array(items)? = output.result["items"],
              case let .object(item)? = items.first else {
            return XCTFail("Missing items")
        }
        XCTAssertEqual(item["reminder_id"], .string("one"))
        XCTAssertNil(item["notes"])
    }

    func testDetailsRejectsMissingStableID() async {
        let environment = makeEnvironment()
        await assertToolError(
            try await environment.executor(.getReminderDetails).execute(
                arguments: .init(["reminder_ids": .array([.string("missing")])]),
                runID: UUID(),
                callID: "details"
            ),
            category: .notFound
        )
    }

    func testCreateReplayDoesNotWriteTwice() async throws {
        let environment = makeEnvironment()
        let runID = UUID()
        let executor = environment.executor(.createReminder)
        let arguments = AgentToolArguments(["title": .string("New task"), "list_id": .string("inbox")])

        let first = try await executor.execute(arguments: arguments, runID: runID, callID: "create")
        let replay = try await executor.execute(arguments: arguments, runID: runID, callID: "create")

        XCTAssertEqual(first.status, .success)
        XCTAssertEqual(replay.status, .alreadyApplied)
        let createCount = await environment.writer.createCount
        XCTAssertEqual(createCount, 1)
    }

    func testCreateReturnsThePersistedSchedulingFields() async throws {
        let environment = makeEnvironment()
        let dueDate = "2026-08-01T02:00:00Z"

        let output = try await environment.executor(.createReminder).execute(
            arguments: .init([
                "title": .string("去上班"),
                "due_date": .string(dueDate),
                "includes_time": .bool(true),
                "list_id": .string("inbox")
            ]),
            runID: UUID(),
            callID: "create-scheduled"
        )

        XCTAssertEqual(output.result["title"], .string("去上班"))
        XCTAssertEqual(output.result["due_date"], .string(dueDate))
        XCTAssertEqual(output.result["includes_time"], .bool(true))
    }

    func testCreateListReturnsStableIDAndDoesNotWriteTwiceOnReplay() async throws {
        let environment = makeEnvironment()
        let runID = UUID()
        let executor = environment.executor(.createList)
        let arguments = AgentToolArguments(["title": .string("发布准备")])

        let first = try await executor.execute(arguments: arguments, runID: runID, callID: "create-list")
        let replay = try await executor.execute(arguments: arguments, runID: runID, callID: "create-list")
        let createListCount = await environment.writer.createListCount

        XCTAssertEqual(first.result["list_id"], .string("created-list-id"))
        XCTAssertEqual(replay.status, .alreadyApplied)
        XCTAssertEqual(createListCount, 1)
    }

    func testUpdateRequiresStableID() async {
        let environment = makeEnvironment()
        await assertToolError(
            try await environment.executor(.updateReminder).execute(
                arguments: .init(["title": .string("Changed")]),
                runID: UUID(),
                callID: "update"
            ),
            category: .invalidArguments
        )
    }

    func testUpdateStopsOnPreconditionConflict() async {
        let environment = makeEnvironment(records: [makeToolRecord(id: "one", listID: "inbox")])
        await assertToolError(
            try await environment.executor(.updateReminder).execute(
                arguments: .init([
                    "reminder_id": .string("one"),
                    "title": .string("Changed"),
                    "expected_list_id": .string("work")
                ]),
                runID: UUID(),
                callID: "update"
            ),
            category: .preconditionConflict
        )
        let updateCount = await environment.writer.updateCount
        XCTAssertEqual(updateCount, 0)
    }

    func testUnchangedCompletionDoesNotRewriteCompletionDate() async throws {
        let environment = makeEnvironment(records: [makeToolRecord(id: "one", isCompleted: true)])
        let output = try await environment.executor(.completeReminder).execute(
            arguments: .init(["reminder_id": .string("one"), "is_completed": .bool(true)]),
            runID: UUID(),
            callID: "complete"
        )

        XCTAssertEqual(output.status, .unchanged)
        let completeCount = await environment.writer.completeCount
        XCTAssertEqual(completeCount, 0)
    }

    func testMoveToCurrentListIsUnchanged() async throws {
        let environment = makeEnvironment(records: [makeToolRecord(id: "one", listID: "inbox")])
        let output = try await environment.executor(.moveReminder).execute(
            arguments: .init(["reminder_id": .string("one"), "list_id": .string("inbox")]),
            runID: UUID(),
            callID: "move"
        )

        XCTAssertEqual(output.status, .unchanged)
        let moveCount = await environment.writer.moveCount
        XCTAssertEqual(moveCount, 0)
    }

    func testDeleteRequiresExplicitConfirmation() async {
        let environment = makeEnvironment(records: [makeToolRecord(id: "one")])
        await assertToolError(
            try await environment.executor(.deleteReminder).execute(
                arguments: .init(["reminder_id": .string("one")]),
                runID: UUID(),
                callID: "delete"
            ),
            category: .confirmationRequired
        )
        let deleteCount = await environment.writer.deleteCount
        XCTAssertEqual(deleteCount, 0)
    }

    func testConfirmedDeleteUsesStableID() async throws {
        let environment = makeEnvironment(records: [makeToolRecord(id: "stable-id")])
        _ = try await environment.executor(.deleteReminder).execute(
            arguments: .init(["reminder_id": .string("stable-id"), "confirmed": .bool(true)]),
            runID: UUID(),
            callID: "delete"
        )

        let deletedIDs = await environment.writer.deletedIDs
        XCTAssertEqual(deletedIDs, ["stable-id"])
    }

    func testWritePermissionIsCheckedBeforeCreate() async {
        let environment = makeEnvironment(canWrite: false)
        await assertToolError(
            try await environment.executor(.createReminder).execute(
                arguments: .init(["title": .string("New")]),
                runID: UUID(),
                callID: "create"
            ),
            category: .permissionDenied
        )
    }

    func testReadReplayRemainsSuccess() async throws {
        let environment = makeEnvironment(records: [makeToolRecord(id: "one")])
        let executor = environment.executor(.searchReminders)
        let runID = UUID()
        _ = try await executor.execute(arguments: .init(), runID: runID, callID: "search")
        let replay = try await executor.execute(arguments: .init(), runID: runID, callID: "search")

        XCTAssertEqual(replay.status, .success)
        let fetchCount = await environment.gateway.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testProposeScheduleCreatesAwaitingConfirmationPlan() async throws {
        let original = Date(timeIntervalSince1970: 1_000)
        let target = Date(timeIntervalSince1970: 2_000)
        let environment = makeEnvironment(records: [makeToolRecord(id: "one", dueDate: original)])
        let runID = UUID()

        let output = try await environment.executor(.proposeSchedule).execute(
            arguments: scheduleArguments(reminderID: "one", target: target),
            runID: runID,
            callID: "propose"
        )

        XCTAssertEqual(output.result["plan_status"], .string("awaiting_confirmation"))
        XCTAssertNotNil(stringValue(output.result["plan_id"]))
        let updateCount = await environment.writer.updateCount
        XCTAssertEqual(updateCount, 0)
    }

    func testProposeScheduleUsesCurrentReminderStateWhenModelSnapshotIsStale() async throws {
        let current = Date(timeIntervalSince1970: 1_000)
        let target = Date(timeIntervalSince1970: 2_000)
        let stale = Date(timeIntervalSince1970: 500)
        let environment = makeEnvironment(records: [makeToolRecord(id: "one", dueDate: current)])
        let formatter = ISO8601DateFormatter()
        let arguments = AgentToolArguments([
            "items": .array([.object([
                "reminder_id": .string("one"),
                "target_due_date": .string(formatter.string(from: target)),
                "expected_due_date": .string(formatter.string(from: stale))
            ])])
        ])

        let output = try await environment.executor(.proposeSchedule).execute(
            arguments: arguments,
            runID: UUID(),
            callID: "propose-stale-model-snapshot"
        )

        XCTAssertEqual(output.status, .success)
        XCTAssertEqual(output.result["plan_status"], .string("awaiting_confirmation"))
        XCTAssertEqual(output.result["items"], .array([.object([
            "item_id": .string("item-1"),
            "reminder_id": .string("one"),
            "title": .string("Task"),
            "original_due_date": .string(formatter.string(from: current)),
            "target_due_date": .string(formatter.string(from: target)),
            "includes_time": .bool(true),
            "status": .string("pending")
        ])]))
    }

    func testProposeScheduleRejectsMissingReminder() async {
        let environment = makeEnvironment()
        await assertToolError(
            try await environment.executor(.proposeSchedule).execute(
                arguments: scheduleArguments(reminderID: "missing", target: Date()),
                runID: UUID(),
                callID: "propose"
            ),
            category: .notFound
        )
    }

    func testApplyScheduleRequiresConfirmation() async throws {
        let environment = makeEnvironment(records: [makeToolRecord(id: "one", dueDate: Date(timeIntervalSince1970: 1_000))])
        let runID = UUID()
        let proposed = try await environment.executor(.proposeSchedule).execute(
            arguments: scheduleArguments(reminderID: "one", target: Date(timeIntervalSince1970: 2_000)),
            runID: runID,
            callID: "propose"
        )
        let planID = try XCTUnwrap(stringValue(proposed.result["plan_id"]))

        await assertToolError(
            try await environment.executor(.applySchedule).execute(
                arguments: .init(["plan_id": .string(planID)]),
                runID: runID,
                callID: "apply"
            ),
            category: .confirmationRequired
        )
    }

    func testApplyScheduleUpdatesByStableID() async throws {
        let original = Date(timeIntervalSince1970: 1_000)
        let target = Date(timeIntervalSince1970: 2_000)
        let environment = makeEnvironment(records: [makeToolRecord(id: "stable", dueDate: original)])
        let runID = UUID()
        let proposed = try await environment.executor(.proposeSchedule).execute(
            arguments: scheduleArguments(reminderID: "stable", target: target),
            runID: runID,
            callID: "propose"
        )
        let planID = try XCTUnwrap(stringValue(proposed.result["plan_id"]))

        let applied = try await environment.executor(.applySchedule).execute(
            arguments: .init(["plan_id": .string(planID), "confirmed": .bool(true)]),
            runID: runID,
            callID: "apply"
        )

        XCTAssertEqual(applied.status, .success)
        XCTAssertEqual(applied.result["plan_status"], .string("succeeded"))
        let updatedIDs = await environment.writer.updatedIDs
        XCTAssertEqual(updatedIDs, ["stable"])
    }

    func testApplyScheduleRejectsDifferentRun() async throws {
        let environment = makeEnvironment(records: [makeToolRecord(id: "one", dueDate: Date(timeIntervalSince1970: 1_000))])
        let proposed = try await environment.executor(.proposeSchedule).execute(
            arguments: scheduleArguments(reminderID: "one", target: Date(timeIntervalSince1970: 2_000)),
            runID: UUID(),
            callID: "propose"
        )
        let planID = try XCTUnwrap(stringValue(proposed.result["plan_id"]))

        await assertToolError(
            try await environment.executor(.applySchedule).execute(
                arguments: .init(["plan_id": .string(planID), "confirmed": .bool(true)]),
                runID: UUID(),
                callID: "apply"
            ),
            category: .staleReference
        )
    }

    func testApplyScheduleReportsPartialFailure() async throws {
        let original = Date(timeIntervalSince1970: 1_000)
        let environment = makeEnvironment(
            records: [makeToolRecord(id: "one", dueDate: original), makeToolRecord(id: "two", dueDate: original)],
            failedUpdateIDs: ["two"]
        )
        let runID = UUID()
        let formatter = ISO8601DateFormatter()
        let items: [AgentJSONValue] = ["one", "two"].enumerated().map { index, id in
            .object([
                "item_id": .string(id),
                "reminder_id": .string(id),
                "target_due_date": .string(formatter.string(from: original.addingTimeInterval(Double(index + 1) * 3_600)))
            ])
        }
        let proposed = try await environment.executor(.proposeSchedule).execute(
            arguments: .init(["items": .array(items)]),
            runID: runID,
            callID: "propose"
        )
        let planID = try XCTUnwrap(stringValue(proposed.result["plan_id"]))

        let output = try await environment.executor(.applySchedule).execute(
            arguments: .init(["plan_id": .string(planID), "confirmed": .bool(true)]),
            runID: runID,
            callID: "apply"
        )

        XCTAssertEqual(output.result["plan_status"], .string("partial"))
        XCTAssertEqual(output.result["successful_count"], .integer(1))
        XCTAssertEqual(output.result["failed_count"], .integer(1))
    }

    private func makeEnvironment(
        canRead: Bool = true,
        canWrite: Bool = true,
        records: [ReminderStoreRecord] = [],
        failedUpdateIDs: Set<String> = []
    ) -> ToolEnvironment {
        let gateway = ToolTestGateway(canRead: canRead, records: records)
        let writer = ToolTestWriter(canWrite: canWrite, failedUpdateIDs: failedUpdateIDs)
        let suite = "ReminderAgentToolExecutorsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ToolEnvironment(
            gateway: gateway,
            writer: writer,
            ledger: AgentToolExecutionLedger(),
            schedulePlanStore: AgentSchedulePlanStore(defaults: defaults, storageKey: "plans"),
            undoStore: AgentUndoRecordStore(defaults: defaults, storageKey: "undo")
        )
    }

    private func scheduleArguments(reminderID: String, target: Date) -> AgentToolArguments {
        .init([
            "items": .array([.object([
                "reminder_id": .string(reminderID),
                "target_due_date": .string(ISO8601DateFormatter().string(from: target))
            ])])
        ])
    }

    private func stringValue(_ value: AgentJSONValue?) -> String? {
        guard case let .string(string)? = value else { return nil }
        return string
    }

    private func assertToolError<T>(
        _ expression: @autoclosure () async throws -> T,
        category: AgentToolErrorCategory
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error")
        } catch let error as AgentToolError {
            XCTAssertEqual(error.category, category)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private struct ToolEnvironment {
    let gateway: ToolTestGateway
    let writer: ToolTestWriter
    let ledger: AgentToolExecutionLedger
    let schedulePlanStore: AgentSchedulePlanStore
    let undoStore: AgentUndoRecordStore

    func executor(_ tool: AgentToolName) -> ReminderAgentToolExecutor {
        ReminderAgentToolExecutor(
            toolName: tool,
            queryService: ReminderQueryService(gateway: gateway),
            writer: writer,
            ledger: ledger,
            schedulePlanStore: schedulePlanStore,
            undoStore: undoStore
        )
    }
}

private actor ToolTestGateway: ReminderStoreGateway {
    let canRead: Bool
    let canWrite = true
    private let records: [String: ReminderStoreRecord]
    private(set) var fetchCount = 0

    init(canRead: Bool, records: [ReminderStoreRecord]) {
        self.canRead = canRead
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    func fetchReminders() throws -> [ReminderStoreRecord] {
        fetchCount += 1
        guard canRead else { throw ReminderGatewayError.readNotAuthorized }
        return Array(records.values)
    }

    func reminder(withID identifier: String) throws -> ReminderStoreRecord? {
        guard canRead else { throw ReminderGatewayError.readNotAuthorized }
        return records[identifier]
    }
}

private actor ToolTestWriter: ReminderToolWriter {
    let canWrite: Bool
    private(set) var createCount = 0
    private(set) var createListCount = 0
    private(set) var updateCount = 0
    private(set) var moveCount = 0
    private(set) var completeCount = 0
    private(set) var deleteCount = 0
    private(set) var deletedIDs: [String] = []
    private(set) var updatedIDs: [String] = []
    private let failedUpdateIDs: Set<String>

    init(canWrite: Bool, failedUpdateIDs: Set<String> = []) {
        self.canWrite = canWrite
        self.failedUpdateIDs = failedUpdateIDs
    }

    func create(title: String, notes: String?, dueDate: Date?, includesTime: Bool, listID: String?, listTitle: String?) -> String {
        createCount += 1
        return "created-id"
    }

    func createList(title: String) -> ReminderListCreationResult {
        createListCount += 1
        return ReminderListCreationResult(id: "created-list-id", title: title, created: true)
    }

    func update(id: String, mutation: ReminderToolMutation) throws {
        updateCount += 1
        if failedUpdateIDs.contains(id) {
            throw AgentToolError(category: .eventKitError, userVisibleMessage: "write failed")
        }
        updatedIDs.append(id)
    }

    func move(id: String, listID: String?, listTitle: String?) {
        moveCount += 1
    }

    func setCompleted(id: String, isCompleted: Bool) {
        completeCount += 1
    }

    func delete(id: String) {
        deleteCount += 1
        deletedIDs.append(id)
    }
}

private func makeToolRecord(
    id: String,
    notes: String? = nil,
    dueDate: Date? = nil,
    listID: String = "inbox",
    isCompleted: Bool = false
) -> ReminderStoreRecord {
    ReminderStoreRecord(
        id: id,
        title: "Task",
        notes: notes,
        dueDate: dueDate,
        includesTime: dueDate != nil,
        listID: listID,
        listTitle: listID.capitalized,
        isCompleted: isCompleted,
        lastModifiedAt: nil
    )
}
