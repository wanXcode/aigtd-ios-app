import Foundation

enum AgentExecutionPolicyDecision: String, Codable, Equatable, Sendable {
    case executeImmediately
    case requireClarification
    case requireConfirmation
    case reject
}

struct AgentExecutionPolicySettings: Equatable, Sendable {
    var confirmDeletion: Bool
    var confirmBulkChange: Bool
    var confirmNewListCreation: Bool
    var autoExecuteSimpleCreate: Bool
    var autoExecuteSimpleUpdate: Bool

    init(
        confirmDeletion: Bool = true,
        confirmBulkChange: Bool = true,
        confirmNewListCreation: Bool = true,
        autoExecuteSimpleCreate: Bool = true,
        autoExecuteSimpleUpdate: Bool = true
    ) {
        self.confirmDeletion = confirmDeletion
        self.confirmBulkChange = confirmBulkChange
        self.confirmNewListCreation = confirmNewListCreation
        self.autoExecuteSimpleCreate = autoExecuteSimpleCreate
        self.autoExecuteSimpleUpdate = autoExecuteSimpleUpdate
    }

    init(policy: ExecutionPolicy) {
        self.init(
            confirmDeletion: policy.confirmDeletion,
            confirmBulkChange: policy.confirmBulkChange,
            confirmNewListCreation: policy.confirmNewListCreation,
            autoExecuteSimpleCreate: policy.autoExecuteSimpleCreate,
            autoExecuteSimpleUpdate: policy.autoExecuteSimpleUpdate
        )
    }
}

/// Long-term rules intentionally expose only stricter choices. They cannot disable a system guard.
struct AgentExecutionPolicyLongTermRules: Equatable, Sendable {
    var requireConfirmationForAllWrites: Bool
    var requireConfirmationForDeletion: Bool
    var requireConfirmationForBulkChanges: Bool
    var requireConfirmationForNewListCreation: Bool
    var requireConfirmationForSimpleCreate: Bool
    var requireConfirmationForSimpleUpdate: Bool

    init(
        requireConfirmationForAllWrites: Bool = false,
        requireConfirmationForDeletion: Bool = false,
        requireConfirmationForBulkChanges: Bool = false,
        requireConfirmationForNewListCreation: Bool = false,
        requireConfirmationForSimpleCreate: Bool = false,
        requireConfirmationForSimpleUpdate: Bool = false
    ) {
        self.requireConfirmationForAllWrites = requireConfirmationForAllWrites
        self.requireConfirmationForDeletion = requireConfirmationForDeletion
        self.requireConfirmationForBulkChanges = requireConfirmationForBulkChanges
        self.requireConfirmationForNewListCreation = requireConfirmationForNewListCreation
        self.requireConfirmationForSimpleCreate = requireConfirmationForSimpleCreate
        self.requireConfirmationForSimpleUpdate = requireConfirmationForSimpleUpdate
    }

    init(memoryItems: [UserMemoryItem]) {
        self.init()
        for item in memoryItems where item.category == .transactionRule {
            let value = item.value.lowercased()
            guard value.contains("确认") || value.contains("confirm") else { continue }

            if Self.containsAny(value, ["所有操作", "所有任务操作", "每次操作", "all changes", "all writes"]) {
                requireConfirmationForAllWrites = true
            }
            if Self.containsAny(value, ["删除", "delete", "移除"]) {
                requireConfirmationForDeletion = true
            }
            if Self.containsAny(value, ["批量", "多项", "多个任务", "bulk"]) {
                requireConfirmationForBulkChanges = true
            }
            if Self.containsAny(value, ["新建清单", "创建清单", "新建列表", "create list"]) {
                requireConfirmationForNewListCreation = true
            }
            if Self.containsAny(value, ["新建任务", "创建任务", "新增任务", "create task", "create reminder"]) {
                requireConfirmationForSimpleCreate = true
            }
            if Self.containsAny(value, ["修改任务", "改期", "移动任务", "完成任务", "update task", "move task", "complete task"]) {
                requireConfirmationForSimpleUpdate = true
            }
        }
    }

    private static func containsAny(_ value: String, _ signals: [String]) -> Bool {
        signals.contains { value.contains($0) }
    }
}

struct AgentExecutionPolicyInput: Equatable, Sendable {
    let tool: AgentToolName
    let riskLevel: AgentToolRiskLevel
    let writeOperationCount: Int
    let affectedItemCount: Int
    let hasUniqueStableTarget: Bool
    let hasPreconditionSnapshot: Bool
    let isExplicitlyConfirmed: Bool
    let settings: AgentExecutionPolicySettings
    let longTermRules: AgentExecutionPolicyLongTermRules

    init(
        tool: AgentToolName,
        riskLevel: AgentToolRiskLevel,
        writeOperationCount: Int = 0,
        affectedItemCount: Int = 0,
        hasUniqueStableTarget: Bool = true,
        hasPreconditionSnapshot: Bool = true,
        isExplicitlyConfirmed: Bool = false,
        settings: AgentExecutionPolicySettings = .init(),
        longTermRules: AgentExecutionPolicyLongTermRules = .init()
    ) {
        self.tool = tool
        self.riskLevel = riskLevel
        self.writeOperationCount = writeOperationCount
        self.affectedItemCount = affectedItemCount
        self.hasUniqueStableTarget = hasUniqueStableTarget
        self.hasPreconditionSnapshot = hasPreconditionSnapshot
        self.isExplicitlyConfirmed = isExplicitlyConfirmed
        self.settings = settings
        self.longTermRules = longTermRules
    }
}

struct AgentExecutionPolicyEvaluator: Sendable {
    func evaluate(_ input: AgentExecutionPolicyInput) -> AgentExecutionPolicyDecision {
        guard input.writeOperationCount >= 0, input.affectedItemCount >= 0,
              let operation = Operation(tool: input.tool),
              operation.expectedRisk == input.riskLevel else {
            return .reject
        }

        guard operation.isWrite else {
            return input.writeOperationCount == 0 ? .executeImmediately : .reject
        }
        guard input.writeOperationCount > 0, input.affectedItemCount > 0 else {
            return .reject
        }

        // Confirmation never substitutes for resolving an identity or obtaining a fresh snapshot.
        if operation.requiresExistingTarget, input.hasUniqueStableTarget == false {
            return .requireClarification
        }
        if operation.requiresPreconditionSnapshot, input.hasPreconditionSnapshot == false {
            return .requireClarification
        }

        if input.isExplicitlyConfirmed {
            return .executeImmediately
        }

        let isBulk = input.writeOperationCount > 1 || input.affectedItemCount > 1
        if requiresConfirmation(operation: operation, isBulk: isBulk, input: input) {
            return .requireConfirmation
        }
        return .executeImmediately
    }

    private func requiresConfirmation(
        operation: Operation,
        isBulk: Bool,
        input: AgentExecutionPolicyInput
    ) -> Bool {
        let settings = input.settings
        let rules = input.longTermRules

        if rules.requireConfirmationForAllWrites { return true }
        if isBulk, settings.confirmBulkChange || rules.requireConfirmationForBulkChanges { return true }
        if operation == .deleteReminder,
           settings.confirmDeletion || rules.requireConfirmationForDeletion { return true }
        if operation == .createList,
           settings.confirmNewListCreation || rules.requireConfirmationForNewListCreation { return true }
        if operation == .createReminder,
           settings.autoExecuteSimpleCreate == false || rules.requireConfirmationForSimpleCreate { return true }
        if operation.isSimpleUpdate,
           settings.autoExecuteSimpleUpdate == false || rules.requireConfirmationForSimpleUpdate { return true }

        // Unknown future high-risk behavior must not become automatic through permissive settings.
        return input.riskLevel == .highRiskWrite && operation != .deleteReminder
    }
}

private extension AgentExecutionPolicyEvaluator {
    enum Operation: Equatable {
        case searchReminders
        case getReminderDetails
        case proposeSchedule
        case createReminder
        case createList
        case updateReminder
        case moveReminder
        case completeReminder
        case deleteReminder
        case applySchedule

        init?(tool: AgentToolName) {
            switch tool {
            case .searchReminders: self = .searchReminders
            case .getReminderDetails: self = .getReminderDetails
            case .proposeSchedule: self = .proposeSchedule
            case .createReminder: self = .createReminder
            case .createList: self = .createList
            case .updateReminder: self = .updateReminder
            case .moveReminder: self = .moveReminder
            case .completeReminder: self = .completeReminder
            case .deleteReminder: self = .deleteReminder
            case .applySchedule: self = .applySchedule
            default: return nil
            }
        }

        var expectedRisk: AgentToolRiskLevel {
            switch self {
            case .searchReminders, .getReminderDetails, .proposeSchedule: .readOnly
            case .createReminder, .updateReminder, .moveReminder, .completeReminder: .lowRiskWrite
            case .createList, .applySchedule: .mediumRiskWrite
            case .deleteReminder: .highRiskWrite
            }
        }

        var isWrite: Bool { expectedRisk != .readOnly }

        var requiresExistingTarget: Bool {
            switch self {
            case .updateReminder, .moveReminder, .completeReminder, .deleteReminder, .applySchedule: true
            default: false
            }
        }

        var requiresPreconditionSnapshot: Bool { requiresExistingTarget }

        var isSimpleUpdate: Bool {
            switch self {
            case .updateReminder, .moveReminder, .completeReminder: true
            default: false
            }
        }
    }
}
