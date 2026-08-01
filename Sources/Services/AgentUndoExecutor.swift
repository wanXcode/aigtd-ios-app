import Foundation

struct AgentUndoExecutionResult: Equatable, Sendable {
    let undoRunID: UUID
    let record: AgentUndoRecord

    var outcomes: [AgentUndoOperationOutcome] { record.outcomes }
}

struct AgentUndoExecutor: Sendable {
    private let gateway: any ReminderStoreGateway
    private let writer: any ReminderToolWriter
    private let store: AgentUndoRecordStore
    private let calendar: Calendar

    init(
        gateway: any ReminderStoreGateway,
        writer: any ReminderToolWriter,
        store: AgentUndoRecordStore,
        calendar: Calendar = .current
    ) {
        self.gateway = gateway
        self.writer = writer
        self.store = store
        self.calendar = calendar
    }

    func execute(recordID: UUID, undoRunID: UUID = UUID()) async throws -> AgentUndoExecutionResult {
        let operations = try store.inverseOperations(for: recordID)
        var outcomes: [AgentUndoOperationOutcome] = []
        outcomes.reserveCapacity(operations.count)

        for operation in operations {
            outcomes.append(await execute(operation))
        }

        let record = try store.completeUndo(
            recordID: recordID,
            undoRunID: undoRunID,
            outcomes: outcomes
        )
        return AgentUndoExecutionResult(undoRunID: undoRunID, record: record)
    }

    private func execute(_ operation: AgentUndoOperation) async -> AgentUndoOperationOutcome {
        guard await gateway.canRead, await gateway.canWrite, await writer.canWrite else {
            return failed(operation)
        }

        do {
            guard let current = try await gateway.reminder(withID: operation.inverseOperation.reminderID) else {
                return conflict(operation, reason: .taskMissing)
            }
            guard matchesForwardSnapshot(current, version: taskVersion(for: operation.inverseOperation)) else {
                return conflict(operation, reason: .taskChanged)
            }

            switch operation.inverseOperation {
            case .removeCreatedReminder:
                try await writer.delete(id: current.id)

            case let .restoreFields(_, changes):
                guard changes.allSatisfy({ matchesForwardValue($0, current: current) }) else {
                    return conflict(operation, reason: .taskChanged)
                }
                guard let mutation = restorationMutation(changes, current: current) else {
                    return failed(operation)
                }
                try await writer.update(id: current.id, mutation: mutation)

            case let .restoreList(_, originalListID, forwardListID):
                guard current.listID == forwardListID else {
                    return conflict(operation, reason: .taskChanged)
                }
                try await writer.move(id: current.id, listID: originalListID, listTitle: nil)

            case let .restoreCompletion(_, originalIsCompleted, forwardIsCompleted):
                guard current.isCompleted == forwardIsCompleted else {
                    return conflict(operation, reason: .taskChanged)
                }
                try await writer.setCompleted(id: current.id, isCompleted: originalIsCompleted)
            }

            return AgentUndoOperationOutcome(operationID: operation.id, status: .undone, reason: nil)
        } catch let error as ReminderGatewayError {
            switch error {
            case .reminderNotFound:
                return conflict(operation, reason: .taskMissing)
            case .listNotFound:
                return conflict(operation, reason: .listMissing)
            case .preconditionConflict:
                return conflict(operation, reason: .taskChanged)
            default:
                return failed(operation)
            }
        } catch {
            return failed(operation)
        }
    }

    private func taskVersion(for inverse: AgentUndoInverseOperation) -> AgentUndoTaskVersion {
        switch inverse {
        case let .removeCreatedReminder(version),
             let .restoreFields(version, _),
             let .restoreList(version, _, _),
             let .restoreCompletion(version, _, _):
            return version
        }
    }

    private func matchesForwardSnapshot(
        _ current: ReminderStoreRecord,
        version: AgentUndoTaskVersion
    ) -> Bool {
        if let title = version.title, current.title != title { return false }
        if version.hasDueDateSnapshot {
            let expected = version.dueDate.map(AgentUndoFieldValue.date) ?? .none
            guard matchesDate(expected, current: current.dueDate) else { return false }
        }
        if let includesTime = version.includesTime, current.includesTime != includesTime { return false }
        if let listID = version.listID, current.listID != listID { return false }
        if let isCompleted = version.isCompleted, current.isCompleted != isCompleted { return false }
        if let notesDigest = version.notesDigest,
           AgentUndoNotesDigest.digest(current.notes) != notesDigest {
            return false
        }
        guard let snapshotModifiedAt = version.lastModifiedAt,
              let modifiedAt = current.lastModifiedAt else {
            return true
        }
        // EventKit can round or slightly shift modification timestamps. Only a timestamp
        // more than one minute newer is strong enough to reject an otherwise valid undo.
        return modifiedAt <= snapshotModifiedAt.addingTimeInterval(60)
    }

    private func matchesForwardValue(_ change: AgentUndoFieldChange, current: ReminderStoreRecord) -> Bool {
        switch change.field {
        case .title:
            return matchesString(change.forwardValue, current: current.title, allowsNil: false)
        case .notes:
            return matchesString(change.forwardValue, current: current.notes, allowsNil: true)
        case .dueDate:
            return matchesDate(change.forwardValue, current: current.dueDate)
        case .includesTime:
            guard case let .bool(expected) = change.forwardValue else { return false }
            return current.includesTime == expected
        }
    }

    private func matchesString(
        _ expected: AgentUndoFieldValue,
        current: String?,
        allowsNil: Bool
    ) -> Bool {
        switch expected {
        case let .string(value):
            if allowsNil && value.isEmpty { return current?.isEmpty != false }
            return current == value
        case .none:
            return allowsNil && current?.isEmpty != false
        case .date:
            return false
        case .bool:
            return false
        }
    }

    private func matchesDate(_ expected: AgentUndoFieldValue, current: Date?) -> Bool {
        switch expected {
        case let .date(value):
            guard let current else { return false }
            return calendar.isDate(current, equalTo: value, toGranularity: .minute)
        case .none:
            return current == nil
        case .string:
            return false
        case .bool:
            return false
        }
    }

    private func restorationMutation(
        _ changes: [AgentUndoFieldChange],
        current: ReminderStoreRecord
    ) -> ReminderToolMutation? {
        var mutation = ReminderToolMutation()
        var restoredIncludesTime: Bool?

        for change in changes {
            switch (change.field, change.originalValue) {
            case let (.title, .string(value)):
                mutation.title = value
            case let (.notes, .string(value)):
                mutation.notes = value
            case (.notes, .none):
                mutation.notes = ""
            case let (.dueDate, .date(value)):
                mutation.dueDate = value
                mutation.includesTime = current.includesTime
            case (.dueDate, .none):
                mutation.clearsDueDate = true
            case let (.includesTime, .bool(value)):
                restoredIncludesTime = value
            default:
                return nil
            }
        }

        if let restoredIncludesTime {
            guard mutation.dueDate != nil || mutation.clearsDueDate else { return nil }
            mutation.includesTime = restoredIncludesTime
        }

        return mutation
    }

    private func conflict(
        _ operation: AgentUndoOperation,
        reason: AgentUndoOutcomeReason
    ) -> AgentUndoOperationOutcome {
        AgentUndoOperationOutcome(operationID: operation.id, status: .conflict, reason: reason)
    }

    private func failed(_ operation: AgentUndoOperation) -> AgentUndoOperationOutcome {
        AgentUndoOperationOutcome(operationID: operation.id, status: .failed, reason: .operationFailed)
    }
}
