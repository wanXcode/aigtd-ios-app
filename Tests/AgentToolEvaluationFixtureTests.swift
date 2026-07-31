import Foundation
import XCTest

final class AgentToolEvaluationFixtureTests: XCTestCase {
    private static let expectedCounts = [
        "query_then_write": 8,
        "multi_write": 8,
        "dependency": 6,
        "ambiguity": 4,
        "partial_failure": 4,
        "chat": 4,
        "protocol_error": 3,
        "budget": 3
    ]

    func testFixtureHasFortyUniqueCasesWithRequiredDistribution() throws {
        let cases = try loadCases()
        XCTAssertEqual(cases.count, 40)
        XCTAssertEqual(Set(cases.map(\.id)).count, 40)
        XCTAssertEqual(Dictionary(grouping: cases, by: \.category).mapValues(\.count), Self.expectedCounts)
    }

    func testEveryCaseDefinesObservableSafetyOutcome() throws {
        for item in try loadCases() {
            XCTAssertFalse(item.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.id)
            XCTAssertFalse(item.expected.phase.isEmpty, item.id)
            XCTAssertFalse(item.expected.mustNot.isEmpty, item.id)
            XCTAssertEqual(Set(item.expected.tools).count, item.expected.tools.count, "\(item.id) 重复声明工具")
            if item.expected.requiresConfirmation {
                let batchCategory = ["multi_write", "dependency", "partial_failure"].contains(item.category)
                XCTAssertTrue(
                    batchCategory || item.expected.tools.count > 1
                        || item.expected.tools.contains("delete_reminder")
                        || item.expected.tools.contains("apply_schedule")
                        || item.expected.tools.contains("create_list"),
                    item.id
                )
            }
            if item.category == "chat" {
                XCTAssertTrue(item.expected.tools.isEmpty, item.id)
                XCTAssertEqual(item.expected.phase, "final", item.id)
            }
        }
    }

    func testFixtureRoundTripsThroughCodable() throws {
        let cases = try loadCases()
        XCTAssertEqual(try JSONDecoder().decode([ToolEvaluationCase].self, from: JSONEncoder().encode(cases)), cases)
    }

    private func loadCases() throws -> [ToolEvaluationCase] {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: "agent_tool_eval_cases", withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "agent_tool_eval_cases", withExtension: "json")
        return try JSONDecoder().decode([ToolEvaluationCase].self, from: Data(contentsOf: try XCTUnwrap(url)))
    }
}

private struct ToolEvaluationCase: Codable, Equatable {
    let id: String
    let category: String
    let input: String
    let context: [String]
    let expected: ToolEvaluationOutcome
}

private struct ToolEvaluationOutcome: Codable, Equatable {
    let phase: String
    let tools: [String]
    let requiresConfirmation: Bool
    let mustNot: [String]

    enum CodingKeys: String, CodingKey {
        case phase, tools
        case requiresConfirmation = "requires_confirmation"
        case mustNot = "must_not"
    }
}
