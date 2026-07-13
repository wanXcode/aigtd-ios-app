import Foundation
import XCTest
@testable import AIGTDReminders

final class AgentEvaluationTests: XCTestCase {
    private static let expectedCategoryCounts = [
        "create": 15,
        "view": 15,
        "move": 10,
        "complete": 10,
        "delete": 10,
        "reschedule": 15,
        "chat": 10,
        "recent_context": 10,
        "error": 5
    ]

    func testEvaluationFixtureHasRequiredSchemaAndDistribution() throws {
        let cases = try loadCases()

        XCTAssertEqual(cases.count, 100, "评测集必须固定为 100 条")
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count, "评测样例 ID 必须唯一")

        let categoryCounts = Dictionary(grouping: cases, by: \.category).mapValues(\.count)
        XCTAssertEqual(categoryCounts, Self.expectedCategoryCounts)

        for evaluationCase in cases {
            XCTAssertFalse(evaluationCase.id.isEmpty, "样例缺少 id")
            XCTAssertFalse(evaluationCase.category.isEmpty, "\(evaluationCase.id) 缺少 category")
            XCTAssertFalse(evaluationCase.input.isEmpty, "\(evaluationCase.id) 缺少 input")
            XCTAssertFalse(evaluationCase.fixture.isEmpty, "\(evaluationCase.id) 缺少 fixture")
            XCTAssertFalse(evaluationCase.expectedIntent.isEmpty, "\(evaluationCase.id) 缺少 expected_intent")
            XCTAssertTrue(
                ["none", "low", "medium", "high"].contains(evaluationCase.risk),
                "\(evaluationCase.id) 的 risk 无效：\(evaluationCase.risk)"
            )
            XCTAssertTrue(
                EvaluationMode.allCases.contains(evaluationCase.evaluationMode),
                "\(evaluationCase.id) 的 evaluation_mode 无效：\(evaluationCase.evaluationMode)"
            )

            for (key, assertion) in evaluationCase.expectedEntities {
                XCTAssertFalse(key.isEmpty, "\(evaluationCase.id) 包含空实体键")
                XCTAssertTrue(
                    assertion.hasMatcher,
                    "\(evaluationCase.id) 的实体 \(key) 至少需要 equals、contains 或 non_empty 断言"
                )
            }
        }

        printCategorySummary(cases: cases, passedIDs: Set(cases.map(\.id)), label: "fixture schema")
    }

    func testLocalFallbackEvaluationCases() throws {
        let cases = try loadCases().filter { $0.evaluationMode == .localFallback }
        var passedIDs = Set<String>()
        var failures: [String] = []

        for evaluationCase in cases {
            let fixture = makeReminderFixture(named: evaluationCase.fixture)
            let result = MockAgentService().respond(
                to: evaluationCase.input,
                reminderLists: fixture.lists,
                reminderItems: fixture.items
            )
            var caseFailures: [String] = []

            if result.actionType != evaluationCase.expectedIntent {
                let actualIntent = result.actionType ?? "nil"
                caseFailures.append(
                    "intent 期望 \(evaluationCase.expectedIntent)，实际 \(actualIntent)"
                )
            }

            do {
                let envelope = try decodeEnvelope(from: result.payloadJSON)
                for (key, assertion) in evaluationCase.expectedEntities {
                    let actualValue = envelope.action.entities[key]
                    caseFailures.append(contentsOf: assertion.failures(key: key, actualValue: actualValue))
                }
            } catch {
                caseFailures.append("payload 无法解析：\(error.localizedDescription)")
            }

            if caseFailures.isEmpty {
                passedIDs.insert(evaluationCase.id)
            } else {
                let details = caseFailures.joined(separator: "；")
                failures.append("[\(evaluationCase.id)] \(details)")
            }
        }

        printCategorySummary(cases: cases, passedIDs: passedIDs, label: "local fallback")
        if failures.isEmpty == false {
            let details = failures.joined(separator: "\n")
            XCTFail("本地评测失败：\n\(details)")
        }
    }

    func testProtocolAndKnownGapCasesAreExplicitlySeparated() throws {
        let cases = try loadCases()
        let protocolFixtures = cases.filter { $0.evaluationMode == .protocolFixture }
        let knownGaps = cases.filter { $0.evaluationMode == .knownGap }

        XCTAssertEqual(protocolFixtures.count, 5)
        XCTAssertEqual(knownGaps.count, 17)
        XCTAssertTrue(protocolFixtures.allSatisfy { $0.category == "error" })
        XCTAssertTrue(knownGaps.allSatisfy { $0.category == "view" || $0.category == "reschedule" || $0.category == "recent_context" })

        print("[AgentEvaluation] protocol_fixture=\(protocolFixtures.count), known_gap=\(knownGaps.count)")
        for evaluationCase in knownGaps {
            print("[AgentEvaluation][known_gap] \(evaluationCase.id): \(evaluationCase.input)")
        }
    }

    func testSingleReminderUpdateKeepsRequestedHour() throws {
        let result = MockAgentService().respond(
            to: "改到后天上午 10 点",
            reminderLists: [],
            reminderItems: []
        )
        XCTAssertEqual(result.actionType, MockAgentIntent.updateReminder.rawValue)

        let envelope = try decodeEnvelope(from: result.payloadJSON)
        let dueDateValue = try XCTUnwrap(envelope.action.entities["due_date"])
        let dueDate = try XCTUnwrap(ISO8601DateFormatter().date(from: dueDateValue))
        let components = Calendar.current.dateComponents([.hour, .minute], from: dueDate)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 0)
    }

    func testNextMondayUpdateTargetsTheImmediatelyFollowingWeek() throws {
        let result = MockAgentService().respond(
            to: "再改到下周一上午 9 点",
            reminderLists: [],
            reminderItems: []
        )
        let envelope = try decodeEnvelope(from: result.payloadJSON)
        let dueDateValue = try XCTUnwrap(envelope.action.entities["due_date"])
        let dueDate = try XCTUnwrap(ISO8601DateFormatter().date(from: dueDateValue))
        let calendar = Calendar.current
        let days = try XCTUnwrap(calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: .now),
            to: calendar.startOfDay(for: dueDate)
        ).day)

        XCTAssertEqual(calendar.component(.weekday, from: dueDate), 2)
        XCTAssertTrue((1...7).contains(days), "下周一应落在未来 7 天内，实际为 \(days) 天后")
        XCTAssertEqual(calendar.component(.hour, from: dueDate), 9)
    }

    private func loadCases() throws -> [AgentEvaluationCase] {
        let bundle = Bundle(for: AgentEvaluationTests.self)
        let url = bundle.url(
            forResource: "agent-evaluation-cases",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: "agent-evaluation-cases", withExtension: "json")

        let fixtureURL = try XCTUnwrap(url, "测试 bundle 中缺少 agent-evaluation-cases.json")
        return try JSONDecoder().decode([AgentEvaluationCase].self, from: Data(contentsOf: fixtureURL))
    }

    private func decodeEnvelope(from payloadJSON: String) throws -> MockAgentEnvelope {
        try JSONDecoder().decode(MockAgentEnvelope.self, from: Data(payloadJSON.utf8))
    }

    private func printCategorySummary(
        cases: [AgentEvaluationCase],
        passedIDs: Set<String>,
        label: String
    ) {
        let grouped = Dictionary(grouping: cases, by: \.category)
        let totalPassed = cases.filter { passedIDs.contains($0.id) }.count
        print("[AgentEvaluation][\(label)] total \(totalPassed)/\(cases.count)")
        for category in grouped.keys.sorted() {
            let categoryCases = grouped[category, default: []]
            let passed = categoryCases.filter { passedIDs.contains($0.id) }.count
            let failedIDs = categoryCases.filter { passedIDs.contains($0.id) == false }.map(\.id)
            let failedList = failedIDs.joined(separator: ",")
            let failureSuffix = failedIDs.isEmpty ? "" : ", failed=\(failedList)"
            print("[AgentEvaluation][\(label)] \(category): \(passed)/\(categoryCases.count)\(failureSuffix)")
        }
    }

    private func makeReminderFixture(named name: String) -> ReminderFixture {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let today = calendar.date(byAdding: .hour, value: 2, to: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)
        let overdue = calendar.date(byAdding: .day, value: -3, to: now)
        let lists = [
            ReminderListInfo(id: "fixture-list-inbox", title: "收集箱"),
            ReminderListInfo(id: "fixture-list-next", title: "下一步行动"),
            ReminderListInfo(id: "fixture-list-project", title: "项目"),
            ReminderListInfo(id: "fixture-list-waiting", title: "等待中"),
            ReminderListInfo(id: "fixture-list-maybe", title: "也许以后")
        ]

        if name == "empty-reminders" {
            return ReminderFixture(lists: lists, items: [])
        }

        let items = [
            ReminderItemInfo(id: "fixture-001", title: "整理季度报表", notes: "虚构测试任务", dueDate: today, listTitle: "收集箱", isCompleted: false),
            ReminderItemInfo(id: "fixture-002", title: "预约设备检修", notes: "虚构测试任务", dueDate: tomorrow, listTitle: "项目", isCompleted: false),
            ReminderItemInfo(id: "fixture-003", title: "核对培训名单", notes: "虚构测试任务", dueDate: overdue, listTitle: "等待中", isCompleted: false),
            ReminderItemInfo(id: "fixture-004", title: "制作演示截图", notes: "虚构测试任务", dueDate: nil, listTitle: "下一步行动", isCompleted: false),
            ReminderItemInfo(id: "fixture-005", title: "已归档的示例事项", notes: "虚构测试任务", dueDate: overdue, listTitle: "收集箱", isCompleted: true)
        ]
        return ReminderFixture(lists: lists, items: items)
    }
}

private struct AgentEvaluationCase: Decodable {
    let id: String
    let category: String
    let input: String
    let fixture: String
    let expectedIntent: String
    let expectedEntities: [String: EntityAssertion]
    let shouldExecute: Bool
    let shouldShowCard: Bool
    let risk: String
    let evaluationMode: EvaluationMode

    enum CodingKeys: String, CodingKey {
        case id, category, input, fixture, risk
        case expectedIntent = "expected_intent"
        case expectedEntities = "expected_entities"
        case shouldExecute = "should_execute"
        case shouldShowCard = "should_show_card"
        case evaluationMode = "evaluation_mode"
    }
}

private struct EntityAssertion: Decodable {
    let equals: String?
    let contains: String?
    let nonEmpty: Bool?

    enum CodingKeys: String, CodingKey {
        case equals, contains
        case nonEmpty = "non_empty"
    }

    var hasMatcher: Bool {
        equals != nil || contains != nil || nonEmpty != nil
    }

    func failures(key: String, actualValue: String?) -> [String] {
        var failures: [String] = []
        let displayedValue = actualValue ?? "nil"
        if let equals, actualValue != equals {
            failures.append("实体 \(key) 期望等于“\(equals)”，实际“\(displayedValue)”")
        }
        if let contains, actualValue?.contains(contains) != true {
            failures.append("实体 \(key) 期望包含“\(contains)”，实际“\(displayedValue)”")
        }
        if nonEmpty == true, actualValue?.isEmpty != false {
            failures.append("实体 \(key) 应为非空，实际“\(displayedValue)”")
        }
        return failures
    }
}

private enum EvaluationMode: String, Decodable, CaseIterable {
    case localFallback = "local_fallback"
    case protocolFixture = "protocol_fixture"
    case knownGap = "known_gap"
}

private struct ReminderFixture {
    let lists: [ReminderListInfo]
    let items: [ReminderItemInfo]
}
