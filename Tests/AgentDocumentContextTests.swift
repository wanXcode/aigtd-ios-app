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
}
