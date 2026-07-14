import Foundation

enum AgentSummaryMessageRole: Equatable, Sendable {
    case user
    case assistant
    case system
}

struct AgentSummaryMessage: Equatable, Sendable {
    let id: UUID
    let role: AgentSummaryMessageRole
    let currentGoal: String?
    let taskScope: String?
    let confirmedConstraints: [String]
    let pendingQuestions: [String]

    init(
        id: UUID,
        role: AgentSummaryMessageRole,
        currentGoal: String? = nil,
        taskScope: String? = nil,
        confirmedConstraints: [String] = [],
        pendingQuestions: [String] = []
    ) {
        self.id = id
        self.role = role
        self.currentGoal = currentGoal
        self.taskScope = taskScope
        self.confirmedConstraints = confirmedConstraints
        self.pendingQuestions = pendingQuestions
    }
}

enum AgentSuccessfulActionKind: String, Equatable, Sendable {
    case create
    case modify
    case move
    case complete
    case delete
    case show
}

struct AgentActionSummaryFact: Equatable, Sendable {
    let messageID: UUID?
    let kind: AgentSuccessfulActionKind
    let succeeded: Bool
    let readableFact: String?
    let reminderIDs: [String]

    init(
        messageID: UUID? = nil,
        kind: AgentSuccessfulActionKind,
        succeeded: Bool,
        readableFact: String? = nil,
        reminderIDs: [String] = []
    ) {
        self.messageID = messageID
        self.kind = kind
        self.succeeded = succeeded
        self.readableFact = readableFact
        self.reminderIDs = reminderIDs
    }
}

struct AgentSessionSummaryService: Sendable {
    static let initialMessageThreshold = 8
    static let incrementalMessageThreshold = 6
    static let maximumSummaryCharacterCount = 1_200

    func shouldUpdate(
        existing: SessionSummary?,
        messages: [AgentSummaryMessage],
        actionFacts: [AgentActionSummaryFact] = []
    ) -> Bool {
        let validMessages = messages.filter(\.isValidConversationMessage)
        let newMessages = messagesAfterCoverage(validMessages, existing: existing)
        let hasNewSuccessfulAction = actionFacts.contains { fact in
            guard fact.succeeded else { return false }
            guard let coveredID = existing?.coveredThroughMessageID,
                  let messageID = fact.messageID,
                  let coveredIndex = validMessages.firstIndex(where: { $0.id == coveredID }),
                  let actionIndex = validMessages.firstIndex(where: { $0.id == messageID }) else {
                return true
            }
            return actionIndex > coveredIndex
        }

        if hasNewSuccessfulAction { return true }
        if existing == nil { return validMessages.count > Self.initialMessageThreshold }
        return newMessages.count >= Self.incrementalMessageThreshold
    }

    func update(
        existing: SessionSummary?,
        messages: [AgentSummaryMessage],
        actionFacts: [AgentActionSummaryFact] = [],
        now: Date = .now
    ) -> SessionSummary? {
        guard shouldUpdate(existing: existing, messages: messages, actionFacts: actionFacts) else {
            return existing
        }

        let validMessages = messages.filter(\.isValidConversationMessage)
        let newMessages = messagesAfterCoverage(validMessages, existing: existing)
        let successfulActions = actionFacts.filter(\.succeeded)

        var goal = existing?.currentGoal
        var scope = existing?.taskScope
        var constraints = existing?.confirmedConstraints ?? []
        var questions = existing?.pendingQuestions ?? []
        var reminderIDs = existing?.relatedReminderIDs ?? []

        for message in newMessages where message.role == .user {
            if let candidate = sanitized(message.currentGoal) { goal = candidate }
            if let candidate = sanitized(message.taskScope) { scope = candidate }
            constraints.append(contentsOf: message.confirmedConstraints.compactMap(sanitized))
            questions.append(contentsOf: message.pendingQuestions.compactMap(sanitized))
        }

        for action in successfulActions {
            reminderIDs.append(contentsOf: action.reminderIDs.compactMap(sanitizedIdentifier))
            if let fact = sanitized(action.readableFact) {
                // The v0.4 contract has no separate executed-facts field. Keep verified
                // facts visibly distinct from user constraints in the closest safe field.
                constraints.append("已执行：\(fact)")
            }
        }

        let budgeted = applyCharacterBudget(
            goal: goal,
            scope: scope,
            constraints: unique(constraints, limit: 16),
            questions: unique(questions, limit: 12),
            reminderIDs: unique(reminderIDs, limit: 40)
        )
        return SessionSummary(
            currentGoal: goal,
            taskScope: scope,
            confirmedConstraints: budgeted.constraints,
            pendingQuestions: budgeted.questions,
            relatedReminderIDs: budgeted.reminderIDs,
            coveredThroughMessageID: validMessages.last?.id ?? existing?.coveredThroughMessageID,
            updatedAt: now
        )
    }

    private func messagesAfterCoverage(
        _ messages: [AgentSummaryMessage],
        existing: SessionSummary?
    ) -> ArraySlice<AgentSummaryMessage> {
        guard let coveredID = existing?.coveredThroughMessageID,
              let coveredIndex = messages.firstIndex(where: { $0.id == coveredID }) else {
            return messages[...]
        }
        return messages[messages.index(after: coveredIndex)...]
    }

    private func sanitized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false, containsCredential(normalized) == false else { return nil }
        return String(normalized.prefix(240))
    }

    private func sanitizedIdentifier(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false,
              normalized.count <= 256,
              normalized.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }
        return normalized
    }

    private func containsCredential(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return ["api key", "apikey", "authorization", "bearer ", "password", "token", "secret", "密码", "密钥", "凭证"]
            .contains { lowered.contains($0) }
    }

    private func unique(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        return Array(values.filter { seen.insert($0).inserted }.suffix(limit))
    }

    private func applyCharacterBudget(
        goal: String?,
        scope: String?,
        constraints: [String],
        questions: [String],
        reminderIDs: [String]
    ) -> (constraints: [String], questions: [String], reminderIDs: [String]) {
        var constraints = constraints
        var questions = questions
        var reminderIDs = reminderIDs

        func characterCount() -> Int {
            [goal, scope].compactMap { $0 }.joined().count
                + constraints.joined().count
                + questions.joined().count
                + reminderIDs.joined().count
        }

        while characterCount() > Self.maximumSummaryCharacterCount {
            if questions.isEmpty == false {
                questions.removeFirst()
            } else if constraints.isEmpty == false {
                constraints.removeFirst()
            } else if reminderIDs.isEmpty == false {
                reminderIDs.removeFirst()
            } else {
                break
            }
        }
        return (constraints, questions, reminderIDs)
    }
}

private extension AgentSummaryMessage {
    var isValidConversationMessage: Bool {
        role == .user || role == .assistant
    }
}
