import XCTest
@testable import AIGTDReminders

final class AgentDocumentContextTests: XCTestCase {
    func testAllFourDocumentsEnterRuntimeContext() {
        let context = AIGTDAgentDocumentStore.runtimeContext(from: [
            AgentDocument(kind: AIGTDAgentDocumentKind.prompt.rawValue, content: "prompt-value"),
            AgentDocument(kind: AIGTDAgentDocumentKind.memory.rawValue, content: "memory-value"),
            AgentDocument(kind: AIGTDAgentDocumentKind.solu.rawValue, content: "solu-value"),
            AgentDocument(kind: AIGTDAgentDocumentKind.operatingGuide.rawValue, content: "guide-value")
        ])

        XCTAssertEqual(context.prompt, "prompt-value")
        XCTAssertEqual(context.memory, "memory-value")
        XCTAssertEqual(context.solu, "solu-value")
        XCTAssertEqual(context.operatingGuide, "guide-value")
    }

    func testMissingOrBlankDocumentsUseSafeDefaults() {
        let context = AIGTDAgentDocumentStore.runtimeContext(from: [
            AgentDocument(kind: AIGTDAgentDocumentKind.memory.rawValue, content: "  \n ")
        ])

        XCTAssertEqual(context.prompt, AIGTDAgentDocumentKind.prompt.defaultContent)
        XCTAssertEqual(context.memory, AIGTDAgentDocumentKind.memory.defaultContent)
        XCTAssertFalse(context.memory.contains("用户称呼：哥哥"))
        XCTAssertEqual(context.solu, AIGTDAgentDocumentKind.solu.defaultContent)
        XCTAssertEqual(context.operatingGuide, AIGTDAgentDocumentKind.operatingGuide.defaultContent)
    }

    func testDocumentsAreLimitedToContextBudget() {
        let context = AIGTDAgentDocumentStore.runtimeContext(from: [
            AgentDocument(kind: AIGTDAgentDocumentKind.prompt.rawValue, content: String(repeating: "a", count: 5_000))
        ])

        XCTAssertEqual(context.prompt.count, 4_000)
    }

    func testLocalFallbackUsesSnapshotReminderDataAsUnifiedInput() throws {
        let dueDate = Date()
        let snapshot = makeSnapshot(
            reminders: [
                ReminderContextItem(
                    id: "snapshot-reminder",
                    title: "Snapshot 里的任务",
                    listID: "snapshot-list",
                    listTitle: "收集箱",
                    dueDate: dueDate,
                    isCompleted: false,
                    lastModifiedAt: nil,
                    relevanceReasons: [.today],
                    notesPreview: nil
                )
            ]
        )

        let result = MockAgentService().respond(
            to: "看看今天的任务",
            reminderLists: [],
            reminderItems: [],
            contextSnapshot: snapshot
        )

        XCTAssertEqual(result.actionType, MockAgentIntent.summarizeLists.rawValue)
        XCTAssertTrue(result.reply.contains("Snapshot 里的任务"))
    }

    func testLocalFallbackUsesStructuredPreferredNameFromSnapshot() {
        let now = Date()
        let preference = UserMemoryItem(
            id: UUID(),
            category: .preferredName,
            value: "小万",
            sourceMessageID: nil,
            createdAt: now,
            updatedAt: now
        )
        let snapshot = makeSnapshot(preferences: [preference])

        let result = MockAgentService().respond(
            to: "你在吗",
            reminderLists: [],
            reminderItems: [],
            contextSnapshot: snapshot
        )

        XCTAssertTrue(result.reply.contains("小万"))
    }

    private func makeSnapshot(
        reminders: [ReminderContextItem] = [],
        preferences: [UserMemoryItem] = []
    ) -> AgentContextSnapshot {
        let now = Date()
        return AgentContextSnapshot(
            generatedAt: now,
            timeZoneIdentifier: TimeZone.current.identifier,
            session: SessionContext(id: UUID(), title: "测试", createdAt: now, updatedAt: now),
            recentTurns: [],
            sessionSummary: nil,
            reminders: reminders,
            references: .empty,
            preferences: preferences,
            documents: AgentDocumentContext(
                prompt: "prompt",
                memory: "memory",
                solu: "solu",
                operatingGuide: "guide"
            ),
            privacy: ContextPrivacyDescriptor(
                includesNotes: false,
                includesCompletedReminders: false,
                maximumReminderCount: 40,
                reminderSnapshotIsStale: false,
                originalReminderCount: reminders.count,
                includedReminderCount: reminders.count,
                truncatedReminderCount: 0,
                truncatedTurnCount: 0
            )
        )
    }
}
