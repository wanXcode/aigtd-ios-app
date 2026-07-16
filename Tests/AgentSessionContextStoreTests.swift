import Foundation
import XCTest
@testable import AIGTDReminders

final class AgentSessionContextStoreTests: XCTestCase {
    func testSnapshotRoundTripsWithoutLosingContractFields() throws {
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let sessionID = UUID()
        let snapshot = AgentContextSnapshot(
            generatedAt: now,
            timeZoneIdentifier: "Asia/Shanghai",
            session: SessionContext(id: sessionID, title: "主会话", createdAt: now, updatedAt: now),
            recentTurns: [AgentConversationTurn(role: "user", text: "把刚才那条改到明天")],
            sessionSummary: nil,
            reminders: [],
            references: .empty,
            preferences: [],
            documents: AgentDocumentContext(prompt: "p", memory: "m", solu: "s", operatingGuide: "o"),
            privacy: ContextPrivacyDescriptor(
                includesNotes: false,
                includesCompletedReminders: false,
                maximumReminderCount: 40,
                reminderSnapshotIsStale: false,
                originalReminderCount: 0,
                includedReminderCount: 0,
                truncatedReminderCount: 0,
                truncatedTurnCount: 0
            )
        )

        let decoded = try JSONDecoder().decode(
            AgentContextSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testContextsAreIsolatedBySession() {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let store = AgentSessionContextStore(defaults: defaults, now: { now })
        let firstID = UUID()
        let secondID = UUID()

        store.update(sessionID: firstID, references: references(reminderID: "first", now: now))
        store.update(sessionID: secondID, references: references(reminderID: "second", now: now))

        XCTAssertEqual(store.context(for: firstID)?.references.recentlyCreated?.reminderID, "first")
        XCTAssertEqual(store.context(for: secondID)?.references.recentlyCreated?.reminderID, "second")
    }

    func testContextsOlderThanThirtyDaysArePruned() {
        let defaults = makeDefaults()
        let start = Date(timeIntervalSince1970: 2_100_000_000)
        let sessionID = UUID()
        AgentSessionContextStore(defaults: defaults, now: { start }).update(sessionID: sessionID)

        let later = start.addingTimeInterval(31 * 24 * 60 * 60)
        let store = AgentSessionContextStore(defaults: defaults, now: { later })

        XCTAssertNil(store.context(for: sessionID))
    }

    func testStaleReferencesOlderThanSevenDaysAreRemoved() {
        let defaults = makeDefaults()
        let start = Date(timeIntervalSince1970: 2_100_000_000)
        let sessionID = UUID()
        var referenceContext = references(reminderID: "stale", now: start)
        referenceContext.recentlyCreated?.isStale = true
        referenceContext.recentlyCreated?.staleSince = start
        AgentSessionContextStore(defaults: defaults, now: { start }).update(
            sessionID: sessionID,
            references: referenceContext
        )

        let later = start.addingTimeInterval(8 * 24 * 60 * 60)
        let store = AgentSessionContextStore(defaults: defaults, now: { later })

        XCTAssertNil(store.context(for: sessionID)?.references.recentlyCreated)
    }

    func testCorruptContextDataRecoversToEmptyState() {
        let defaults = makeDefaults()
        let key = "context-test"
        defaults.set(Data("not-json".utf8), forKey: key)
        let store = AgentSessionContextStore(defaults: defaults, storageKey: key)

        XCTAssertNil(store.context(for: UUID()))
        XCTAssertNil(defaults.data(forKey: key))
    }

    func testPrivacyDefaultsAndBounds() {
        let defaults = makeDefaults()
        let store = AgentContextPrivacyStore(defaults: defaults)

        XCTAssertEqual(store.settings(), .standard)
        XCTAssertFalse(store.settings().includesNotes)
        XCTAssertFalse(store.settings().includesCompletedReminders)
        XCTAssertEqual(store.settings().maximumReminderCount, 40)

        store.save(AgentContextPrivacySettings(includesNotes: true, includesCompletedReminders: true, maximumReminderCount: 500))
        XCTAssertEqual(store.settings().maximumReminderCount, 100)
    }

    func testCorruptPrivacyDataRestoresSafeDefaults() {
        let defaults = makeDefaults()
        let key = "privacy-test"
        defaults.set(Data("broken".utf8), forKey: key)
        let store = AgentContextPrivacyStore(defaults: defaults, storageKey: key)

        XCTAssertEqual(store.settings(), .standard)
        XCTAssertNil(defaults.data(forKey: key))
    }

    func testUserMemoryUpsertsByCategoryAndCanBeCleared() {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let store = AgentUserMemoryStore(defaults: defaults, now: { now })

        store.upsert(category: .defaultTaskTime, value: "上午 9 点", sourceMessageID: UUID())
        store.upsert(category: .defaultTaskTime, value: "上午 10 点", sourceMessageID: UUID())

        XCTAssertEqual(store.items().count, 1)
        XCTAssertEqual(store.items().first?.value, "上午 10 点")
        store.clear()
        XCTAssertTrue(store.items().isEmpty)
    }

    func testTransactionRulesAppendAndExactDuplicatesAreDeduplicated() {
        let defaults = makeDefaults()
        let store = AgentUserMemoryStore(defaults: defaults)

        let first = store.upsert(
            category: .transactionRule,
            value: "所有删除任务都要先确认",
            sourceMessageID: UUID()
        )
        store.upsert(
            category: .transactionRule,
            value: "只整理项目清单里的未完成任务",
            sourceMessageID: UUID()
        )
        let duplicate = store.upsert(
            category: .transactionRule,
            value: "所有删除任务都要先确认",
            sourceMessageID: UUID()
        )

        XCTAssertEqual(store.items().count, 2)
        XCTAssertEqual(duplicate.id, first.id)
        XCTAssertEqual(
            Set(store.items().map(\.value)),
            Set(["所有删除任务都要先确认", "只整理项目清单里的未完成任务"])
        )
    }

    func testEditingOneTransactionRuleDoesNotOverwriteAnother() throws {
        let defaults = makeDefaults()
        let store = AgentUserMemoryStore(defaults: defaults)
        let first = store.upsert(category: .transactionRule, value: "规则一", sourceMessageID: nil)
        let second = store.upsert(category: .transactionRule, value: "规则二", sourceMessageID: nil)

        let updated = try XCTUnwrap(store.update(id: first.id, value: "规则一已修改"))

        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(store.items().count, 2)
        XCTAssertTrue(store.items().contains { $0.id == first.id && $0.value == "规则一已修改" })
        XCTAssertTrue(store.items().contains { $0.id == second.id && $0.value == "规则二" })
    }

    private func references(reminderID: String, now: Date) -> ReferenceContext {
        ReferenceContext(
            recentlyCreated: ReminderReference(reminderID: reminderID, recordedAt: now),
            recentlyModified: nil,
            recentlyMoved: nil,
            recentlyCompleted: nil,
            recentlyShown: [],
            explicitlySelected: nil
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AgentSessionContextStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
