@preconcurrency import EventKit
import Foundation

protocol ReminderStoreGateway: Sendable {
    var canRead: Bool { get async }
    var canWrite: Bool { get async }

    func fetchReminders() async throws -> [ReminderStoreRecord]
    func reminder(withID identifier: String) async throws -> ReminderStoreRecord?
}

struct ReminderStoreRecord: Hashable, Sendable {
    let id: String
    let title: String
    let notes: String?
    let dueDate: Date?
    let includesTime: Bool
    let listID: String
    let listTitle: String
    let isCompleted: Bool
    let lastModifiedAt: Date?
}

struct ReminderWritePreconditions: Codable, Hashable, Sendable {
    var expectedListID: String?
    var expectedDueDate: Date?
    var expectedCompletion: Bool?
    var mustExist: Bool

    init(
        expectedListID: String? = nil,
        expectedDueDate: Date? = nil,
        expectedCompletion: Bool? = nil,
        mustExist: Bool = true
    ) {
        self.expectedListID = expectedListID
        self.expectedDueDate = expectedDueDate
        self.expectedCompletion = expectedCompletion
        self.mustExist = mustExist
    }

    func conflicts(
        with record: ReminderStoreRecord?,
        calendar: Calendar = .current
    ) -> [ReminderPreconditionConflict] {
        guard let record else {
            return mustExist ? [.missingReminder] : []
        }

        var conflicts: [ReminderPreconditionConflict] = []
        if let expectedListID, record.listID != expectedListID {
            conflicts.append(.listID(expected: expectedListID, actual: record.listID))
        }
        if let expectedDueDate,
           record.dueDate.map({ calendar.isDate($0, equalTo: expectedDueDate, toGranularity: .minute) }) != true {
            conflicts.append(.dueDate(expected: expectedDueDate, actual: record.dueDate))
        }
        if let expectedCompletion, record.isCompleted != expectedCompletion {
            conflicts.append(.completion(expected: expectedCompletion, actual: record.isCompleted))
        }
        return conflicts
    }
}

enum ReminderPreconditionConflict: Hashable, Sendable {
    case missingReminder
    case listID(expected: String, actual: String)
    case dueDate(expected: Date, actual: Date?)
    case completion(expected: Bool, actual: Bool)
}

enum ReminderGatewayError: Error, Equatable, Sendable {
    case readNotAuthorized
    case writeNotAuthorized
    case invalidRequest(String)
    case reminderNotFound(String)
    case listNotFound(String)
    case preconditionConflict([ReminderPreconditionConflict])
    case storeUnavailable
    case operationFailed
}

actor EventKitReminderStoreGateway: ReminderStoreGateway {
    private let service: ReminderStoreService

    init(service: ReminderStoreService = ReminderStoreService()) {
        self.service = service
    }

    var canRead: Bool {
        Self.authorizationCapabilities.canRead
    }

    var canWrite: Bool {
        Self.authorizationCapabilities.canWrite
    }

    func fetchReminders() async throws -> [ReminderStoreRecord] {
        guard canRead else { throw ReminderGatewayError.readNotAuthorized }
        do {
            return try await service.fetchGatewayReminders()
        } catch let error as ReminderGatewayError {
            throw error
        } catch {
            throw ReminderGatewayError.operationFailed
        }
    }

    func reminder(withID identifier: String) async throws -> ReminderStoreRecord? {
        guard canRead else { throw ReminderGatewayError.readNotAuthorized }
        guard identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ReminderGatewayError.invalidRequest("reminder ID must not be empty")
        }
        do {
            return try service.fetchGatewayReminder(withID: identifier)
        } catch let error as ReminderGatewayError {
            throw error
        } catch {
            throw ReminderGatewayError.operationFailed
        }
    }

    private static var authorizationCapabilities: (canRead: Bool, canWrite: Bool) {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        return (status == .fullAccess, status == .fullAccess || status == .writeOnly)
    }
}

extension ReminderStoreService {
    fileprivate func fetchGatewayReminders() async throws -> [ReminderStoreRecord] {
        let store = EKEventStore()
        store.refreshSourcesIfNecessary()
        let predicate = store.predicateForReminders(in: nil)

        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(ReminderStoreRecord.init))
            }
        }
    }

    fileprivate func fetchGatewayReminder(withID identifier: String) throws -> ReminderStoreRecord? {
        let store = EKEventStore()
        store.refreshSourcesIfNecessary()
        return (store.calendarItem(withIdentifier: identifier) as? EKReminder)
            .map(ReminderStoreRecord.init)
    }
}

private extension ReminderStoreRecord {
    init(reminder: EKReminder) {
        let dueComponents = reminder.dueDateComponents
        self.init(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            notes: reminder.notes,
            dueDate: dueComponents?.date,
            includesTime: dueComponents?.hour != nil || dueComponents?.minute != nil,
            listID: reminder.calendar.calendarIdentifier,
            listTitle: reminder.calendar.title,
            isCompleted: reminder.isCompleted,
            lastModifiedAt: reminder.lastModifiedDate
        )
    }
}
