import Foundation

struct ReminderSearchRequest: Hashable, Sendable {
    var query: String?
    var listID: String?
    var listTitle: String?
    var dateFrom: Date?
    var dateTo: Date?
    var includeCompleted: Bool
    var limit: Int

    init(
        query: String? = nil,
        listID: String? = nil,
        listTitle: String? = nil,
        dateFrom: Date? = nil,
        dateTo: Date? = nil,
        includeCompleted: Bool = false,
        limit: Int = 50
    ) {
        self.query = query
        self.listID = listID
        self.listTitle = listTitle
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.includeCompleted = includeCompleted
        self.limit = limit
    }
}

struct ReminderQueryPrivacy: Hashable, Sendable {
    var allowsNotes: Bool
    var allowsCompletedReminders: Bool

    init(allowsNotes: Bool = false, allowsCompletedReminders: Bool = false) {
        self.allowsNotes = allowsNotes
        self.allowsCompletedReminders = allowsCompletedReminders
    }
}

struct ReminderQueryResult: Hashable, Sendable {
    let id: String
    let title: String
    let notes: String?
    let dueDate: Date?
    let includesTime: Bool
    let listID: String
    let listTitle: String
    let isCompleted: Bool?
    let lastModifiedAt: Date?
}

struct ReminderQueryService: Sendable {
    private let gateway: any ReminderStoreGateway

    init(gateway: any ReminderStoreGateway) {
        self.gateway = gateway
    }

    func search(
        _ request: ReminderSearchRequest,
        privacy: ReminderQueryPrivacy = ReminderQueryPrivacy()
    ) async throws -> [ReminderQueryResult] {
        try validate(request)
        try await requireReadAccess()

        let normalizedQuery = normalized(request.query)
        let normalizedListTitle = normalized(request.listTitle)
        let records = try await gateway.fetchReminders()

        return records
            .filter { record in
                guard privacy.allowsCompletedReminders || record.isCompleted == false else { return false }
                guard request.includeCompleted || record.isCompleted == false else { return false }
                guard request.listID == nil || record.listID == request.listID else { return false }
                guard normalizedListTitle == nil || normalized(record.listTitle) == normalizedListTitle else { return false }
                if let normalizedQuery, normalized(record.title)?.contains(normalizedQuery) != true { return false }
                if let dateFrom = request.dateFrom, record.dueDate.map({ $0 >= dateFrom }) != true { return false }
                if let dateTo = request.dateTo, record.dueDate.map({ $0 <= dateTo }) != true { return false }
                return true
            }
            .sorted(by: reminderSort)
            .prefix(request.limit)
            .map { filteredResult(from: $0, privacy: privacy) }
    }

    func details(
        forIDs identifiers: [String],
        privacy: ReminderQueryPrivacy = ReminderQueryPrivacy()
    ) async throws -> [ReminderQueryResult] {
        guard identifiers.isEmpty == false, identifiers.count <= 10 else {
            throw ReminderGatewayError.invalidRequest("details requires between 1 and 10 reminder IDs")
        }
        guard identifiers.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else {
            throw ReminderGatewayError.invalidRequest("reminder IDs must not be empty")
        }
        try await requireReadAccess()

        var results: [ReminderQueryResult] = []
        for identifier in identifiers {
            guard let record = try await gateway.reminder(withID: identifier) else { continue }
            guard privacy.allowsCompletedReminders || record.isCompleted == false else { continue }
            results.append(filteredResult(from: record, privacy: privacy))
        }
        return results
    }

    private func requireReadAccess() async throws {
        guard await gateway.canRead else {
            throw ReminderGatewayError.readNotAuthorized
        }
    }

    private func validate(_ request: ReminderSearchRequest) throws {
        guard (1...50).contains(request.limit) else {
            throw ReminderGatewayError.invalidRequest("search limit must be between 1 and 50")
        }
        if let dateFrom = request.dateFrom, let dateTo = request.dateTo, dateFrom > dateTo {
            throw ReminderGatewayError.invalidRequest("dateFrom must not be later than dateTo")
        }
    }

    private func filteredResult(
        from record: ReminderStoreRecord,
        privacy: ReminderQueryPrivacy
    ) -> ReminderQueryResult {
        ReminderQueryResult(
            id: record.id,
            title: record.title,
            notes: privacy.allowsNotes ? record.notes : nil,
            dueDate: record.dueDate,
            includesTime: record.includesTime,
            listID: record.listID,
            listTitle: record.listTitle,
            isCompleted: privacy.allowsCompletedReminders ? record.isCompleted : nil,
            lastModifiedAt: record.lastModifiedAt
        )
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func reminderSort(_ lhs: ReminderStoreRecord, _ rhs: ReminderStoreRecord) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        if lhs.listTitle != rhs.listTitle {
            return lhs.listTitle.localizedCompare(rhs.listTitle) == .orderedAscending
        }
        if lhs.title != rhs.title {
            return lhs.title.localizedCompare(rhs.title) == .orderedAscending
        }
        return lhs.id < rhs.id
    }
}
