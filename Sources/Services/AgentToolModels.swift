import Foundation

struct AgentToolName: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let searchReminders: Self = "search_reminders"
    static let getReminderDetails: Self = "get_reminder_details"
    static let createReminder: Self = "create_reminder"
    static let createList: Self = "create_list"
    static let updateReminder: Self = "update_reminder"
    static let moveReminder: Self = "move_reminder"
    static let completeReminder: Self = "complete_reminder"
    static let deleteReminder: Self = "delete_reminder"
    static let proposeSchedule: Self = "propose_schedule"
    static let applySchedule: Self = "apply_schedule"
}

enum AgentJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case object([String: AgentJSONValue])
    case array([AgentJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AgentJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([AgentJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

struct AgentToolArguments: Codable, Equatable, Sendable {
    let values: [String: AgentJSONValue]

    init(_ values: [String: AgentJSONValue] = [:]) {
        self.values = values
    }

    subscript(key: String) -> AgentJSONValue? {
        values[key]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        values = try container.decode([String: AgentJSONValue].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

enum AgentToolRiskLevel: String, Codable, Sendable {
    case readOnly = "read_only"
    case lowRiskWrite = "low_risk_write"
    case mediumRiskWrite = "medium_risk_write"
    case highRiskWrite = "high_risk_write"
}

struct AgentToolCall: Codable, Equatable, Sendable {
    let callID: String
    let tool: AgentToolName
    let arguments: AgentToolArguments
    let dependencyCallIDs: [String]?

    init(
        callID: String,
        tool: AgentToolName,
        arguments: AgentToolArguments = .init(),
        dependencyCallIDs: [String]? = nil
    ) {
        self.callID = callID
        self.tool = tool
        self.arguments = arguments
        self.dependencyCallIDs = dependencyCallIDs
    }

    private enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case tool
        case arguments
        case dependencyCallIDs = "depends_on"
    }
}

enum AgentToolExecutionStatus: String, Codable, Sendable {
    case queued
    case running
    case awaitingConfirmation = "awaiting_confirmation"
    case success
    case failed
    case skipped
    case cancelled
    case timedOut = "timed_out"
    case unchanged
    case alreadyApplied = "already_applied"
}

enum AgentToolErrorCategory: String, Codable, Sendable {
    case permissionDenied = "permission_denied"
    case notFound = "not_found"
    case ambiguousTarget = "ambiguous_target"
    case invalidArguments = "invalid_arguments"
    case listNotFound = "list_not_found"
    case staleReference = "stale_reference"
    case preconditionConflict = "precondition_conflict"
    case confirmationRequired = "confirmation_required"
    case planExpired = "plan_expired"
    case timeout
    case cancelled
    case budgetExhausted = "budget_exhausted"
    case modelProtocolError = "model_protocol_error"
    case eventKitError = "eventkit_error"
    case networkError = "network_error"
    case unknownTool = "unknown_tool"
    case toolExecutionFailed = "tool_execution_failed"
}

struct AgentToolError: Error, Codable, Equatable, Sendable {
    let category: AgentToolErrorCategory
    let userVisibleMessage: String

    init(category: AgentToolErrorCategory, userVisibleMessage: String) {
        self.category = category
        self.userVisibleMessage = userVisibleMessage
    }

    private enum CodingKeys: String, CodingKey {
        case category
        case userVisibleMessage = "user_visible_message"
    }
}

struct AgentToolExecutionOutput: Codable, Equatable, Sendable {
    let status: AgentToolExecutionStatus
    let result: AgentToolArguments

    init(status: AgentToolExecutionStatus = .success, result: AgentToolArguments = .init()) {
        self.status = status
        self.result = result
    }
}

struct AgentToolResult: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let runID: UUID
    let callID: String
    let tool: AgentToolName
    let status: AgentToolExecutionStatus
    let result: AgentToolArguments?
    let error: AgentToolError?

    init(
        schemaVersion: Int = 1,
        runID: UUID,
        callID: String,
        tool: AgentToolName,
        status: AgentToolExecutionStatus,
        result: AgentToolArguments? = nil,
        error: AgentToolError? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.callID = callID
        self.tool = tool
        self.status = status
        self.result = result
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case callID = "call_id"
        case tool
        case status
        case result
        case error
    }
}

enum AgentModelDecisionPhase: String, Codable, Sendable {
    case toolCalls = "tool_calls"
    case awaitingClarification = "awaiting_clarification"
    case awaitingConfirmation = "awaiting_confirmation"
    case final
}

struct AgentModelDecision: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let runID: UUID
    let goal: String
    let phase: AgentModelDecisionPhase
    let assistantDraft: String?
    let toolCalls: [AgentToolCall]
    let finalReply: String?

    init(
        schemaVersion: Int = 1,
        runID: UUID,
        goal: String,
        phase: AgentModelDecisionPhase,
        assistantDraft: String? = nil,
        toolCalls: [AgentToolCall] = [],
        finalReply: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.goal = goal
        self.phase = phase
        self.assistantDraft = assistantDraft
        self.toolCalls = toolCalls
        self.finalReply = finalReply
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case goal
        case phase
        case assistantDraft = "assistant_draft"
        case toolCalls = "tool_calls"
        case finalReply = "final_reply"
    }
}

struct AgentModelRequest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let runID: UUID
    let userInput: String
    let modelTurn: Int
    let toolResults: [AgentToolResult]
    let contextSnapshot: AgentContextSnapshot?

    init(
        schemaVersion: Int = 1,
        runID: UUID,
        userInput: String,
        modelTurn: Int,
        toolResults: [AgentToolResult],
        contextSnapshot: AgentContextSnapshot? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.userInput = userInput
        self.modelTurn = modelTurn
        self.toolResults = toolResults
        self.contextSnapshot = contextSnapshot
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case userInput = "user_input"
        case modelTurn = "model_turn"
        case toolResults = "tool_results"
        case contextSnapshot = "context_snapshot"
    }
}

enum AgentRunStatus: String, Codable, Sendable {
    case idle
    case preparingContext = "preparing_context"
    case deciding
    case executingReads = "executing_reads"
    case awaitingClarification = "awaiting_clarification"
    case awaitingConfirmation = "awaiting_confirmation"
    case executingWrites = "executing_writes"
    case synthesizing
    case succeeded
    case partial
    case failed
    case cancelled
}

struct AgentRunResult: Codable, Equatable, Sendable {
    let runID: UUID
    let goal: String
    let status: AgentRunStatus
    let finalReply: String?
    let modelTurns: Int
    let toolCallCount: Int
    let toolResults: [AgentToolResult]
    let pendingToolCalls: [AgentToolCall]
    let error: AgentToolError?

    init(
        runID: UUID,
        goal: String,
        status: AgentRunStatus,
        finalReply: String?,
        modelTurns: Int,
        toolCallCount: Int,
        toolResults: [AgentToolResult],
        pendingToolCalls: [AgentToolCall] = [],
        error: AgentToolError?
    ) {
        self.runID = runID
        self.goal = goal
        self.status = status
        self.finalReply = finalReply
        self.modelTurns = modelTurns
        self.toolCallCount = toolCallCount
        self.toolResults = toolResults
        self.pendingToolCalls = pendingToolCalls
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case goal
        case status
        case finalReply = "final_reply"
        case modelTurns = "model_turns"
        case toolCallCount = "tool_call_count"
        case toolResults = "tool_results"
        case pendingToolCalls = "pending_tool_calls"
        case error
    }
}

protocol AgentModelClient: Sendable {
    func decide(_ request: AgentModelRequest) async throws -> AgentModelDecision
}

protocol AgentToolExecutor: Sendable {
    var toolName: AgentToolName { get }
    var riskLevel: AgentToolRiskLevel { get }

    func execute(
        arguments: AgentToolArguments,
        runID: UUID,
        callID: String
    ) async throws -> AgentToolExecutionOutput
}
