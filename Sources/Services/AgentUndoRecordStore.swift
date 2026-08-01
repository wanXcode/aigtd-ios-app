import Foundation
import CryptoKit

enum AgentUndoForwardOperation: String, Codable, Equatable, Sendable {
    case create
    case update
    case move
    case complete
}

enum AgentUndoField: String, Codable, Equatable, Sendable {
    case title
    case dueDate = "due_date"
    case includesTime = "includes_time"
    case notes
}

enum AgentUndoFieldValue: Codable, Equatable, Sendable {
    case string(String)
    case date(Date)
    case bool(Bool)
    case none
}

struct AgentUndoFieldChange: Codable, Equatable, Sendable {
    let field: AgentUndoField
    let originalValue: AgentUndoFieldValue
    let forwardValue: AgentUndoFieldValue
}

struct AgentUndoTaskVersion: Codable, Equatable, Sendable {
    let reminderID: String
    let lastModifiedAt: Date?
    let title: String?
    let dueDate: Date?
    let hasDueDateSnapshot: Bool
    let includesTime: Bool?
    let listID: String?
    let isCompleted: Bool?
    let notesDigest: String?

    init(
        reminderID: String,
        lastModifiedAt: Date? = nil,
        title: String? = nil,
        dueDate: Date? = nil,
        hasDueDateSnapshot: Bool = false,
        includesTime: Bool? = nil,
        listID: String? = nil,
        isCompleted: Bool? = nil,
        notesDigest: String? = nil
    ) {
        self.reminderID = reminderID
        self.lastModifiedAt = lastModifiedAt
        self.title = title
        self.dueDate = dueDate
        self.hasDueDateSnapshot = hasDueDateSnapshot
        self.includesTime = includesTime
        self.listID = listID
        self.isCompleted = isCompleted
        self.notesDigest = notesDigest
    }

    private enum CodingKeys: String, CodingKey {
        case reminderID = "reminder_id"
        case lastModifiedAt = "last_modified_at"
        case title
        case dueDate = "due_date"
        case hasDueDateSnapshot = "has_due_date_snapshot"
        case includesTime = "includes_time"
        case listID = "list_id"
        case isCompleted = "is_completed"
        case notesDigest = "notes_digest"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reminderID = try container.decode(String.self, forKey: .reminderID)
        lastModifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastModifiedAt)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
        hasDueDateSnapshot = try container.decodeIfPresent(Bool.self, forKey: .hasDueDateSnapshot) ?? false
        includesTime = try container.decodeIfPresent(Bool.self, forKey: .includesTime)
        listID = try container.decodeIfPresent(String.self, forKey: .listID)
        isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted)
        notesDigest = try container.decodeIfPresent(String.self, forKey: .notesDigest)
    }
}

enum AgentUndoNotesDigest {
    static func digest(_ notes: String?) -> String {
        SHA256.hash(data: Data((notes ?? "").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum AgentUndoInverseOperation: Codable, Equatable, Sendable {
    // This removes a task created by the forward operation. Forward deletes are deliberately unsupported.
    case removeCreatedReminder(taskVersion: AgentUndoTaskVersion)
    case restoreFields(taskVersion: AgentUndoTaskVersion, changes: [AgentUndoFieldChange])
    case restoreList(taskVersion: AgentUndoTaskVersion, originalListID: String, forwardListID: String)
    case restoreCompletion(
        taskVersion: AgentUndoTaskVersion,
        originalIsCompleted: Bool,
        forwardIsCompleted: Bool
    )

    var forwardOperation: AgentUndoForwardOperation {
        switch self {
        case .removeCreatedReminder:
            return .create
        case .restoreFields:
            return .update
        case .restoreList:
            return .move
        case .restoreCompletion:
            return .complete
        }
    }

    var reminderID: String {
        switch self {
        case let .removeCreatedReminder(taskVersion),
             let .restoreFields(taskVersion, _),
             let .restoreList(taskVersion, _, _),
             let .restoreCompletion(taskVersion, _, _):
            return taskVersion.reminderID
        }
    }
}

struct AgentUndoOperation: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { operationID }

    let operationID: UUID
    let forwardCallID: String
    let forwardOperation: AgentUndoForwardOperation
    let inverseOperation: AgentUndoInverseOperation
    let recordedAt: Date

    init(
        operationID: UUID = UUID(),
        forwardCallID: String,
        inverseOperation: AgentUndoInverseOperation,
        recordedAt: Date = .now
    ) {
        self.operationID = operationID
        self.forwardCallID = forwardCallID
        self.forwardOperation = inverseOperation.forwardOperation
        self.inverseOperation = inverseOperation
        self.recordedAt = recordedAt
    }

    private enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case forwardCallID = "forward_call_id"
        case forwardOperation = "forward_operation"
        case inverseOperation = "inverse_operation"
        case recordedAt = "recorded_at"
    }
}

enum AgentUndoRecordStatus: String, Codable, Equatable, Sendable {
    case available
    case expired
    case undone
    case conflict
    case partiallyFailed = "partially_failed"
}

enum AgentUndoOperationOutcomeStatus: String, Codable, Equatable, Sendable {
    case undone
    case conflict
    case failed
}

enum AgentUndoOutcomeReason: String, Codable, Equatable, Sendable {
    case taskChanged = "task_changed"
    case taskMissing = "task_missing"
    case listMissing = "list_missing"
    case operationFailed = "operation_failed"
}

struct AgentUndoOperationOutcome: Codable, Equatable, Sendable {
    let operationID: UUID
    let status: AgentUndoOperationOutcomeStatus
    let reason: AgentUndoOutcomeReason?

    private enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case status
        case reason
    }
}

struct AgentUndoRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { recordID }

    let recordID: UUID
    let forwardRunID: UUID
    let sessionID: UUID?
    let createdAt: Date
    let expiresAt: Date
    var operations: [AgentUndoOperation]
    var status: AgentUndoRecordStatus
    var undoRunID: UUID?
    var outcomes: [AgentUndoOperationOutcome]
    var resolvedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case recordID = "record_id"
        case forwardRunID = "forward_run_id"
        case sessionID = "session_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case operations
        case status
        case undoRunID = "undo_run_id"
        case outcomes
        case resolvedAt = "resolved_at"
    }
}

enum AgentUndoRecordStoreError: Error, Equatable {
    case invalidInput
    case duplicateCallID
    case notFound
    case unavailable(AgentUndoRecordStatus)
}

private struct AgentUndoRecordStoreEnvelope: Codable {
    let schemaVersion: Int
    var records: [AgentUndoRecord]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case records
    }
}

final class AgentUndoRecordStore: @unchecked Sendable {
    static let shared = AgentUndoRecordStore()
    static let currentSchemaVersion = 1
    static let defaultStorageKey = "aigtd.agent.undo-records.v1"
    static let defaultAvailabilityInterval: TimeInterval = 10 * 60

    private let defaults: UserDefaults
    private let storageKey: String
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = AgentUndoRecordStore.defaultStorageKey,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.now = now
        withLock {
            var records = loadUnlocked()
            if expireAvailableUnlocked(&records, at: now()) {
                saveUnlocked(records)
            }
        }
    }

    @discardableResult
    func record(
        recordID: UUID = UUID(),
        forwardRunID: UUID,
        sessionID: UUID? = nil,
        successfulOperations: [AgentUndoOperation],
        availabilityInterval: TimeInterval = AgentUndoRecordStore.defaultAvailabilityInterval
    ) throws -> AgentUndoRecord {
        guard successfulOperations.isEmpty == false, availabilityInterval > 0 else {
            throw AgentUndoRecordStoreError.invalidInput
        }
        try validate(successfulOperations)

        return try withLock {
            var records = loadUnlocked()
            let timestamp = now()
            _ = expireAvailableUnlocked(&records, at: timestamp)

            if let index = records.firstIndex(where: { $0.forwardRunID == forwardRunID }) {
                guard records[index].status == .available else {
                    saveUnlocked(records)
                    throw AgentUndoRecordStoreError.unavailable(records[index].status)
                }
                guard records[index].sessionID == sessionID else {
                    saveUnlocked(records)
                    throw AgentUndoRecordStoreError.invalidInput
                }
                let existingCallIDs = Set(records[index].operations.map(\.forwardCallID))
                guard successfulOperations.allSatisfy({ existingCallIDs.contains($0.forwardCallID) == false }) else {
                    saveUnlocked(records)
                    throw AgentUndoRecordStoreError.duplicateCallID
                }
                records[index].operations.append(contentsOf: successfulOperations)
                let record = records[index]
                saveUnlocked(records)
                return record
            }

            guard records.contains(where: { $0.recordID == recordID }) == false else {
                saveUnlocked(records)
                throw AgentUndoRecordStoreError.invalidInput
            }

            let record = AgentUndoRecord(
                recordID: recordID,
                forwardRunID: forwardRunID,
                sessionID: sessionID,
                createdAt: timestamp,
                expiresAt: timestamp.addingTimeInterval(availabilityInterval),
                operations: successfulOperations,
                status: .available,
                undoRunID: nil,
                outcomes: [],
                resolvedAt: nil
            )
            records.append(record)
            saveUnlocked(records)
            return record
        }
    }

    @discardableResult
    func recordSuccessfulOperation(
        forwardRunID: UUID,
        sessionID: UUID? = nil,
        operation: AgentUndoOperation,
        availabilityInterval: TimeInterval = AgentUndoRecordStore.defaultAvailabilityInterval
    ) throws -> AgentUndoRecord {
        try record(
            forwardRunID: forwardRunID,
            sessionID: sessionID,
            successfulOperations: [operation],
            availabilityInterval: availabilityInterval
        )
    }

    func record(id: UUID) -> AgentUndoRecord? {
        withLock {
            var records = loadUnlocked()
            if expireAvailableUnlocked(&records, at: now()) {
                saveUnlocked(records)
            }
            return records.first { $0.recordID == id }
        }
    }

    func record(forwardRunID: UUID) -> AgentUndoRecord? {
        withLock {
            var records = loadUnlocked()
            if expireAvailableUnlocked(&records, at: now()) {
                saveUnlocked(records)
            }
            return records.first { $0.forwardRunID == forwardRunID }
        }
    }

    func records(sessionID: UUID? = nil) -> [AgentUndoRecord] {
        withLock {
            var records = loadUnlocked()
            if expireAvailableUnlocked(&records, at: now()) {
                saveUnlocked(records)
            }
            return records
                .filter { sessionID == nil || $0.sessionID == sessionID }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    func inverseOperations(for recordID: UUID) throws -> [AgentUndoOperation] {
        try withLock {
            var records = loadUnlocked()
            _ = expireAvailableUnlocked(&records, at: now())
            guard let record = records.first(where: { $0.recordID == recordID }) else {
                saveUnlocked(records)
                throw AgentUndoRecordStoreError.notFound
            }
            guard record.status == .available else {
                saveUnlocked(records)
                throw AgentUndoRecordStoreError.unavailable(record.status)
            }
            saveUnlocked(records)
            return Array(record.operations.reversed())
        }
    }

    @discardableResult
    func completeUndo(
        recordID: UUID,
        undoRunID: UUID,
        outcomes: [AgentUndoOperationOutcome]
    ) throws -> AgentUndoRecord {
        try withLock {
            var records = loadUnlocked()
            _ = expireAvailableUnlocked(&records, at: now())
            guard let index = records.firstIndex(where: { $0.recordID == recordID }) else {
                saveUnlocked(records)
                throw AgentUndoRecordStoreError.notFound
            }
            guard records[index].status == .available else {
                saveUnlocked(records)
                throw AgentUndoRecordStoreError.unavailable(records[index].status)
            }
            let operationIDs = Set(records[index].operations.map(\.operationID))
            let outcomeIDs = outcomes.map(\.operationID)
            guard outcomes.isEmpty == false,
                  Set(outcomeIDs).count == outcomeIDs.count,
                  outcomeIDs.allSatisfy(operationIDs.contains) else {
                saveUnlocked(records)
                throw AgentUndoRecordStoreError.invalidInput
            }

            records[index].undoRunID = undoRunID
            records[index].outcomes = outcomes
            records[index].resolvedAt = now()
            if outcomes.count == records[index].operations.count,
               outcomes.allSatisfy({ $0.status == .undone }) {
                records[index].status = .undone
            } else if outcomes.count == records[index].operations.count,
                      outcomes.allSatisfy({ $0.status == .conflict }) {
                records[index].status = .conflict
            } else {
                records[index].status = .partiallyFailed
            }
            let record = records[index]
            saveUnlocked(records)
            return record
        }
    }

    func expireRecords() {
        withLock {
            var records = loadUnlocked()
            if expireAvailableUnlocked(&records, at: now()) {
                saveUnlocked(records)
            }
        }
    }

    func clear() {
        withLock { defaults.removeObject(forKey: storageKey) }
    }

    private func validate(_ operations: [AgentUndoOperation]) throws {
        let callIDs = operations.map(\.forwardCallID)
        let operationIDs = operations.map(\.operationID)
        guard operations.isEmpty == false,
              callIDs.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }),
              Set(callIDs).count == callIDs.count,
              Set(operationIDs).count == operationIDs.count,
              operations.allSatisfy({ $0.inverseOperation.reminderID.isEmpty == false }),
              operations.allSatisfy({ $0.forwardOperation == $0.inverseOperation.forwardOperation }) else {
            throw AgentUndoRecordStoreError.invalidInput
        }
        for operation in operations {
            switch operation.inverseOperation {
            case let .restoreFields(_, changes):
                guard changes.isEmpty == false,
                      Set(changes.map(\.field)).count == changes.count else {
                    throw AgentUndoRecordStoreError.invalidInput
                }
            case let .restoreList(_, originalListID, forwardListID):
                guard originalListID.isEmpty == false,
                      forwardListID.isEmpty == false,
                      originalListID != forwardListID else {
                    throw AgentUndoRecordStoreError.invalidInput
                }
            case let .restoreCompletion(_, originalIsCompleted, forwardIsCompleted):
                guard originalIsCompleted != forwardIsCompleted else {
                    throw AgentUndoRecordStoreError.invalidInput
                }
            case .removeCreatedReminder:
                break
            }
        }
    }

    @discardableResult
    private func expireAvailableUnlocked(_ records: inout [AgentUndoRecord], at timestamp: Date) -> Bool {
        var changed = false
        for index in records.indices
            where records[index].status == .available && records[index].expiresAt <= timestamp {
            records[index].status = .expired
            changed = true
        }
        return changed
    }

    private func loadUnlocked() -> [AgentUndoRecord] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        guard let envelope = try? JSONDecoder().decode(AgentUndoRecordStoreEnvelope.self, from: data),
              envelope.schemaVersion == Self.currentSchemaVersion,
              persistedRecordsAreValid(envelope.records) else {
            defaults.removeObject(forKey: storageKey)
            return []
        }
        return envelope.records
    }

    private func persistedRecordsAreValid(_ records: [AgentUndoRecord]) -> Bool {
        guard Set(records.map(\.recordID)).count == records.count,
              Set(records.map(\.forwardRunID)).count == records.count else {
            return false
        }
        return records.allSatisfy { record in
            guard record.expiresAt > record.createdAt,
                  operationsAreValid(record.operations) else {
                return false
            }
            switch record.status {
            case .available, .expired:
                return record.undoRunID == nil && record.outcomes.isEmpty && record.resolvedAt == nil
            case .undone, .conflict, .partiallyFailed:
                let operationIDs = Set(record.operations.map(\.operationID))
                let outcomeIDs = record.outcomes.map(\.operationID)
                return record.undoRunID != nil
                    && record.resolvedAt != nil
                    && outcomeIDs.isEmpty == false
                    && Set(outcomeIDs).count == outcomeIDs.count
                    && outcomeIDs.allSatisfy(operationIDs.contains)
            }
        }
    }

    private func operationsAreValid(_ operations: [AgentUndoOperation]) -> Bool {
        do {
            try validate(operations)
            return true
        } catch {
            return false
        }
    }

    private func saveUnlocked(_ records: [AgentUndoRecord]) {
        guard records.isEmpty == false else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        let envelope = AgentUndoRecordStoreEnvelope(
            schemaVersion: Self.currentSchemaVersion,
            records: records
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
