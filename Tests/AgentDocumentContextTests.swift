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

    func testViewResultOverridesGenericRemoteIntentAndCarriesDisplayedOrder() throws {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let items = [
            ReminderItemInfo(id: "first", title: "第一条", notes: "", dueDate: tomorrow, listTitle: "收集箱", isCompleted: false),
            ReminderItemInfo(id: "second", title: "第二条", notes: "", dueDate: tomorrow, listTitle: "收集箱", isCompleted: false),
            ReminderItemInfo(id: "third", title: "第三条", notes: "", dueDate: tomorrow, listTitle: "收集箱", isCompleted: false),
            ReminderItemInfo(id: "fourth", title: "第四条", notes: "", dueDate: tomorrow, listTitle: "收集箱", isCompleted: false)
        ]
        let localResult = MockAgentService().respond(
            to: "看看明天的任务",
            reminderLists: [ReminderListInfo(id: "inbox", title: "收集箱")],
            reminderItems: items
        )

        XCTAssertTrue(
            AgentResultArbitration.shouldPreferLocalResult(
                remoteActionType: MockAgentIntent.captureMessage.rawValue,
                localActionType: localResult.actionType
            )
        )
        XCTAssertTrue(
            AgentResultArbitration.shouldBypassRemote(
                localActionType: localResult.actionType,
                hasExplicitOrdinal: false
            )
        )
        let envelope = try JSONDecoder().decode(
            MockAgentEnvelope.self,
            from: Data(localResult.payloadJSON.utf8)
        )
        XCTAssertEqual(envelope.action.entities["shown_ids"], "first,second,third")
        XCTAssertEqual(envelope.action.entities["top_items"], "第一条、第二条、第三条")
    }

    func testDetailQueryReturnsOptedInNotesAndCompletedStatusWithoutMutation() throws {
        let snapshot = makeSnapshot(reminders: [
            ReminderContextItem(
                id: "open-note",
                title: "隐私备注测试",
                listID: "inbox",
                listTitle: "收集箱",
                dueDate: nil,
                isCompleted: false,
                lastModifiedAt: nil,
                relevanceReasons: [.openItem],
                notesPreview: "这是私人备注 12345"
            ),
            ReminderContextItem(
                id: "completed-item",
                title: "隐私完成测试",
                listID: "inbox",
                listTitle: "收集箱",
                dueDate: nil,
                isCompleted: true,
                lastModifiedAt: nil,
                relevanceReasons: [],
                notesPreview: nil
            )
        ])

        let result = MockAgentService().respond(
            to: "列出隐私备注测试的备注，并告诉我隐私完成测试是否已完成",
            reminderLists: [],
            reminderItems: [],
            contextSnapshot: snapshot
        )
        let envelope = try JSONDecoder().decode(
            MockAgentEnvelope.self,
            from: Data(result.payloadJSON.utf8)
        )

        XCTAssertEqual(result.actionType, MockAgentIntent.summarizeLists.rawValue)
        XCTAssertTrue(result.reply.contains("这是私人备注 12345"))
        XCTAssertTrue(result.reply.contains("隐私完成测试：已完成"))
        XCTAssertEqual(
            Set(envelope.action.entities["shown_ids"]?.split(separator: ",").map(String.init) ?? []),
            Set(["completed-item", "open-note"])
        )
        XCTAssertTrue(
            AgentResultArbitration.shouldBypassRemote(
                localActionType: result.actionType,
                hasExplicitOrdinal: false
            )
        )
    }

    func testDetailQueryCannotRevealDataExcludedFromSnapshot() {
        let snapshot = makeSnapshot(reminders: [
            ReminderContextItem(
                id: "open-note",
                title: "隐私备注测试",
                listID: "inbox",
                listTitle: "收集箱",
                dueDate: nil,
                isCompleted: false,
                lastModifiedAt: nil,
                relevanceReasons: [.openItem],
                notesPreview: nil
            )
        ])

        let result = MockAgentService().respond(
            to: "列出隐私备注测试的备注，并告诉我隐私完成测试是否已完成",
            reminderLists: [],
            reminderItems: [],
            contextSnapshot: snapshot
        )

        XCTAssertEqual(result.actionType, MockAgentIntent.summarizeLists.rawValue)
        XCTAssertTrue(result.reply.contains("没有可读取的备注"))
        XCTAssertFalse(result.reply.contains("私人备注 12345"))
        XCTAssertFalse(result.reply.contains("隐私完成测试：已完成"))
    }

    func testOrdinalTimeOnlyUpdateUsesStableOrdinalAndPreservesExistingDate() throws {
        let result = MockAgentService().respond(
            to: "把第二条改到下午 4 点",
            reminderLists: [],
            reminderItems: []
        )
        let envelope = try JSONDecoder().decode(
            MockAgentEnvelope.self,
            from: Data(result.payloadJSON.utf8)
        )

        XCTAssertEqual(result.actionType, MockAgentIntent.updateReminder.rawValue)
        XCTAssertEqual(envelope.action.entities["ordinal"], "2")
        XCTAssertEqual(envelope.action.entities["preserve_existing_date"], "true")
        XCTAssertTrue(
            AgentResultArbitration.shouldBypassRemote(
                localActionType: result.actionType,
                hasExplicitOrdinal: true
            )
        )
        let dueDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: try XCTUnwrap(envelope.action.entities["due_date"]))
        )
        XCTAssertEqual(Calendar.current.component(.hour, from: dueDate), 16)
    }

    func testDeleteUsesLocalSafetyPathInsteadOfModelSelectedCandidate() {
        let result = MockAgentService().respond(
            to: "删除同名测试会议",
            reminderLists: [],
            reminderItems: []
        )

        XCTAssertEqual(result.actionType, MockAgentIntent.deleteReminder.rawValue)
        XCTAssertTrue(
            AgentResultArbitration.shouldBypassRemote(
                localActionType: result.actionType,
                hasExplicitOrdinal: false
            )
        )
        XCTAssertTrue(
            AgentResultArbitration.shouldPreferLocalResult(
                remoteActionType: MockAgentIntent.deleteReminder.rawValue,
                localActionType: result.actionType
            )
        )
    }

    func testDeleteKeywordInsideReminderTitleDoesNotTriggerDeletion() throws {
        let result = MockAgentService().respond(
            to: "后天提醒我检查长期记忆删除结果",
            reminderLists: [],
            reminderItems: []
        )
        let envelope = try JSONDecoder().decode(
            MockAgentEnvelope.self,
            from: Data(result.payloadJSON.utf8)
        )

        XCTAssertEqual(result.actionType, MockAgentIntent.createReminder.rawValue)
        XCTAssertEqual(envelope.action.entities["title"], "检查长期记忆删除结果")
    }

    func testRememberOneTimeTaskCreatesCleanReminderTitle() throws {
        let result = MockAgentService().respond(
            to: "记住明天提醒我交报告",
            reminderLists: [],
            reminderItems: []
        )
        let envelope = try JSONDecoder().decode(
            MockAgentEnvelope.self,
            from: Data(result.payloadJSON.utf8)
        )

        XCTAssertEqual(result.actionType, MockAgentIntent.createReminder.rawValue)
        XCTAssertEqual(envelope.action.entities["title"], "交报告")
        XCTAssertEqual(
            AgentMemoryPolicy().evaluate(message: "记住明天提醒我交报告"),
            .rejected(.oneTimeTask)
        )
    }

    func testExplicitDeletionCommandFormsStillTriggerDeletion() {
        for input in ["删除测试任务", "帮我删除测试任务", "把测试任务删掉"] {
            let result = MockAgentService().respond(
                to: input,
                reminderLists: [],
                reminderItems: []
            )

            XCTAssertEqual(
                result.actionType,
                MockAgentIntent.deleteReminder.rawValue,
                "应识别为删除命令：\(input)"
            )
        }
    }

    func testDateOnlyReminderUsesDefaultTimeOnlyWhilePreferenceExists() throws {
        let calendar = Calendar.current
        let parsedDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 18,
            hour: 9
        )))
        let preference = UserMemoryItem(
            id: UUID(),
            category: .defaultTaskTime,
            value: "以后没有具体时间的任务默认放上午 9 点",
            sourceMessageID: nil,
            createdAt: .now,
            updatedAt: .now
        )

        let withoutPreference = ReminderCreationSchedule.resolve(
            parsedDueDate: parsedDate,
            sourceText: "后天提醒我检查报告",
            preferences: [],
            calendar: calendar
        )
        XCTAssertFalse(withoutPreference.includesTime)

        let withPreference = ReminderCreationSchedule.resolve(
            parsedDueDate: parsedDate,
            sourceText: "后天提醒我检查报告",
            preferences: [preference],
            calendar: calendar
        )
        XCTAssertTrue(withPreference.includesTime)
        XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(withPreference.dueDate)), 9)

        let explicitTime = ReminderCreationSchedule.resolve(
            parsedDueDate: parsedDate,
            sourceText: "后天下午 3 点提醒我检查报告",
            preferences: [],
            calendar: calendar
        )
        XCTAssertTrue(explicitTime.includesTime)
    }

    func testTimeBeforeReminderCommandProducesCleanExactTitle() throws {
        for (input, expectedTitle) in [
            ("明天下午 2 点提醒我同名安全测试", "同名安全测试"),
            ("明天上午九点提醒我整理季度报表", "整理季度报表")
        ] {
            let result = MockAgentService().respond(
                to: input,
                reminderLists: [],
                reminderItems: []
            )
            let envelope = try JSONDecoder().decode(
                MockAgentEnvelope.self,
                from: Data(result.payloadJSON.utf8)
            )

            XCTAssertEqual(envelope.action.entities["title"], expectedTitle)
        }
    }

    func testScopeStatementsAreNotMistakenForViewRequests() {
        let statements = [
            "项目里的任务优先看标题是否清楚",
            "暂时不用处理收集箱",
            "也不用处理等待中清单",
            "今天只是做一次整理测试"
        ]

        for statement in statements {
            let result = MockAgentService().respond(
                to: statement,
                reminderLists: [],
                reminderItems: []
            )
            XCTAssertEqual(
                result.actionType,
                MockAgentIntent.captureMessage.rawValue,
                "不应把说明句误判为查看任务：\(statement)"
            )
        }
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
