import Foundation

enum AgentPendingInteractionStatus: String, Codable, Equatable, Sendable {
    case active
    case superseded
    case cancelled
    case expired
}

struct AgentPendingInteraction: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { interactionID }

    let interactionID: UUID
    let sessionID: UUID
    let runID: UUID
    let version: Int
    let goal: String
    let pendingCalls: [AgentToolCall]
    let priorResults: [AgentToolResult]
    let createdAt: Date
    let expiresAt: Date
    var status: AgentPendingInteractionStatus

    private enum CodingKeys: String, CodingKey {
        case interactionID = "interaction_id"
        case sessionID = "session_id"
        case runID = "run_id"
        case version
        case goal
        case pendingCalls = "pending_calls"
        case priorResults = "prior_results"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case status
    }
}

private struct AgentPendingInteractionStoreEnvelope: Codable {
    let schemaVersion: Int
    var interactions: [AgentPendingInteraction]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case interactions
    }
}

final class AgentPendingInteractionStore: @unchecked Sendable {
    static let shared = AgentPendingInteractionStore()
    static let currentSchemaVersion = 1
    static let defaultStorageKey = "aigtd.agent.pending-interactions.v1"
    static let defaultExpirationInterval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let storageKey: String
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = AgentPendingInteractionStore.defaultStorageKey,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.now = now
        withLock {
            var interactions = loadUnlocked()
            if expireActiveUnlocked(&interactions, at: now()) {
                saveUnlocked(interactions)
            }
        }
    }

    @discardableResult
    func create(
        interactionID: UUID = UUID(),
        sessionID: UUID,
        runID: UUID,
        goal: String,
        pendingCalls: [AgentToolCall],
        priorResults: [AgentToolResult] = [],
        expirationInterval: TimeInterval = AgentPendingInteractionStore.defaultExpirationInterval
    ) throws -> AgentPendingInteraction {
        let normalizedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedGoal.isEmpty == false else {
            throw AgentToolError(category: .invalidArguments, userVisibleMessage: "待确认目标不能为空。")
        }
        guard pendingCalls.isEmpty == false else {
            throw AgentToolError(category: .invalidArguments, userVisibleMessage: "待确认操作不能为空。")
        }
        let callIDs = pendingCalls.map(\.callID)
        guard callIDs.allSatisfy({ $0.isEmpty == false }), Set(callIDs).count == callIDs.count else {
            throw AgentToolError(category: .invalidArguments, userVisibleMessage: "待确认操作包含无效或重复调用。")
        }
        guard expirationInterval > 0 else {
            throw AgentToolError(category: .invalidArguments, userVisibleMessage: "待确认操作的有效期无效。")
        }

        return withLock {
            var interactions = loadUnlocked()
            let timestamp = now()
            _ = expireActiveUnlocked(&interactions, at: timestamp)

            for index in interactions.indices
                where interactions[index].sessionID == sessionID && interactions[index].status == .active {
                interactions[index].status = .superseded
            }

            let nextVersion = interactions
                .lazy
                .filter { $0.sessionID == sessionID }
                .map(\.version)
                .max()
                .map { $0 + 1 } ?? 1
            let interaction = AgentPendingInteraction(
                interactionID: interactionID,
                sessionID: sessionID,
                runID: runID,
                version: nextVersion,
                goal: normalizedGoal,
                pendingCalls: pendingCalls,
                priorResults: priorResults,
                createdAt: timestamp,
                expiresAt: timestamp.addingTimeInterval(expirationInterval),
                status: .active
            )
            interactions.append(interaction)
            saveUnlocked(interactions)
            return interaction
        }
    }

    func active(for sessionID: UUID) -> AgentPendingInteraction? {
        withLock {
            var interactions = loadUnlocked()
            if expireActiveUnlocked(&interactions, at: now()) {
                saveUnlocked(interactions)
            }
            return interactions.first { $0.sessionID == sessionID && $0.status == .active }
        }
    }

    func interaction(id: UUID) -> AgentPendingInteraction? {
        withLock {
            var interactions = loadUnlocked()
            if expireActiveUnlocked(&interactions, at: now()) {
                saveUnlocked(interactions)
            }
            return interactions.first { $0.interactionID == id }
        }
    }

    func interactions(for sessionID: UUID? = nil) -> [AgentPendingInteraction] {
        withLock {
            var interactions = loadUnlocked()
            if expireActiveUnlocked(&interactions, at: now()) {
                saveUnlocked(interactions)
            }
            return interactions
                .filter { sessionID == nil || $0.sessionID == sessionID }
                .sorted {
                    $0.createdAt == $1.createdAt ? $0.version > $1.version : $0.createdAt > $1.createdAt
                }
        }
    }

    @discardableResult
    func supersede(id: UUID) throws -> AgentPendingInteraction {
        try transition(id: id, to: .superseded)
    }

    @discardableResult
    func cancel(id: UUID) throws -> AgentPendingInteraction {
        try transition(id: id, to: .cancelled)
    }

    func expireInteractions() {
        withLock {
            var interactions = loadUnlocked()
            if expireActiveUnlocked(&interactions, at: now()) {
                saveUnlocked(interactions)
            }
        }
    }

    func clear() {
        withLock { defaults.removeObject(forKey: storageKey) }
    }

    private func transition(
        id: UUID,
        to status: AgentPendingInteractionStatus
    ) throws -> AgentPendingInteraction {
        try withLock {
            var interactions = loadUnlocked()
            _ = expireActiveUnlocked(&interactions, at: now())
            guard let index = interactions.firstIndex(where: { $0.interactionID == id }) else {
                saveUnlocked(interactions)
                throw AgentToolError(category: .notFound, userVisibleMessage: "没有找到待确认方案。")
            }
            guard interactions[index].status == .active else {
                saveUnlocked(interactions)
                throw AgentToolError(category: .staleReference, userVisibleMessage: "该待确认方案已失效。")
            }
            interactions[index].status = status
            let interaction = interactions[index]
            saveUnlocked(interactions)
            return interaction
        }
    }

    @discardableResult
    private func expireActiveUnlocked(
        _ interactions: inout [AgentPendingInteraction],
        at timestamp: Date
    ) -> Bool {
        var changed = false
        for index in interactions.indices
            where interactions[index].status == .active && interactions[index].expiresAt <= timestamp {
            interactions[index].status = .expired
            changed = true
        }
        return changed
    }

    private func loadUnlocked() -> [AgentPendingInteraction] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        guard let envelope = try? JSONDecoder().decode(AgentPendingInteractionStoreEnvelope.self, from: data),
              envelope.schemaVersion == Self.currentSchemaVersion else {
            defaults.removeObject(forKey: storageKey)
            return []
        }
        return envelope.interactions
    }

    private func saveUnlocked(_ interactions: [AgentPendingInteraction]) {
        guard interactions.isEmpty == false else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        let envelope = AgentPendingInteractionStoreEnvelope(
            schemaVersion: Self.currentSchemaVersion,
            interactions: interactions
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
