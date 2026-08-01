import Foundation
import XCTest
@testable import AIGTDReminders

final class AgentPendingInteractionStoreTests: XCTestCase {
    func testCreatePersistsCompleteInteractionAndUsesDefaultExpiration() throws {
        let clock = PendingInteractionTestClock()
        let fixture = makeFixture(clock: clock)
        let call = makeCall(id: "write-1")
        let priorResult = makeResult(runID: fixture.runID)

        let interaction = try fixture.store.create(
            sessionID: fixture.sessionID,
            runID: fixture.runID,
            goal: "  修改会议时间  ",
            pendingCalls: [call],
            priorResults: [priorResult]
        )

        XCTAssertEqual(interaction.version, 1)
        XCTAssertEqual(interaction.goal, "修改会议时间")
        XCTAssertEqual(interaction.pendingCalls, [call])
        XCTAssertEqual(interaction.priorResults, [priorResult])
        XCTAssertEqual(interaction.createdAt, clock.now)
        XCTAssertEqual(
            interaction.expiresAt,
            clock.now.addingTimeInterval(AgentPendingInteractionStore.defaultExpirationInterval)
        )
        XCTAssertEqual(interaction.status, .active)
        XCTAssertEqual(fixture.store.active(for: fixture.sessionID), interaction)
    }

    func testNewInteractionSupersedesPreviousActiveAndIncrementsVersion() throws {
        let fixture = makeFixture()
        let first = try fixture.store.create(
            sessionID: fixture.sessionID,
            runID: fixture.runID,
            goal: "第一版",
            pendingCalls: [makeCall()]
        )
        let second = try fixture.store.create(
            sessionID: fixture.sessionID,
            runID: UUID(),
            goal: "第二版",
            pendingCalls: [makeCall(id: "second")]
        )

        XCTAssertEqual(second.version, 2)
        XCTAssertEqual(fixture.store.active(for: fixture.sessionID)?.interactionID, second.interactionID)
        XCTAssertEqual(fixture.store.interaction(id: first.interactionID)?.status, .superseded)
        XCTAssertEqual(fixture.store.interactions(for: fixture.sessionID).filter { $0.status == .active }.count, 1)
    }

    func testVersionsIncreaseAfterCancelledSupersededAndExpiredRecords() throws {
        let clock = PendingInteractionTestClock()
        let fixture = makeFixture(clock: clock)
        let first = try fixture.store.create(
            sessionID: fixture.sessionID,
            runID: fixture.runID,
            goal: "v1",
            pendingCalls: [makeCall()]
        )
        _ = try fixture.store.cancel(id: first.interactionID)
        let second = try fixture.store.create(
            sessionID: fixture.sessionID,
            runID: UUID(),
            goal: "v2",
            pendingCalls: [makeCall(id: "v2")],
            expirationInterval: 1
        )
        clock.now.addTimeInterval(2)
        XCTAssertNil(fixture.store.active(for: fixture.sessionID))
        let third = try fixture.store.create(
            sessionID: fixture.sessionID,
            runID: UUID(),
            goal: "v3",
            pendingCalls: [makeCall(id: "v3")]
        )

        XCTAssertEqual(second.version, 2)
        XCTAssertEqual(third.version, 3)
    }

    func testSessionsMaintainIndependentActiveInteractionsAndVersions() throws {
        let fixture = makeFixture()
        let otherSession = UUID()
        let first = try fixture.store.create(
            sessionID: fixture.sessionID,
            runID: fixture.runID,
            goal: "会话一",
            pendingCalls: [makeCall()]
        )
        let other = try fixture.store.create(
            sessionID: otherSession,
            runID: UUID(),
            goal: "会话二",
            pendingCalls: [makeCall(id: "other")]
        )

        XCTAssertEqual(first.version, 1)
        XCTAssertEqual(other.version, 1)
        XCTAssertEqual(fixture.store.active(for: fixture.sessionID)?.interactionID, first.interactionID)
        XCTAssertEqual(fixture.store.active(for: otherSession)?.interactionID, other.interactionID)
    }

    func testCancelRemovesActiveButRetainsCancelledRecord() throws {
        let fixture = makeFixture()
        let interaction = try create(in: fixture)

        let cancelled = try fixture.store.cancel(id: interaction.interactionID)

        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertNil(fixture.store.active(for: fixture.sessionID))
        XCTAssertEqual(fixture.store.interaction(id: interaction.interactionID)?.status, .cancelled)
    }

    func testExplicitSupersedeRemovesActiveButRetainsRecord() throws {
        let fixture = makeFixture()
        let interaction = try create(in: fixture)

        XCTAssertEqual(try fixture.store.supersede(id: interaction.interactionID).status, .superseded)
        XCTAssertNil(fixture.store.active(for: fixture.sessionID))
    }

    func testExpiredInteractionTransitionsToExpiredAndIsNotActive() throws {
        let clock = PendingInteractionTestClock()
        let fixture = makeFixture(clock: clock)
        let interaction = try fixture.store.create(
            sessionID: fixture.sessionID,
            runID: fixture.runID,
            goal: "短期方案",
            pendingCalls: [makeCall()],
            expirationInterval: 10
        )

        clock.now.addTimeInterval(10)

        XCTAssertNil(fixture.store.active(for: fixture.sessionID))
        XCTAssertEqual(fixture.store.interaction(id: interaction.interactionID)?.status, .expired)
    }

    func testExpiredStatusPersistsAcrossStoreInstances() throws {
        let defaults = makeDefaults()
        let clock = PendingInteractionTestClock()
        let first = AgentPendingInteractionStore(defaults: defaults, storageKey: "pending", now: { clock.now })
        let interaction = try first.create(
            sessionID: UUID(),
            runID: UUID(),
            goal: "会过期",
            pendingCalls: [makeCall()],
            expirationInterval: 1
        )
        clock.now.addTimeInterval(2)
        first.expireInteractions()

        let second = AgentPendingInteractionStore(defaults: defaults, storageKey: "pending", now: { clock.now })
        XCTAssertEqual(second.interaction(id: interaction.interactionID)?.status, .expired)
    }

    func testPersistenceRestoresUniqueActiveInteraction() throws {
        let defaults = makeDefaults()
        let sessionID = UUID()
        let first = AgentPendingInteractionStore(defaults: defaults, storageKey: "pending")
        let interaction = try first.create(
            sessionID: sessionID,
            runID: UUID(),
            goal: "重启恢复",
            pendingCalls: [makeCall()]
        )

        let second = AgentPendingInteractionStore(defaults: defaults, storageKey: "pending")

        XCTAssertEqual(second.active(for: sessionID), interaction)
    }

    func testCreateRejectsInvalidInputWithoutChangingExistingActive() throws {
        let fixture = makeFixture()
        let existing = try create(in: fixture)

        XCTAssertThrowsError(try fixture.store.create(
            sessionID: fixture.sessionID,
            runID: UUID(),
            goal: "   ",
            pendingCalls: [makeCall(id: "new")]
        ))
        XCTAssertThrowsError(try fixture.store.create(
            sessionID: fixture.sessionID,
            runID: UUID(),
            goal: "空操作",
            pendingCalls: []
        ))
        XCTAssertThrowsError(try fixture.store.create(
            sessionID: fixture.sessionID,
            runID: UUID(),
            goal: "重复调用",
            pendingCalls: [makeCall(id: "same"), makeCall(id: "same")]
        ))
        XCTAssertThrowsError(try fixture.store.create(
            sessionID: fixture.sessionID,
            runID: UUID(),
            goal: "错误期限",
            pendingCalls: [makeCall(id: "expiry")],
            expirationInterval: 0
        ))

        XCTAssertEqual(fixture.store.active(for: fixture.sessionID)?.interactionID, existing.interactionID)
    }

    func testTerminalInteractionCannotTransitionAgain() throws {
        let fixture = makeFixture()
        let interaction = try create(in: fixture)
        _ = try fixture.store.cancel(id: interaction.interactionID)

        XCTAssertThrowsError(try fixture.store.supersede(id: interaction.interactionID)) {
            XCTAssertEqual(($0 as? AgentToolError)?.category, .staleReference)
        }
    }

    func testMissingInteractionReturnsNotFound() {
        let store = AgentPendingInteractionStore(defaults: makeDefaults(), storageKey: "pending")

        XCTAssertThrowsError(try store.cancel(id: UUID())) {
            XCTAssertEqual(($0 as? AgentToolError)?.category, .notFound)
        }
    }

    func testCorruptPersistenceRecoversAndOnlyClearsOwnedKey() {
        let defaults = makeDefaults()
        defaults.set(Data("not-json".utf8), forKey: "pending")
        defaults.set("keep", forKey: "chat-history")

        let store = AgentPendingInteractionStore(defaults: defaults, storageKey: "pending")

        XCTAssertTrue(store.interactions().isEmpty)
        XCTAssertNil(defaults.object(forKey: "pending"))
        XCTAssertEqual(defaults.string(forKey: "chat-history"), "keep")
    }

    func testUnsupportedSchemaRecoversSafely() throws {
        let defaults = makeDefaults()
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": 999, "interactions": []])
        defaults.set(data, forKey: "pending")

        let store = AgentPendingInteractionStore(defaults: defaults, storageKey: "pending")

        XCTAssertTrue(store.interactions().isEmpty)
        XCTAssertNil(defaults.object(forKey: "pending"))
    }

    func testConcurrentCreationLeavesExactlyOneActiveAndMonotonicVersions() {
        let fixture = makeFixture()
        let count = 40

        DispatchQueue.concurrentPerform(iterations: count) { index in
            _ = try? fixture.store.create(
                sessionID: fixture.sessionID,
                runID: UUID(),
                goal: "版本 \(index)",
                pendingCalls: [makeCall(id: "call-\(index)")]
            )
        }

        let interactions = fixture.store.interactions(for: fixture.sessionID)
        XCTAssertEqual(interactions.count, count)
        XCTAssertEqual(interactions.filter { $0.status == .active }.count, 1)
        XCTAssertEqual(Set(interactions.map(\.version)), Set(1...count))
    }

    func testClearAndCustomStorageKeyAreScoped() throws {
        let defaults = makeDefaults()
        let store = AgentPendingInteractionStore(defaults: defaults, storageKey: "custom-pending")
        _ = try store.create(
            sessionID: UUID(),
            runID: UUID(),
            goal: "自定义键",
            pendingCalls: [makeCall()]
        )
        defaults.set(true, forKey: "privacy-setting")

        XCTAssertNotNil(defaults.data(forKey: "custom-pending"))
        XCTAssertNil(defaults.data(forKey: AgentPendingInteractionStore.defaultStorageKey))
        store.clear()
        XCTAssertTrue(store.interactions().isEmpty)
        XCTAssertTrue(defaults.bool(forKey: "privacy-setting"))
    }

    private func create(in fixture: PendingInteractionFixture) throws -> AgentPendingInteraction {
        try fixture.store.create(
            sessionID: fixture.sessionID,
            runID: fixture.runID,
            goal: "确认修改",
            pendingCalls: [makeCall()]
        )
    }

    private func makeFixture(
        clock: PendingInteractionTestClock = PendingInteractionTestClock()
    ) -> PendingInteractionFixture {
        PendingInteractionFixture(
            store: AgentPendingInteractionStore(
                defaults: makeDefaults(),
                storageKey: "pending",
                now: { clock.now }
            ),
            sessionID: UUID(),
            runID: UUID()
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AgentPendingInteractionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

private struct PendingInteractionFixture {
    let store: AgentPendingInteractionStore
    let sessionID: UUID
    let runID: UUID
}

private final class PendingInteractionTestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 2_000_000_000)
}

private func makeCall(id: String = "write") -> AgentToolCall {
    AgentToolCall(
        callID: id,
        tool: .updateReminder,
        arguments: AgentToolArguments(["reminder_id": .string("reminder-1")])
    )
}

private func makeResult(runID: UUID) -> AgentToolResult {
    AgentToolResult(
        runID: runID,
        callID: "read-1",
        tool: .searchReminders,
        status: .success,
        result: AgentToolArguments(["count": .integer(1)])
    )
}
