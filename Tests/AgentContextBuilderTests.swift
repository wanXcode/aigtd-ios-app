import Foundation
import XCTest
@testable import AIGTDReminders

final class AgentContextBuilderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_100_000_000)

    func testRecentTurnsUseLatestEightAndLimitEachToThreeHundredCharacters() {
        let turns = (0..<10).map { AgentConversationTurn(role: "user", text: "\($0)-" + repeated("字", 350)) }

        let snapshot = build(recentTurns: turns)

        XCTAssertEqual(snapshot.recentTurns.count, 8)
        XCTAssertTrue(snapshot.recentTurns[0].text.hasPrefix("2-"))
        XCTAssertEqual(snapshot.recentTurns[0].text.count, 300)
        XCTAssertTrue(snapshot.recentTurns[7].text.hasPrefix("9-"))
        XCTAssertEqual(snapshot.privacy.truncatedTurnCount, 2)
    }

    func testStableReferenceTargetsSurviveAConstrainedReminderBudget() {
        let references = ReferenceContext(
            recentlyCreated: reference("created", secondsAgo: 20),
            recentlyModified: nil,
            recentlyMoved: nil,
            recentlyCompleted: nil,
            recentlyShown: [reference("shown", secondsAgo: 10)],
            explicitlySelected: reference("selected", secondsAgo: 30)
        )
        let reminders = [
            reminder("ordinary", reasons: [.today]),
            reminder("shown"),
            reminder("selected"),
            reminder("created")
        ]

        let snapshot = build(
            reminders: reminders,
            references: references,
            privacy: AgentContextPrivacySettings(maximumReminderCount: 3)
        )

        XCTAssertEqual(snapshot.reminders.map(\.id), ["selected", "shown", "created"])
        XCTAssertEqual(snapshot.privacy.originalReminderCount, 4)
        XCTAssertEqual(snapshot.privacy.includedReminderCount, 3)
        XCTAssertEqual(snapshot.privacy.truncatedReminderCount, 1)
    }

    func testRelevanceOrderingUsesDocumentedTiersAndDeterministicTieBreakers() {
        let reminders = [
            reminder("open-b", title: "Beta", dueDate: now.addingTimeInterval(200), reasons: [.openItem]),
            reminder("overdue", reasons: [.overdue]),
            reminder("scope", reasons: [.listScope]),
            reminder("open-a", title: "Alpha", dueDate: now.addingTimeInterval(200), reasons: [.openItem]),
            reminder("today", reasons: [.today])
        ]

        let first = build(reminders: reminders).reminders.map(\.id)
        let second = build(reminders: Array(reminders.reversed())).reminders.map(\.id)

        XCTAssertEqual(first, ["scope", "overdue", "today", "open-a", "open-b"])
        XCTAssertEqual(second, first)
    }

    func testReferencesMergeReasonsWithoutDuplicatesAndIgnoreStaleReferences() {
        var stale = reference("stale", secondsAgo: 1)
        stale.isStale = true
        stale.staleSince = now
        let references = ReferenceContext(
            recentlyCreated: reference("active", secondsAgo: 2),
            recentlyModified: reference("active", secondsAgo: 1),
            recentlyMoved: nil,
            recentlyCompleted: nil,
            recentlyShown: [reference("active", secondsAgo: 3), stale],
            explicitlySelected: nil
        )

        let snapshot = build(
            reminders: [reminder("active", reasons: [.recentlyCreated]), reminder("stale")],
            references: references
        )

        XCTAssertEqual(
            snapshot.reminders.first(where: { $0.id == "active" })?.relevanceReasons,
            [.recentlyCreated, .recentlyModified, .recentlyShown]
        )
        XCTAssertEqual(snapshot.reminders.first(where: { $0.id == "stale" })?.relevanceReasons, [])
    }

    func testRecentlyShownOrderIsPreservedWhenReferencesShareATimestamp() {
        let recordedAt = now.addingTimeInterval(-10)
        let references = ReferenceContext(
            recentlyCreated: nil,
            recentlyModified: nil,
            recentlyMoved: nil,
            recentlyCompleted: nil,
            recentlyShown: [
                ReminderReference(reminderID: "second-title", recordedAt: recordedAt),
                ReminderReference(reminderID: "first-title", recordedAt: recordedAt)
            ],
            explicitlySelected: nil
        )

        let snapshot = build(
            reminders: [reminder("first-title"), reminder("second-title")],
            references: references
        )

        XCTAssertEqual(snapshot.reminders.map(\.id), ["second-title", "first-title"])
    }

    func testPrivacyDefaultsExcludeCompletedItemsAndAllNotes() {
        let snapshot = build(reminders: [
            reminder("open", notes: "private"),
            reminder("completed", isCompleted: true, notes: "finished private")
        ])

        XCTAssertEqual(snapshot.reminders.map(\.id), ["open"])
        XCTAssertNil(snapshot.reminders[0].notesPreview)
        XCTAssertFalse(snapshot.privacy.includesNotes)
        XCTAssertFalse(snapshot.privacy.includesCompletedReminders)
        XCTAssertEqual(snapshot.privacy.truncatedReminderCount, 1)
    }

    func testPrivacyOptInIncludesCompletedItemsAndTruncatedNotes() {
        let privacy = AgentContextPrivacySettings(
            includesNotes: true,
            includesCompletedReminders: true,
            maximumReminderCount: 40
        )

        let snapshot = build(
            reminders: [reminder("completed", isCompleted: true, notes: repeated("n", 250))],
            privacy: privacy,
            reminderSnapshotIsStale: true
        )

        XCTAssertEqual(snapshot.reminders.map(\.id), ["completed"])
        XCTAssertEqual(snapshot.reminders[0].notesPreview?.count, 200)
        XCTAssertTrue(snapshot.privacy.includesNotes)
        XCTAssertTrue(snapshot.privacy.includesCompletedReminders)
        XCTAssertTrue(snapshot.privacy.reminderSnapshotIsStale)
    }

    func testReminderMaximumAndFieldBudgetsAreApplied() {
        let reminders = (0..<5).map { index in
            reminder("id-\(index)", title: repeated("t", 150), reasons: [.openItem])
        }

        let snapshot = build(
            reminders: reminders,
            privacy: AgentContextPrivacySettings(maximumReminderCount: 2)
        )

        XCTAssertEqual(snapshot.reminders.count, 2)
        XCTAssertTrue(snapshot.reminders.allSatisfy { $0.title.count == 120 })
        XCTAssertEqual(snapshot.privacy.truncatedReminderCount, 3)
    }

    func testDocumentsFallBackPerFieldAndEachKindHasAnIndependentBudget() {
        let fallback = AgentDocumentContext(
            prompt: repeated("p", 4_100),
            memory: "fallback-memory",
            solu: "fallback-solu",
            operatingGuide: repeated("o", 4_050)
        )
        let documents = AgentContextDocumentsInput(
            prompt: "   \n",
            memory: "current-memory",
            solu: nil,
            operatingGuide: "current-guide",
            fallback: fallback
        )

        let snapshot = build(documents: documents)

        XCTAssertEqual(snapshot.documents.prompt.count, 4_000)
        XCTAssertEqual(snapshot.documents.memory, "current-memory")
        XCTAssertEqual(snapshot.documents.solu, "fallback-solu")
        XCTAssertEqual(snapshot.documents.operatingGuide, "current-guide")
    }

    func testBuildPreservesSessionSummaryPreferencesAndTimeMetadata() {
        let preference = UserMemoryItem(
            id: UUID(),
            category: .preferredName,
            value: "哥哥",
            sourceMessageID: nil,
            createdAt: now,
            updatedAt: now
        )
        let summary = SessionSummary(
            currentGoal: "整理今天",
            taskScope: nil,
            confirmedConstraints: [],
            pendingQuestions: [],
            relatedReminderIDs: ["related"],
            coveredThroughMessageID: nil,
            updatedAt: now
        )

        let snapshot = build(
            sessionSummary: summary,
            reminders: [reminder("other", reasons: [.dateScope]), reminder("related")],
            preferences: [preference]
        )

        XCTAssertEqual(snapshot.generatedAt, now)
        XCTAssertEqual(snapshot.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(snapshot.sessionSummary, summary)
        XCTAssertEqual(snapshot.preferences, [preference])
        XCTAssertEqual(snapshot.reminders.first?.id, "related")
    }

    private func build(
        recentTurns: [AgentConversationTurn] = [],
        sessionSummary: SessionSummary? = nil,
        reminders: [ReminderContextItem] = [],
        references: ReferenceContext = .empty,
        preferences: [UserMemoryItem] = [],
        documents: AgentContextDocumentsInput? = nil,
        privacy: AgentContextPrivacySettings = .standard,
        reminderSnapshotIsStale: Bool = false
    ) -> AgentContextSnapshot {
        let fallback = AgentDocumentContext(prompt: "p", memory: "m", solu: "s", operatingGuide: "o")
        return AgentContextBuilder().build(from: AgentContextBuildInput(
            generatedAt: now,
            timeZoneIdentifier: "Asia/Shanghai",
            session: SessionContext(id: UUID(), title: "Main", createdAt: now, updatedAt: now),
            recentTurns: recentTurns,
            sessionSummary: sessionSummary,
            reminders: reminders,
            references: references,
            preferences: preferences,
            documents: documents ?? AgentContextDocumentsInput(
                prompt: nil,
                memory: nil,
                solu: nil,
                operatingGuide: nil,
                fallback: fallback
            ),
            privacy: privacy,
            reminderSnapshotIsStale: reminderSnapshotIsStale
        ))
    }

    private func reminder(
        _ id: String,
        title: String? = nil,
        dueDate: Date? = nil,
        isCompleted: Bool = false,
        notes: String? = nil,
        reasons: [ReminderContextRelevance] = []
    ) -> ReminderContextItem {
        ReminderContextItem(
            id: id,
            title: title ?? id,
            listID: "list-id",
            listTitle: "Inbox",
            dueDate: dueDate,
            isCompleted: isCompleted,
            lastModifiedAt: now,
            relevanceReasons: reasons,
            notesPreview: notes
        )
    }

    private func reference(_ id: String, secondsAgo: TimeInterval) -> ReminderReference {
        ReminderReference(reminderID: id, recordedAt: now.addingTimeInterval(-secondsAgo))
    }

    private func repeated(_ value: Character, _ count: Int) -> String {
        String(repeating: String(value), count: count)
    }
}
