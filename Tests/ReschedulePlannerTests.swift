import XCTest
@testable import AIGTDReminders

final class ReschedulePlannerTests: XCTestCase {
    func testPlanKeepsStableReminderIDsAndExcludesCompletedItems() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-13T02:00:00Z"))
        let items = [
            ReminderItemInfo(
                id: "stable-a",
                title: "任务 A",
                notes: "",
                dueDate: now.addingTimeInterval(-3600),
                listTitle: "收集箱",
                isCompleted: false
            ),
            ReminderItemInfo(
                id: "completed-b",
                title: "已完成任务",
                notes: "",
                dueDate: nil,
                listTitle: "收集箱",
                isCompleted: true
            ),
            ReminderItemInfo(
                id: "stable-c",
                title: "任务 C",
                notes: "",
                dueDate: nil,
                listTitle: "工作",
                isCompleted: false
            )
        ]

        let plan = try XCTUnwrap(
            ReschedulePlanner().makePlan(
                entities: ["scope": "current_open_items", "window_days": "14"],
                reminderItems: items,
                now: now
            )
        )

        XCTAssertEqual(plan.items.map(\.reminderID), ["stable-a", "stable-c"])
        XCTAssertFalse(plan.items.contains { $0.reminderID == "completed-b" })
        for item in plan.items {
            let dueDate = try XCTUnwrap(ISO8601DateFormatter().date(from: item.dueDateISO8601))
            XCTAssertGreaterThan(dueDate, now)
        }
    }

    func testSameSnapshotProducesSamePlan() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-13T02:00:00Z"))
        let items = [
            ReminderItemInfo(
                id: "one",
                title: "第一条",
                notes: "",
                dueDate: nil,
                listTitle: "收集箱",
                isCompleted: false
            ),
            ReminderItemInfo(
                id: "two",
                title: "第二条",
                notes: "",
                dueDate: nil,
                listTitle: "收集箱",
                isCompleted: false
            )
        ]
        let entities = ["scope": "current_open_items", "window_days": "7"]

        let first = ReschedulePlanner().makePlan(entities: entities, reminderItems: items, now: now)
        let second = ReschedulePlanner().makePlan(entities: entities, reminderItems: items, now: now)

        XCTAssertEqual(first, second)
    }

    func testOverdueScopeOnlyIncludesOverdueOpenItems() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-13T02:00:00Z"))
        let items = [
            ReminderItemInfo(id: "overdue", title: "逾期", notes: "", dueDate: now.addingTimeInterval(-60), listTitle: "收集箱", isCompleted: false),
            ReminderItemInfo(id: "future", title: "未来", notes: "", dueDate: now.addingTimeInterval(3600), listTitle: "收集箱", isCompleted: false),
            ReminderItemInfo(id: "no-date", title: "无时间", notes: "", dueDate: nil, listTitle: "收集箱", isCompleted: false)
        ]

        let plan = try XCTUnwrap(
            ReschedulePlanner().makePlan(
                entities: ["scope": "overdue_open_items"],
                reminderItems: items,
                now: now
            )
        )

        XCTAssertEqual(plan.items.map(\.reminderID), ["overdue"])
    }

    func testPastRequestedStartDateIsMovedIntoFuture() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-13T10:00:00Z"))
        let item = ReminderItemInfo(
            id: "one",
            title: "第一条",
            notes: "",
            dueDate: nil,
            listTitle: "收集箱",
            isCompleted: false
        )

        let plan = try XCTUnwrap(
            ReschedulePlanner().makePlan(
                entities: ["start_date": "2026-07-01T01:00:00Z"],
                reminderItems: [item],
                now: now
            )
        )
        let dueDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: try XCTUnwrap(plan.items.first?.dueDateISO8601))
        )

        XCTAssertGreaterThan(dueDate, now)
    }
}
