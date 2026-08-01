import XCTest
@testable import AIGTDReminders

final class AgentExecutionPolicyEvaluatorTests: XCTestCase {
    private let evaluator = AgentExecutionPolicyEvaluator()

    func testSettingsSnapshotCopiesExecutionPolicy() {
        let policy = ExecutionPolicy(
            confirmDeletion: false,
            confirmBulkChange: false,
            confirmNewListCreation: false,
            autoExecuteSimpleCreate: false,
            autoExecuteSimpleUpdate: false
        )

        XCTAssertEqual(
            AgentExecutionPolicySettings(policy: policy),
            AgentExecutionPolicySettings(
                confirmDeletion: false,
                confirmBulkChange: false,
                confirmNewListCreation: false,
                autoExecuteSimpleCreate: false,
                autoExecuteSimpleUpdate: false
            )
        )
    }

    func testReadOnlyToolsExecuteImmediatelyWithoutWriteMetadata() {
        for tool in [AgentToolName.searchReminders, .getReminderDetails, .proposeSchedule] {
            XCTAssertEqual(evaluate(tool: tool, risk: .readOnly), .executeImmediately)
        }
    }

    func testReadOnlyToolRejectsWriteCount() {
        XCTAssertEqual(
            evaluate(tool: .searchReminders, risk: .readOnly, writes: 1, affected: 1),
            .reject
        )
    }

    func testUnknownToolAndRiskMismatchAreRejected() {
        XCTAssertEqual(evaluate(tool: "future_tool", risk: .highRiskWrite), .reject)
        XCTAssertEqual(
            evaluate(tool: .deleteReminder, risk: .lowRiskWrite, writes: 1, affected: 1),
            .reject
        )
    }

    func testWriteRequiresPositiveOperationAndAffectedCounts() {
        XCTAssertEqual(evaluate(tool: .createReminder, risk: .lowRiskWrite), .reject)
        XCTAssertEqual(
            evaluate(tool: .createReminder, risk: .lowRiskWrite, writes: 1, affected: 0),
            .reject
        )
    }

    func testSimpleCreateFollowsAutoExecuteSetting() {
        XCTAssertEqual(
            evaluate(tool: .createReminder, risk: .lowRiskWrite, writes: 1, affected: 1),
            .executeImmediately
        )
        XCTAssertEqual(
            evaluate(
                tool: .createReminder,
                risk: .lowRiskWrite,
                writes: 1,
                affected: 1,
                settings: .init(autoExecuteSimpleCreate: false)
            ),
            .requireConfirmation
        )
    }

    func testSimpleUpdateRequiresUniqueTargetAndSnapshotBeforePolicy() {
        XCTAssertEqual(
            evaluate(
                tool: .updateReminder,
                risk: .lowRiskWrite,
                writes: 1,
                affected: 1,
                unique: false,
                snapshot: true,
                confirmed: true
            ),
            .requireClarification
        )
        XCTAssertEqual(
            evaluate(
                tool: .updateReminder,
                risk: .lowRiskWrite,
                writes: 1,
                affected: 1,
                unique: true,
                snapshot: false,
                confirmed: true
            ),
            .requireClarification
        )
    }

    func testSimpleUpdateFollowsAutoExecuteSetting() {
        XCTAssertEqual(
            evaluate(tool: .moveReminder, risk: .lowRiskWrite, writes: 1, affected: 1),
            .executeImmediately
        )
        XCTAssertEqual(
            evaluate(
                tool: .completeReminder,
                risk: .lowRiskWrite,
                writes: 1,
                affected: 1,
                settings: .init(autoExecuteSimpleUpdate: false)
            ),
            .requireConfirmation
        )
    }

    func testDeletionFollowsDeletionPolicyAfterSafetyGates() {
        XCTAssertEqual(
            evaluate(tool: .deleteReminder, risk: .highRiskWrite, writes: 1, affected: 1),
            .requireConfirmation
        )
        XCTAssertEqual(
            evaluate(
                tool: .deleteReminder,
                risk: .highRiskWrite,
                writes: 1,
                affected: 1,
                settings: .init(confirmDeletion: false)
            ),
            .executeImmediately
        )
    }

    func testNewListCreationFollowsPolicy() {
        XCTAssertEqual(
            evaluate(tool: .createList, risk: .mediumRiskWrite, writes: 1, affected: 1),
            .requireConfirmation
        )
        XCTAssertEqual(
            evaluate(
                tool: .createList,
                risk: .mediumRiskWrite,
                writes: 1,
                affected: 1,
                settings: .init(confirmNewListCreation: false)
            ),
            .executeImmediately
        )
    }

    func testBulkOperationRequiresConfirmationByDefault() {
        XCTAssertEqual(
            evaluate(tool: .updateReminder, risk: .lowRiskWrite, writes: 2, affected: 2),
            .requireConfirmation
        )
        XCTAssertEqual(
            evaluate(
                tool: .applySchedule,
                risk: .mediumRiskWrite,
                writes: 1,
                affected: 3,
                settings: .init(confirmBulkChange: false)
            ),
            .executeImmediately
        )
    }

    func testExplicitConfirmationReleasesPolicyConfirmationButNotSafetyGates() {
        XCTAssertEqual(
            evaluate(
                tool: .deleteReminder,
                risk: .highRiskWrite,
                writes: 1,
                affected: 1,
                confirmed: true
            ),
            .executeImmediately
        )
        XCTAssertEqual(
            evaluate(
                tool: .applySchedule,
                risk: .mediumRiskWrite,
                writes: 3,
                affected: 3,
                snapshot: false,
                confirmed: true
            ),
            .requireClarification
        )
    }

    func testLongTermRulesCanTightenPermissiveSettings() {
        let permissive = AgentExecutionPolicySettings(
            confirmDeletion: false,
            confirmBulkChange: false,
            confirmNewListCreation: false,
            autoExecuteSimpleCreate: true,
            autoExecuteSimpleUpdate: true
        )

        XCTAssertEqual(
            evaluate(
                tool: .deleteReminder,
                risk: .highRiskWrite,
                writes: 1,
                affected: 1,
                settings: permissive,
                rules: .init(requireConfirmationForDeletion: true)
            ),
            .requireConfirmation
        )
        XCTAssertEqual(
            evaluate(
                tool: .createReminder,
                risk: .lowRiskWrite,
                writes: 1,
                affected: 1,
                settings: permissive,
                rules: .init(requireConfirmationForSimpleCreate: true)
            ),
            .requireConfirmation
        )
        XCTAssertEqual(
            evaluate(
                tool: .moveReminder,
                risk: .lowRiskWrite,
                writes: 1,
                affected: 1,
                settings: permissive,
                rules: .init(requireConfirmationForAllWrites: true)
            ),
            .requireConfirmation
        )
    }

    func testExplicitConfirmationSatisfiesLongTermConfirmationRequirement() {
        XCTAssertEqual(
            evaluate(
                tool: .createReminder,
                risk: .lowRiskWrite,
                writes: 1,
                affected: 1,
                confirmed: true,
                rules: .init(requireConfirmationForAllWrites: true)
            ),
            .executeImmediately
        )
    }

    func testLongTermMemoryMapsOnlyConfirmationTransactionRules() {
        let now = Date()
        let rules = AgentExecutionPolicyLongTermRules(memoryItems: [
            UserMemoryItem(
                id: UUID(),
                category: .transactionRule,
                value: "所有删除任务都要先确认",
                sourceMessageID: nil,
                createdAt: now,
                updatedAt: now
            ),
            UserMemoryItem(
                id: UUID(),
                category: .transactionRule,
                value: "完成任务前也要确认",
                sourceMessageID: nil,
                createdAt: now,
                updatedAt: now
            ),
            UserMemoryItem(
                id: UUID(),
                category: .defaultList,
                value: "删除清单",
                sourceMessageID: nil,
                createdAt: now,
                updatedAt: now
            )
        ])

        XCTAssertTrue(rules.requireConfirmationForDeletion)
        XCTAssertTrue(rules.requireConfirmationForSimpleUpdate)
        XCTAssertFalse(rules.requireConfirmationForAllWrites)
        XCTAssertFalse(rules.requireConfirmationForNewListCreation)
    }

    private func evaluate(
        tool: AgentToolName,
        risk: AgentToolRiskLevel,
        writes: Int = 0,
        affected: Int = 0,
        unique: Bool = true,
        snapshot: Bool = true,
        confirmed: Bool = false,
        settings: AgentExecutionPolicySettings = .init(),
        rules: AgentExecutionPolicyLongTermRules = .init()
    ) -> AgentExecutionPolicyDecision {
        evaluator.evaluate(
            AgentExecutionPolicyInput(
                tool: tool,
                riskLevel: risk,
                writeOperationCount: writes,
                affectedItemCount: affected,
                hasUniqueStableTarget: unique,
                hasPreconditionSnapshot: snapshot,
                isExplicitlyConfirmed: confirmed,
                settings: settings,
                longTermRules: rules
            )
        )
    }
}
