import Foundation
import XCTest
@testable import AIGTDReminders

final class AgentUndoRecordStoreTests: XCTestCase {
    func testRecordsCreateInverseWithDefaultTenMinuteWindow() throws {
        let clock = UndoTestClock()
        let fixture = makeFixture(clock: clock)
        let operation = makeCreateOperation(callID: "create")

        let record = try fixture.store.record(
            forwardRunID: fixture.runID,
            sessionID: fixture.sessionID,
            successfulOperations: [operation]
        )

        XCTAssertEqual(record.operations, [operation])
        XCTAssertEqual(record.status, .available)
        XCTAssertEqual(record.createdAt, clock.now)
        XCTAssertEqual(record.expiresAt, clock.now.addingTimeInterval(10 * 60))
        XCTAssertEqual(operation.forwardOperation, .create)
    }

    func testSupportsOnlyCreateUpdateMoveAndCompleteForwardModels() {
        XCTAssertEqual(makeCreateOperation().forwardOperation, .create)
        XCTAssertEqual(makeUpdateOperation().forwardOperation, .update)
        XCTAssertEqual(makeMoveOperation().forwardOperation, .move)
        XCTAssertEqual(makeCompleteOperation().forwardOperation, .complete)
        XCTAssertEqual(Set([makeCreateOperation(), makeUpdateOperation(), makeMoveOperation(), makeCompleteOperation()].map(\.forwardOperation)), Set([.create, .update, .move, .complete]))
    }

    func testUpdateSnapshotContainsOnlyChangedFieldsAndTheirForwardValues() throws {
        let operation = makeUpdateOperation()
        guard case let .restoreFields(_, changes) = operation.inverseOperation else {
            return XCTFail("Expected field restoration")
        }

        XCTAssertEqual(changes, [
            AgentUndoFieldChange(
                field: .dueDate,
                originalValue: .none,
                forwardValue: .date(Date(timeIntervalSince1970: 300))
            )
        ])
        XCTAssertFalse(changes.contains { $0.field == .notes })
    }

    func testSameForwardRunAccumulatesMultipleSuccessfulWrites() throws {
        let fixture = makeFixture()
        _ = try fixture.store.recordSuccessfulOperation(
            forwardRunID: fixture.runID,
            sessionID: fixture.sessionID,
            operation: makeCreateOperation(callID: "one")
        )
        let record = try fixture.store.recordSuccessfulOperation(
            forwardRunID: fixture.runID,
            sessionID: fixture.sessionID,
            operation: makeMoveOperation(callID: "two")
        )

        XCTAssertEqual(record.operations.map(\.forwardCallID), ["one", "two"])
        XCTAssertEqual(fixture.store.records().count, 1)
    }

    func testInverseOperationsAreReadInReverseForwardOrder() throws {
        let fixture = makeFixture()
        let operations = [
            makeCreateOperation(callID: "first"),
            makeUpdateOperation(callID: "second"),
            makeMoveOperation(callID: "third")
        ]
        let record = try fixture.store.record(
            forwardRunID: fixture.runID,
            successfulOperations: operations
        )

        XCTAssertEqual(try fixture.store.inverseOperations(for: record.id).map(\.forwardCallID), ["third", "second", "first"])
    }

    func testExpiredRecordRemainsDiagnosticButCannotBeReadForUndo() throws {
        let clock = UndoTestClock()
        let fixture = makeFixture(clock: clock)
        let record = try fixture.store.record(
            forwardRunID: fixture.runID,
            successfulOperations: [makeCreateOperation()],
            availabilityInterval: 5
        )

        clock.now.addTimeInterval(5)

        XCTAssertThrowsError(try fixture.store.inverseOperations(for: record.id)) {
            XCTAssertEqual($0 as? AgentUndoRecordStoreError, .unavailable(.expired))
        }
        XCTAssertEqual(fixture.store.record(id: record.id)?.status, .expired)
    }

    func testExpirationPersistsAcrossStoreInstances() throws {
        let defaults = makeDefaults()
        let clock = UndoTestClock()
        let first = AgentUndoRecordStore(defaults: defaults, storageKey: "undo", now: { clock.now })
        let record = try first.record(
            forwardRunID: UUID(),
            successfulOperations: [makeCreateOperation()],
            availabilityInterval: 1
        )
        clock.now.addTimeInterval(2)
        first.expireRecords()

        let second = AgentUndoRecordStore(defaults: defaults, storageKey: "undo", now: { clock.now })
        XCTAssertEqual(second.record(id: record.id)?.status, .expired)
    }

    func testCompleteUndoMarksAllSuccessfulOperationsUndone() throws {
        let fixture = makeFixture()
        let record = try fixture.store.record(
            forwardRunID: fixture.runID,
            successfulOperations: [makeCreateOperation(callID: "one"), makeMoveOperation(callID: "two")]
        )
        let undoRunID = UUID()
        let outcomes = record.operations.map {
            AgentUndoOperationOutcome(operationID: $0.id, status: .undone, reason: nil)
        }

        let completed = try fixture.store.completeUndo(recordID: record.id, undoRunID: undoRunID, outcomes: outcomes)

        XCTAssertEqual(completed.status, .undone)
        XCTAssertEqual(completed.undoRunID, undoRunID)
        XCTAssertNotNil(completed.resolvedAt)
    }

    func testCompleteUndoMarksAllConflictsAsConflict() throws {
        let fixture = makeFixture()
        let record = try fixture.store.record(
            forwardRunID: fixture.runID,
            successfulOperations: [makeMoveOperation()]
        )

        let completed = try fixture.store.completeUndo(
            recordID: record.id,
            undoRunID: UUID(),
            outcomes: [AgentUndoOperationOutcome(
                operationID: record.operations[0].id,
                status: .conflict,
                reason: .taskChanged
            )]
        )

        XCTAssertEqual(completed.status, .conflict)
        XCTAssertEqual(completed.outcomes.first?.reason, .taskChanged)
    }

    func testCompleteUndoMarksMixedResultsAsPartiallyFailed() throws {
        let fixture = makeFixture()
        let record = try fixture.store.record(
            forwardRunID: fixture.runID,
            successfulOperations: [makeCreateOperation(callID: "one"), makeCompleteOperation(callID: "two")]
        )

        let completed = try fixture.store.completeUndo(
            recordID: record.id,
            undoRunID: UUID(),
            outcomes: [
                AgentUndoOperationOutcome(operationID: record.operations[0].id, status: .undone, reason: nil),
                AgentUndoOperationOutcome(operationID: record.operations[1].id, status: .failed, reason: .operationFailed)
            ]
        )

        XCTAssertEqual(completed.status, .partiallyFailed)
    }

    func testIncompleteOutcomeSetIsPartiallyFailed() throws {
        let fixture = makeFixture()
        let record = try fixture.store.record(
            forwardRunID: fixture.runID,
            successfulOperations: [makeCreateOperation(callID: "one"), makeMoveOperation(callID: "two")]
        )

        let completed = try fixture.store.completeUndo(
            recordID: record.id,
            undoRunID: UUID(),
            outcomes: [AgentUndoOperationOutcome(operationID: record.operations[0].id, status: .undone, reason: nil)]
        )

        XCTAssertEqual(completed.status, .partiallyFailed)
    }

    func testTerminalRecordCannotBeUndoneAgainOrAppended() throws {
        let fixture = makeFixture()
        let record = try fixture.store.record(
            forwardRunID: fixture.runID,
            successfulOperations: [makeCreateOperation()]
        )
        _ = try fixture.store.completeUndo(
            recordID: record.id,
            undoRunID: UUID(),
            outcomes: [AgentUndoOperationOutcome(operationID: record.operations[0].id, status: .undone, reason: nil)]
        )

        XCTAssertThrowsError(try fixture.store.inverseOperations(for: record.id)) {
            XCTAssertEqual($0 as? AgentUndoRecordStoreError, .unavailable(.undone))
        }
        XCTAssertThrowsError(try fixture.store.recordSuccessfulOperation(
            forwardRunID: fixture.runID,
            operation: makeMoveOperation(callID: "late")
        ))
    }

    func testRejectsDuplicateCallIDsAndInvalidMinimalSnapshots() throws {
        let fixture = makeFixture()
        XCTAssertThrowsError(try fixture.store.record(
            forwardRunID: fixture.runID,
            successfulOperations: [makeCreateOperation(callID: "same"), makeMoveOperation(callID: "same")]
        )) {
            XCTAssertEqual($0 as? AgentUndoRecordStoreError, .invalidInput)
        }
        let invalid = AgentUndoOperation(
            forwardCallID: "invalid",
            inverseOperation: .restoreFields(taskVersion: taskVersion(), changes: [])
        )
        XCTAssertThrowsError(try fixture.store.record(
            forwardRunID: fixture.runID,
            successfulOperations: [invalid]
        ))
    }

    func testPersistenceRoundTripsAllInverseOperationKinds() throws {
        let defaults = makeDefaults()
        let first = AgentUndoRecordStore(defaults: defaults, storageKey: "undo")
        let operations = [makeCreateOperation(), makeUpdateOperation(), makeMoveOperation(), makeCompleteOperation()]
        let record = try first.record(forwardRunID: UUID(), successfulOperations: operations)

        let second = AgentUndoRecordStore(defaults: defaults, storageKey: "undo")

        XCTAssertEqual(second.record(id: record.id), record)
    }

    func testCorruptPersistenceRecoversAndOnlyClearsOwnedKey() {
        let defaults = makeDefaults()
        defaults.set(Data("not-json".utf8), forKey: "undo")
        defaults.set("keep", forKey: "chat-history")

        let store = AgentUndoRecordStore(defaults: defaults, storageKey: "undo")

        XCTAssertTrue(store.records().isEmpty)
        XCTAssertNil(defaults.object(forKey: "undo"))
        XCTAssertEqual(defaults.string(forKey: "chat-history"), "keep")
    }

    func testUnsupportedSchemaRecoversSafely() throws {
        let defaults = makeDefaults()
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": 999, "records": []])
        defaults.set(data, forKey: "undo")

        let store = AgentUndoRecordStore(defaults: defaults, storageKey: "undo")

        XCTAssertTrue(store.records().isEmpty)
        XCTAssertNil(defaults.object(forKey: "undo"))
    }

    func testSemanticallyInvalidPersistenceRecoversSafely() throws {
        let defaults = makeDefaults()
        let invalidRecord = AgentUndoRecord(
            recordID: UUID(),
            forwardRunID: UUID(),
            sessionID: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 200),
            operations: [],
            status: .available,
            undoRunID: nil,
            outcomes: [],
            resolvedAt: nil
        )
        let data = try JSONEncoder().encode(UndoTestEnvelope(schemaVersion: 1, records: [invalidRecord]))
        defaults.set(data, forKey: "undo")

        let store = AgentUndoRecordStore(defaults: defaults, storageKey: "undo")

        XCTAssertTrue(store.records().isEmpty)
        XCTAssertNil(defaults.object(forKey: "undo"))
    }

    func testPersistedPayloadHasNoCredentialOrRawModelResponseFields() throws {
        let defaults = makeDefaults()
        let store = AgentUndoRecordStore(defaults: defaults, storageKey: "undo")
        _ = try store.record(
            forwardRunID: UUID(),
            successfulOperations: [makeUpdateOperation()]
        )

        let data = try XCTUnwrap(defaults.data(forKey: "undo"))
        let payload = String(decoding: data, as: UTF8.self).lowercased()
        XCTAssertFalse(payload.contains("api_key"))
        XCTAssertFalse(payload.contains("authorization"))
        XCTAssertFalse(payload.contains("model_response"))
        XCTAssertFalse(payload.contains("raw_response"))
    }

    func testConcurrentAppendsProduceOneRecordWithEveryOperation() {
        let fixture = makeFixture()
        let count = 40

        DispatchQueue.concurrentPerform(iterations: count) { index in
            _ = try? fixture.store.recordSuccessfulOperation(
                forwardRunID: fixture.runID,
                sessionID: fixture.sessionID,
                operation: makeCreateOperation(callID: "call-\(index)", reminderID: "reminder-\(index)")
            )
        }

        let records = fixture.store.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.operations.count, count)
        XCTAssertEqual(Set(records.first?.operations.map(\.forwardCallID) ?? []).count, count)
    }

    func testClearAndCustomStorageKeyAreScoped() throws {
        let defaults = makeDefaults()
        let store = AgentUndoRecordStore(defaults: defaults, storageKey: "custom-undo")
        _ = try store.record(forwardRunID: UUID(), successfulOperations: [makeCreateOperation()])
        defaults.set(true, forKey: "privacy-setting")

        XCTAssertNotNil(defaults.data(forKey: "custom-undo"))
        XCTAssertNil(defaults.data(forKey: AgentUndoRecordStore.defaultStorageKey))
        store.clear()
        XCTAssertTrue(store.records().isEmpty)
        XCTAssertTrue(defaults.bool(forKey: "privacy-setting"))
    }

    private func makeFixture(clock: UndoTestClock = UndoTestClock()) -> UndoStoreFixture {
        UndoStoreFixture(
            store: AgentUndoRecordStore(defaults: makeDefaults(), storageKey: "undo", now: { clock.now }),
            sessionID: UUID(),
            runID: UUID()
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AgentUndoRecordStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

private struct UndoStoreFixture {
    let store: AgentUndoRecordStore
    let sessionID: UUID
    let runID: UUID
}

private struct UndoTestEnvelope: Codable {
    let schemaVersion: Int
    let records: [AgentUndoRecord]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case records
    }
}

private final class UndoTestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 2_000_000_000)
}

private func taskVersion(_ reminderID: String = "reminder-1") -> AgentUndoTaskVersion {
    AgentUndoTaskVersion(reminderID: reminderID, lastModifiedAt: Date(timeIntervalSince1970: 200))
}

private func makeCreateOperation(callID: String = "create", reminderID: String = "created") -> AgentUndoOperation {
    AgentUndoOperation(
        forwardCallID: callID,
        inverseOperation: .removeCreatedReminder(taskVersion: taskVersion(reminderID))
    )
}

private func makeUpdateOperation(callID: String = "update") -> AgentUndoOperation {
    AgentUndoOperation(
        forwardCallID: callID,
        inverseOperation: .restoreFields(
            taskVersion: taskVersion(),
            changes: [AgentUndoFieldChange(
                field: .dueDate,
                originalValue: .none,
                forwardValue: .date(Date(timeIntervalSince1970: 300))
            )]
        )
    )
}

private func makeMoveOperation(callID: String = "move") -> AgentUndoOperation {
    AgentUndoOperation(
        forwardCallID: callID,
        inverseOperation: .restoreList(
            taskVersion: taskVersion(),
            originalListID: "inbox",
            forwardListID: "project"
        )
    )
}

private func makeCompleteOperation(callID: String = "complete") -> AgentUndoOperation {
    AgentUndoOperation(
        forwardCallID: callID,
        inverseOperation: .restoreCompletion(
            taskVersion: taskVersion(),
            originalIsCompleted: false,
            forwardIsCompleted: true
        )
    )
}
