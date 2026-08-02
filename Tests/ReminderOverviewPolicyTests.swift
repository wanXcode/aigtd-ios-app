import XCTest
@testable import AIGTDReminders

final class ReminderOverviewPolicyTests: XCTestCase {
    func testSectionsKeepSystemListOrderAndIncludeEmptyLists() {
        let lists = [
            ReminderListInfo(id: "waiting", title: "等待中"),
            ReminderListInfo(id: "inbox", title: "收集箱"),
            ReminderListInfo(id: "project", title: "项目")
        ]
        let items = [
            makeItem(id: "inbox-1", title: "收件任务", listID: "inbox", listTitle: "收集箱"),
            makeItem(id: "waiting-1", title: "等待任务", listID: "waiting", listTitle: "等待中")
        ]

        let sections = ReminderOverviewPolicy.sections(lists: lists, items: items)

        XCTAssertEqual(sections.map(\.id), ["waiting", "inbox", "project"])
        XCTAssertEqual(sections.map(\.title), ["等待中", "收集箱", "项目"])
        XCTAssertEqual(sections[2].items, [])
    }

    func testSectionsSeparateListsWithTheSameTitleByListID() {
        let lists = [
            ReminderListInfo(id: "personal-inbox", title: "收集箱"),
            ReminderListInfo(id: "work-inbox", title: "收集箱"),
            ReminderListInfo(id: "shared-inbox", title: "收集箱")
        ]
        let items = [
            makeItem(id: "work-1", title: "工作任务", listID: "work-inbox", listTitle: "收集箱"),
            makeItem(id: "personal-1", title: "个人任务", listID: "personal-inbox", listTitle: "收集箱")
        ]

        let sections = ReminderOverviewPolicy.sections(lists: lists, items: items)

        XCTAssertEqual(sections.map(\.id), ["personal-inbox", "work-inbox", "shared-inbox"])
        XCTAssertEqual(sections[0].items.map(\.id), ["personal-1"])
        XCTAssertEqual(sections[1].items.map(\.id), ["work-1"])
        XCTAssertEqual(sections[2].items, [])
    }

    func testSectionsKeepIncomingTaskOrderWithoutSortingByCompletionDateOrTitle() {
        let later = Date(timeIntervalSince1970: 2_000)
        let earlier = Date(timeIntervalSince1970: 1_000)
        let items = [
            makeItem(id: "first", title: "Z", dueDate: later, listTitle: "收集箱", isCompleted: true),
            makeItem(id: "second", title: "A", dueDate: earlier, listTitle: "收集箱", isCompleted: false),
            makeItem(id: "third", title: "M", dueDate: nil, listTitle: "收集箱", isCompleted: false)
        ]

        let sections = ReminderOverviewPolicy.sections(
            lists: [ReminderListInfo(id: "inbox", title: "收集箱")],
            items: items
        )

        XCTAssertEqual(sections[0].items.map(\.id), ["first", "second", "third"])
    }

    func testUnknownListsFollowFirstAppearanceWithoutAlphabeticalFallbackSort() {
        let items = [
            makeItem(id: "z-1", title: "第一项", listTitle: "Z 清单"),
            makeItem(id: "a-1", title: "第二项", listTitle: "A 清单"),
            makeItem(id: "z-2", title: "第三项", listTitle: "Z 清单")
        ]

        let sections = ReminderOverviewPolicy.sections(lists: [], items: items)

        XCTAssertEqual(sections.map(\.title), ["Z 清单", "A 清单"])
        XCTAssertEqual(sections[0].items.map(\.id), ["z-1", "z-2"])
    }

    func testStableOrderUsesCallbackOrderOnFirstRefresh() {
        let callbackItems = [
            makeItem(id: "inbox-2", title: "第二项", listID: "inbox", listTitle: "收集箱"),
            makeItem(id: "project-1", title: "项目项", listID: "project", listTitle: "项目"),
            makeItem(id: "inbox-1", title: "第一项", listID: "inbox", listTitle: "收集箱")
        ]

        let result = ReminderOverviewPolicy.stabilizedItems(
            callbackItems,
            previousState: .empty
        )

        XCTAssertEqual(result.items.map(\.id), ["inbox-2", "project-1", "inbox-1"])
    }

    func testStableOrderRetainsKnownItemsPerListAndAppendsNewItemsInCallbackOrder() {
        let firstRefresh = ReminderOverviewPolicy.stabilizedItems(
            [
                makeItem(id: "inbox-1", title: "收件一", listID: "inbox", listTitle: "收集箱"),
                makeItem(id: "inbox-2", title: "收件二", listID: "inbox", listTitle: "收集箱"),
                makeItem(id: "project-1", title: "项目一", listID: "project", listTitle: "项目"),
                makeItem(id: "project-2", title: "项目二", listID: "project", listTitle: "项目")
            ],
            previousState: .empty
        )
        let secondRefresh = ReminderOverviewPolicy.stabilizedItems(
            [
                makeItem(id: "project-2", title: "项目二已更新", listID: "project", listTitle: "项目"),
                makeItem(id: "inbox-2", title: "收件二已更新", listID: "inbox", listTitle: "收集箱"),
                makeItem(id: "project-3", title: "项目三", listID: "project", listTitle: "项目"),
                makeItem(id: "inbox-3", title: "收件三", listID: "inbox", listTitle: "收集箱"),
                makeItem(id: "project-1", title: "项目一", listID: "project", listTitle: "项目"),
                makeItem(id: "inbox-1", title: "收件一", listID: "inbox", listTitle: "收集箱"),
                makeItem(id: "inbox-4", title: "收件四", listID: "inbox", listTitle: "收集箱")
            ],
            previousState: firstRefresh.state
        )
        let sections = ReminderOverviewPolicy.sections(
            lists: [
                ReminderListInfo(id: "inbox", title: "收集箱"),
                ReminderListInfo(id: "project", title: "项目")
            ],
            items: secondRefresh.items
        )

        XCTAssertEqual(sections[0].items.map(\.id), ["inbox-1", "inbox-2", "inbox-3", "inbox-4"])
        XCTAssertEqual(sections[1].items.map(\.id), ["project-1", "project-2", "project-3"])
        XCTAssertEqual(sections[0].items[1].title, "收件二已更新")
        XCTAssertEqual(sections[1].items[1].title, "项目二已更新")
    }

    func testSyncDescriptionNeverUsesFutureWording() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            ReminderOverviewPolicy.syncDescription(
                isLoading: false,
                lastSyncAt: now.addingTimeInterval(10),
                now: now
            ),
            "刚刚同步"
        )
        XCTAssertEqual(
            ReminderOverviewPolicy.syncDescription(
                isLoading: false,
                lastSyncAt: now.addingTimeInterval(-8),
                now: now
            ),
            "最新同步 8 秒前"
        )
        XCTAssertFalse(
            ReminderOverviewPolicy.syncDescription(
                isLoading: false,
                lastSyncAt: now,
                now: now
            ).contains("秒后")
        )
    }

    func testAdjustmentDraftUsesNaturalTaskContext() {
        let item = makeItem(id: "stable-id", title: "准备发布", listTitle: "项目")

        XCTAssertEqual(
            ReminderOverviewPolicy.adjustmentDraft(for: item),
            "请帮我调整“准备发布”这条任务："
        )
    }

    func testReminderAdjustmentSelectionIsRetainedOnlyWhileDraftReferencesTask() {
        let selection = ReminderAdjustmentSelection(
            reminderID: "stable-id",
            reminderTitle: "准备发布"
        )

        XCTAssertEqual(
            ReminderAdjustmentDraftPolicy.retainedSelection(
                selection,
                in: "请帮我调整“准备发布”这条任务：改到明天上午 9 点"
            ),
            selection
        )
        XCTAssertNil(
            ReminderAdjustmentDraftPolicy.retainedSelection(
                selection,
                in: "帮我看看明天有哪些任务"
            )
        )
        XCTAssertNil(ReminderAdjustmentDraftPolicy.retainedSelection(selection, in: ""))
    }

    @MainActor
    func testRouteToChatKeepsStableReminderContextForAdjustment() {
        let model = AppModel()
        let item = makeItem(id: "stable-id", title: "准备发布", listTitle: "项目")

        model.routeToChatForReminderAdjustment(item)

        XCTAssertEqual(model.selectedTab, .chat)
        XCTAssertEqual(model.chatComposerResumeSource, .reminderAdjustment)
        XCTAssertEqual(model.pendingReminderAdjustmentContext?.id, "stable-id")
        XCTAssertEqual(model.pendingChatDraftAfterModelSetup, "请帮我调整“准备发布”这条任务：")
        XCTAssertTrue(model.shouldResumeChatComposer)
    }

    private func makeItem(
        id: String,
        title: String,
        dueDate: Date? = nil,
        listID: String = "",
        listTitle: String,
        isCompleted: Bool = false
    ) -> ReminderItemInfo {
        ReminderItemInfo(
            id: id,
            title: title,
            notes: "",
            dueDate: dueDate,
            listID: listID,
            listTitle: listTitle,
            isCompleted: isCompleted
        )
    }
}
