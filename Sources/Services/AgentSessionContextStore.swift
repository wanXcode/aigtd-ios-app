import Foundation

struct StoredAgentSessionContext: Codable, Equatable, Sendable {
    let sessionID: UUID
    var summary: SessionSummary?
    var references: ReferenceContext
    var updatedAt: Date
}

private struct AgentSessionContextEnvelope: Codable {
    let schemaVersion: Int
    var records: [StoredAgentSessionContext]
}

final class AgentSessionContextStore: @unchecked Sendable {
    static let shared = AgentSessionContextStore()
    static let currentSchemaVersion = 1

    private let defaults: UserDefaults
    private let storageKey: String
    private let now: @Sendable () -> Date
    private let retentionInterval: TimeInterval
    private let staleReferenceRetentionInterval: TimeInterval
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "aigtd.agent-session-context.v1",
        retentionInterval: TimeInterval = 30 * 24 * 60 * 60,
        staleReferenceRetentionInterval: TimeInterval = 7 * 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.retentionInterval = retentionInterval
        self.staleReferenceRetentionInterval = staleReferenceRetentionInterval
        self.now = now
        prune()
    }

    func context(for sessionID: UUID) -> StoredAgentSessionContext? {
        lock.withAgentContextLock {
            let timestamp = now()
            let records = pruned(loadUnlocked(), referenceDate: timestamp)
            saveUnlocked(records)
            return records.first { $0.sessionID == sessionID }
        }
    }

    func save(_ context: StoredAgentSessionContext) {
        lock.withAgentContextLock {
            var records = loadUnlocked()
            if let index = records.firstIndex(where: { $0.sessionID == context.sessionID }) {
                records[index] = context
            } else {
                records.append(context)
            }
            saveUnlocked(pruned(records, referenceDate: now()))
        }
    }

    @discardableResult
    func update(
        sessionID: UUID,
        summary: SessionSummary? = nil,
        references: ReferenceContext? = nil
    ) -> StoredAgentSessionContext {
        lock.withAgentContextLock {
            let timestamp = now()
            var records = loadUnlocked()
            let existing = records.first(where: { $0.sessionID == sessionID })
            let updated = StoredAgentSessionContext(
                sessionID: sessionID,
                summary: summary ?? existing?.summary,
                references: references ?? existing?.references ?? .empty,
                updatedAt: timestamp
            )
            if let index = records.firstIndex(where: { $0.sessionID == sessionID }) {
                records[index] = updated
            } else {
                records.append(updated)
            }
            saveUnlocked(pruned(records, referenceDate: timestamp))
            return updated
        }
    }

    func remove(sessionID: UUID) {
        lock.withAgentContextLock {
            saveUnlocked(loadUnlocked().filter { $0.sessionID != sessionID })
        }
    }

    func clear() {
        lock.withAgentContextLock { defaults.removeObject(forKey: storageKey) }
    }

    func prune() {
        lock.withAgentContextLock {
            saveUnlocked(pruned(loadUnlocked(), referenceDate: now()))
        }
    }

    private func loadUnlocked() -> [StoredAgentSessionContext] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        guard let envelope = try? JSONDecoder().decode(AgentSessionContextEnvelope.self, from: data),
              envelope.schemaVersion == Self.currentSchemaVersion else {
            defaults.removeObject(forKey: storageKey)
            return []
        }
        return envelope.records
    }

    private func saveUnlocked(_ records: [StoredAgentSessionContext]) {
        if records.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }
        let envelope = AgentSessionContextEnvelope(
            schemaVersion: Self.currentSchemaVersion,
            records: records
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func pruned(
        _ records: [StoredAgentSessionContext],
        referenceDate: Date
    ) -> [StoredAgentSessionContext] {
        let contextCutoff = referenceDate.addingTimeInterval(-retentionInterval)
        let staleReferenceCutoff = referenceDate.addingTimeInterval(-staleReferenceRetentionInterval)
        return records
            .filter { $0.updatedAt >= contextCutoff }
            .map { record in
                var record = record
                record.references = record.references.removingStaleReferences(olderThan: staleReferenceCutoff)
                return record
            }
    }
}

final class AgentContextPrivacyStore: @unchecked Sendable {
    static let shared = AgentContextPrivacyStore()

    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "aigtd.agent-context-privacy.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func settings() -> AgentContextPrivacySettings {
        lock.withAgentContextLock {
            guard let data = defaults.data(forKey: storageKey),
                  let settings = try? JSONDecoder().decode(AgentContextPrivacySettings.self, from: data),
                  settings.schemaVersion == AgentContextPrivacySettings.currentSchemaVersion else {
                defaults.removeObject(forKey: storageKey)
                return .standard
            }
            return AgentContextPrivacySettings(
                includesNotes: settings.includesNotes,
                includesCompletedReminders: settings.includesCompletedReminders,
                maximumReminderCount: settings.maximumReminderCount
            )
        }
    }

    func save(_ settings: AgentContextPrivacySettings) {
        lock.withAgentContextLock {
            let normalized = AgentContextPrivacySettings(
                includesNotes: settings.includesNotes,
                includesCompletedReminders: settings.includesCompletedReminders,
                maximumReminderCount: settings.maximumReminderCount
            )
            guard let data = try? JSONEncoder().encode(normalized) else { return }
            defaults.set(data, forKey: storageKey)
        }
    }

    func reset() {
        lock.withAgentContextLock { defaults.removeObject(forKey: storageKey) }
    }
}

private struct AgentUserMemoryEnvelope: Codable {
    let schemaVersion: Int
    var items: [UserMemoryItem]
}

final class AgentUserMemoryStore: @unchecked Sendable {
    static let shared = AgentUserMemoryStore()
    static let currentSchemaVersion = 1

    private let defaults: UserDefaults
    private let storageKey: String
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "aigtd.agent-user-memory.v1",
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.now = now
    }

    func items() -> [UserMemoryItem] {
        lock.withAgentContextLock { loadUnlocked().sorted { $0.updatedAt > $1.updatedAt } }
    }

    @discardableResult
    func upsert(
        category: UserMemoryCategory,
        value: String,
        sourceMessageID: UUID?
    ) -> UserMemoryItem {
        lock.withAgentContextLock {
            var items = loadUnlocked()
            let timestamp = now()
            let cleaned = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
            let item: UserMemoryItem
            if let index = items.firstIndex(where: { $0.category == category }) {
                items[index].value = cleaned
                items[index].updatedAt = timestamp
                item = items[index]
            } else {
                item = UserMemoryItem(
                    id: UUID(),
                    category: category,
                    value: cleaned,
                    sourceMessageID: sourceMessageID,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
                items.append(item)
            }
            saveUnlocked(items)
            return item
        }
    }

    func remove(id: UUID) {
        lock.withAgentContextLock { saveUnlocked(loadUnlocked().filter { $0.id != id }) }
    }

    func clear() {
        lock.withAgentContextLock { defaults.removeObject(forKey: storageKey) }
    }

    private func loadUnlocked() -> [UserMemoryItem] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        guard let envelope = try? JSONDecoder().decode(AgentUserMemoryEnvelope.self, from: data),
              envelope.schemaVersion == Self.currentSchemaVersion else {
            defaults.removeObject(forKey: storageKey)
            return []
        }
        return envelope.items
    }

    private func saveUnlocked(_ items: [UserMemoryItem]) {
        guard items.isEmpty == false else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        let envelope = AgentUserMemoryEnvelope(schemaVersion: Self.currentSchemaVersion, items: items)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

private extension NSLock {
    func withAgentContextLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
