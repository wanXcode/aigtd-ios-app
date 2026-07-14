import Foundation
import XCTest

final class AgentContextEvaluationFixtureTests: XCTestCase {
    private static let expectedCategoryCounts: [AgentContextEvaluationCategory: Int] = [
        .recentObjectReference: 15,
        .displayOrdinal: 10,
        .longConversationSummary: 10,
        .sameNameSafety: 5,
        .longTermPreference: 5,
        .privacyRecovery: 5
    ]

    func testFixtureHasRequiredCountAndCategoryDistribution() throws {
        let cases = try loadCases()
        let actualCounts = Dictionary(grouping: cases, by: \.category).mapValues(\.count)

        XCTAssertEqual(cases.count, 50, "上下文与记忆评测集必须恰好包含 50 条")
        XCTAssertEqual(actualCounts, Self.expectedCategoryCounts)
    }

    func testFixtureIDsAreUniqueAndRequiredOutcomesArePresent() throws {
        let cases = try loadCases()

        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count, "评测样例 ID 必须唯一")

        for evaluationCase in cases {
            XCTAssertFalse(evaluationCase.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(evaluationCase.context.isEmpty, "\(evaluationCase.id) 缺少上下文")
            XCTAssertTrue(
                evaluationCase.context.allSatisfy {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                },
                "\(evaluationCase.id) 包含空上下文"
            )
            XCTAssertFalse(
                evaluationCase.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(evaluationCase.id) 缺少输入"
            )
            XCTAssertFalse(
                evaluationCase.expectedOutcome.decision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(evaluationCase.id) 缺少 expected_outcome.decision"
            )
            XCTAssertFalse(
                evaluationCase.expectedOutcome.mustSatisfy.isEmpty,
                "\(evaluationCase.id) 缺少 expected_outcome.must_satisfy"
            )
            XCTAssertTrue(
                evaluationCase.expectedOutcome.mustSatisfy.allSatisfy {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                },
                "\(evaluationCase.id) 包含空的 expected outcome 断言"
            )
            XCTAssertFalse(
                evaluationCase.expectedOutcome.mustNot.isEmpty,
                "\(evaluationCase.id) 缺少 expected_outcome.must_not"
            )
            XCTAssertTrue(
                evaluationCase.expectedOutcome.mustNot.allSatisfy {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                },
                "\(evaluationCase.id) 包含空的 expected outcome 禁止项"
            )
        }
    }

    func testFixtureSchemaRoundTripsThroughCodable() throws {
        let cases = try loadCases()
        let encoded = try JSONEncoder().encode(cases)
        let decoded = try JSONDecoder().decode([AgentContextEvaluationCase].self, from: encoded)

        XCTAssertEqual(decoded, cases)
    }

    private func loadCases() throws -> [AgentContextEvaluationCase] {
#if SWIFT_PACKAGE
        let bundle = Bundle.module
#else
        let bundle = Bundle(for: Self.self)
#endif
        let fixtureURL = bundle.url(
            forResource: "agent_context_eval_cases",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: "agent_context_eval_cases", withExtension: "json")

        return try JSONDecoder().decode(
            [AgentContextEvaluationCase].self,
            from: Data(contentsOf: try XCTUnwrap(fixtureURL, "测试 bundle 中缺少 agent_context_eval_cases.json"))
        )
    }
}

private struct AgentContextEvaluationCase: Codable, Equatable {
    let id: String
    let category: AgentContextEvaluationCategory
    let context: [String]
    let input: String
    let expectedOutcome: AgentContextExpectedOutcome

    enum CodingKeys: String, CodingKey {
        case id, category, context, input
        case expectedOutcome = "expected_outcome"
    }
}

private enum AgentContextEvaluationCategory: String, Codable, CaseIterable {
    case recentObjectReference = "recent_object_reference"
    case displayOrdinal = "display_ordinal"
    case longConversationSummary = "long_conversation_summary"
    case sameNameSafety = "same_name_safety"
    case longTermPreference = "long_term_preference"
    case privacyRecovery = "privacy_recovery"
}

private struct AgentContextExpectedOutcome: Codable, Equatable {
    let decision: String
    let mustSatisfy: [String]
    let mustNot: [String]

    enum CodingKeys: String, CodingKey {
        case decision
        case mustSatisfy = "must_satisfy"
        case mustNot = "must_not"
    }
}
