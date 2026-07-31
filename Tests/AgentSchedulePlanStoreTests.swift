import XCTest
@testable import AIGTDReminders

final class AgentSchedulePlanStoreTests: XCTestCase {
    func testCreateAndLoadPlan() throws {
        let fixture = makeFixture()
        let plan = try fixture.store.create(runID: fixture.runID, items: [fixture.item])

        XCTAssertEqual(try fixture.store.load(id: plan.id), plan)
        XCTAssertEqual(plan.status, .awaitingConfirmation)
    }

    func testCreateRejectsEmptyPlan() {
        let fixture = makeFixture()
        XCTAssertThrowsError(try fixture.store.create(runID: fixture.runID, items: [])) {
            XCTAssertEqual(($0 as? AgentToolError)?.category, .invalidArguments)
        }
    }

    func testCreateRejectsDuplicateItemIDs() {
        let fixture = makeFixture()
        XCTAssertThrowsError(try fixture.store.create(runID: fixture.runID, items: [fixture.item, fixture.item]))
    }

    func testCreateRejectsUnknownDependency() {
        let fixture = makeFixture()
        let item = makeItem(id: "two", dependencyIDs: ["missing"])
        XCTAssertThrowsError(try fixture.store.create(runID: fixture.runID, items: [item]))
    }

    func testLoadRejectsWrongRun() throws {
        let fixture = makeFixture()
        let plan = try fixture.store.create(runID: fixture.runID, items: [fixture.item])
        XCTAssertThrowsError(try fixture.store.load(id: plan.id, runID: UUID())) {
            XCTAssertEqual(($0 as? AgentToolError)?.category, .staleReference)
        }
    }

    func testLoadRejectsWrongSession() throws {
        let fixture = makeFixture()
        let sessionID = UUID()
        let plan = try fixture.store.create(runID: fixture.runID, sessionID: sessionID, items: [fixture.item])
        XCTAssertThrowsError(try fixture.store.load(id: plan.id, sessionID: UUID())) {
            XCTAssertEqual(($0 as? AgentToolError)?.category, .staleReference)
        }
    }

    func testExpiredPlanReturnsPlanExpiredAndIsRemoved() throws {
        let clock = TestClock()
        let fixture = makeFixture(clock: clock)
        let plan = try fixture.store.create(runID: fixture.runID, items: [fixture.item])
        clock.now = clock.now.addingTimeInterval(24 * 60 * 60 + 1)

        XCTAssertThrowsError(try fixture.store.load(id: plan.id)) {
            XCTAssertEqual(($0 as? AgentToolError)?.category, .planExpired)
        }
        XCTAssertThrowsError(try fixture.store.load(id: plan.id)) {
            XCTAssertEqual(($0 as? AgentToolError)?.category, .notFound)
        }
    }

    func testRecordAllAppliedAggregatesSucceeded() throws {
        let fixture = makeFixture()
        let plan = try fixture.store.create(runID: fixture.runID, items: [fixture.item])
        let updated = try fixture.store.record(planID: plan.id, itemID: fixture.item.id, status: .applied)

        XCTAssertEqual(updated.status, .succeeded)
        XCTAssertEqual(updated.successfulCount, 1)
    }

    func testRecordPartialFailureAggregatesPartial() throws {
        let fixture = makeFixture()
        let second = makeItem(id: "two")
        let plan = try fixture.store.create(runID: fixture.runID, items: [fixture.item, second])
        _ = try fixture.store.record(planID: plan.id, itemID: fixture.item.id, status: .applied)
        let updated = try fixture.store.record(
            planID: plan.id,
            itemID: second.id,
            status: .failed,
            error: AgentToolError(category: .notFound, userVisibleMessage: "不存在")
        )

        XCTAssertEqual(updated.status, .partial)
        XCTAssertEqual(updated.failedCount, 1)
        XCTAssertEqual(updated.items[1].errorCategory, .notFound)
    }

    func testMarkExecutingThenCancelCancelsPendingItems() throws {
        let fixture = makeFixture()
        let plan = try fixture.store.create(runID: fixture.runID, items: [fixture.item])
        XCTAssertEqual(try fixture.store.markExecuting(id: plan.id).status, .executing)

        let cancelled = try fixture.store.cancel(id: plan.id)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(cancelled.items.first?.status, .cancelled)
    }

    func testSucceededPlanCanBeMarkedExecutingWithoutChangingResult() throws {
        let fixture = makeFixture()
        let plan = try fixture.store.create(runID: fixture.runID, items: [fixture.item])
        _ = try fixture.store.record(planID: plan.id, itemID: fixture.item.id, status: .unchanged)

        XCTAssertEqual(try fixture.store.markExecuting(id: plan.id).status, .succeeded)
    }

    func testCorruptPersistenceIsClearedWithoutThrowing() {
        let defaults = makeDefaults()
        defaults.set(Data("bad".utf8), forKey: "plans")
        let store = AgentSchedulePlanStore(defaults: defaults, storageKey: "plans")

        XCTAssertThrowsError(try store.load(id: UUID())) {
            XCTAssertEqual(($0 as? AgentToolError)?.category, .notFound)
        }
        XCTAssertNil(defaults.object(forKey: "plans"))
    }

    func testPlanPersistsAcrossStoreInstances() throws {
        let defaults = makeDefaults()
        let first = AgentSchedulePlanStore(defaults: defaults, storageKey: "plans")
        let plan = try first.create(runID: UUID(), items: [makeItem()])
        let second = AgentSchedulePlanStore(defaults: defaults, storageKey: "plans")

        XCTAssertEqual(try second.load(id: plan.id).id, plan.id)
    }

    private func makeFixture(clock: TestClock = TestClock()) -> Fixture {
        Fixture(
            store: AgentSchedulePlanStore(defaults: makeDefaults(), storageKey: "plans", now: { clock.now }),
            runID: UUID(),
            item: makeItem()
        )
    }

    private func makeItem(id: String = "one", dependencyIDs: [String] = []) -> AgentSchedulePlanItem {
        AgentSchedulePlanItem(
            id: id,
            reminderID: "reminder-\(id)",
            originalDueDate: Date(timeIntervalSince1970: 100),
            targetDueDate: Date(timeIntervalSince1970: 200),
            includesTime: true,
            dependencyIDs: dependencyIDs
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AgentSchedulePlanStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private struct Fixture {
        let store: AgentSchedulePlanStore
        let runID: UUID
        let item: AgentSchedulePlanItem
    }
}

private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000)
}
