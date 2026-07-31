import XCTest
@testable import AIGTDReminders

final class ReminderQueryServiceTests: XCTestCase {
    func testWriteOnlyGatewayCannotBeUsedForReads() async {
        let gateway = InMemoryReminderStoreGateway(canRead: false, canWrite: true, records: [makeRecord(id: "one")])
        let service = ReminderQueryService(gateway: gateway)

        await XCTAssertThrowsErrorAsync(try await service.search(ReminderSearchRequest())) { error in
            XCTAssertEqual(error as? ReminderGatewayError, .readNotAuthorized)
        }
        let fetchCount = await gateway.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testDetailsByStableIDAreNotLimitedToFirstFiftySearchItems() async throws {
        let records = (0..<60).map { makeRecord(id: "id-\($0)", title: "Task \($0)") }
        let service = ReminderQueryService(
            gateway: InMemoryReminderStoreGateway(canRead: true, canWrite: true, records: records)
        )

        let searchResults = try await service.search(ReminderSearchRequest(limit: 50))
        let details = try await service.details(forIDs: ["id-59"])

        XCTAssertEqual(searchResults.count, 50)
        XCTAssertEqual(details.map(\.id), ["id-59"])
    }

    func testStructuredSearchFiltersTitleListDatesAndCompletion() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 2_000)
        let records = [
            makeRecord(id: "match", title: "Project Meeting", dueDate: start.addingTimeInterval(100), listID: "work", listTitle: "Work"),
            makeRecord(id: "wrong-title", title: "Project Review", dueDate: start.addingTimeInterval(100), listID: "work", listTitle: "Work"),
            makeRecord(id: "wrong-list", title: "Project Meeting", dueDate: start.addingTimeInterval(100), listID: "home", listTitle: "Home"),
            makeRecord(id: "wrong-date", title: "Project Meeting", dueDate: end.addingTimeInterval(100), listID: "work", listTitle: "Work"),
            makeRecord(id: "completed", title: "Project Meeting", dueDate: start.addingTimeInterval(100), listID: "work", listTitle: "Work", isCompleted: true)
        ]
        let service = ReminderQueryService(
            gateway: InMemoryReminderStoreGateway(canRead: true, canWrite: true, records: records)
        )

        let results = try await service.search(
            ReminderSearchRequest(
                query: " meeting ",
                listID: "work",
                listTitle: "work",
                dateFrom: start,
                dateTo: end,
                includeCompleted: false
            )
        )

        XCTAssertEqual(results.map(\.id), ["match"])
    }

    func testPrivacyFiltersNotesCompletedItemsAndCompletionState() async throws {
        let records = [
            makeRecord(id: "open", notes: "private note"),
            makeRecord(id: "completed", notes: "completed secret", isCompleted: true)
        ]
        let service = ReminderQueryService(
            gateway: InMemoryReminderStoreGateway(canRead: true, canWrite: true, records: records)
        )

        let privateResults = try await service.search(
            ReminderSearchRequest(includeCompleted: true),
            privacy: ReminderQueryPrivacy(allowsNotes: false, allowsCompletedReminders: false)
        )
        XCTAssertEqual(privateResults.map(\.id), ["open"])
        XCTAssertNil(privateResults.first?.notes)
        XCTAssertNil(privateResults.first?.isCompleted)

        let allowedDetails = try await service.details(
            forIDs: ["completed"],
            privacy: ReminderQueryPrivacy(allowsNotes: true, allowsCompletedReminders: true)
        )
        XCTAssertEqual(allowedDetails.first?.notes, "completed secret")
        XCTAssertEqual(allowedDetails.first?.isCompleted, true)
    }

    func testWritePreconditionsReportStructuredConflicts() {
        let current = makeRecord(
            id: "target",
            dueDate: Date(timeIntervalSince1970: 2_000),
            listID: "actual-list",
            isCompleted: false
        )
        let expectedDate = Date(timeIntervalSince1970: 1_000)
        let preconditions = ReminderWritePreconditions(
            expectedListID: "expected-list",
            expectedDueDate: expectedDate,
            expectedCompletion: true,
            mustExist: true
        )

        XCTAssertEqual(
            preconditions.conflicts(with: current),
            [
                .listID(expected: "expected-list", actual: "actual-list"),
                .dueDate(expected: expectedDate, actual: current.dueDate),
                .completion(expected: true, actual: false)
            ]
        )
        XCTAssertEqual(preconditions.conflicts(with: nil), [.missingReminder])
    }
}

private actor InMemoryReminderStoreGateway: ReminderStoreGateway {
    let canRead: Bool
    let canWrite: Bool
    private let recordsByID: [String: ReminderStoreRecord]
    private(set) var fetchCount = 0

    init(canRead: Bool, canWrite: Bool, records: [ReminderStoreRecord]) {
        self.canRead = canRead
        self.canWrite = canWrite
        self.recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    func fetchReminders() throws -> [ReminderStoreRecord] {
        fetchCount += 1
        guard canRead else { throw ReminderGatewayError.readNotAuthorized }
        return Array(recordsByID.values)
    }

    func reminder(withID identifier: String) throws -> ReminderStoreRecord? {
        guard canRead else { throw ReminderGatewayError.readNotAuthorized }
        return recordsByID[identifier]
    }
}

private func makeRecord(
    id: String,
    title: String = "Task",
    notes: String? = nil,
    dueDate: Date? = nil,
    listID: String = "inbox",
    listTitle: String = "Inbox",
    isCompleted: Bool = false
) -> ReminderStoreRecord {
    ReminderStoreRecord(
        id: id,
        title: title,
        notes: notes,
        dueDate: dueDate,
        includesTime: dueDate != nil,
        listID: listID,
        listTitle: listTitle,
        isCompleted: isCompleted,
        lastModifiedAt: nil
    )
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
