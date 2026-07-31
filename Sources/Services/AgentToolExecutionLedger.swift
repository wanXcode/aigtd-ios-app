import Foundation

struct AgentToolExecutionKey: Codable, Hashable, Sendable {
    let runID: String
    let callID: String

    init(runID: String, callID: String) {
        self.runID = runID
        self.callID = callID
    }
}

enum AgentToolExecutionReplayStatus: String, Codable, Equatable, Sendable {
    case success
    case unchanged
    case alreadyApplied = "already_applied"
}

struct AgentToolExecutionResult: Codable, Equatable, Sendable {
    let status: AgentToolExecutionReplayStatus
    let resultJSON: String?

    init(status: AgentToolExecutionReplayStatus, resultJSON: String? = nil) {
        self.status = status
        self.resultJSON = resultJSON
    }
}

struct AgentToolExecutionLedgerLookup: Equatable, Sendable {
    let result: AgentToolExecutionResult
    let recordedAt: Date
    let isReplay: Bool
}

final class AgentToolExecutionLedger: @unchecked Sendable {
    static let defaultRetentionInterval: TimeInterval = 24 * 60 * 60
    static let shared = AgentToolExecutionLedger(
        defaults: .standard,
        storageKey: "aigtd.agent.tool-ledger.v1"
    )

    private struct Entry: Codable {
        let result: AgentToolExecutionResult
        let recordedAt: Date
    }

    private struct PersistedEntry: Codable {
        let key: AgentToolExecutionKey
        let entry: Entry
    }

    private let retentionInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let defaults: UserDefaults?
    private let storageKey: String?
    private let lock = NSLock()
    private var entries: [AgentToolExecutionKey: Entry]

    init(
        retentionInterval: TimeInterval = AgentToolExecutionLedger.defaultRetentionInterval,
        defaults: UserDefaults? = nil,
        storageKey: String? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        precondition(retentionInterval >= 0, "Retention interval cannot be negative")
        self.retentionInterval = retentionInterval
        self.defaults = defaults
        self.storageKey = storageKey
        self.now = now
        if let defaults, let storageKey, let data = defaults.data(forKey: storageKey),
           let persisted = try? JSONDecoder().decode([PersistedEntry].self, from: data) {
            entries = Dictionary(persisted.map { ($0.key, $0.entry) }, uniquingKeysWith: { _, latest in latest })
        } else {
            entries = [:]
            if let defaults, let storageKey, defaults.object(forKey: storageKey) != nil {
                defaults.removeObject(forKey: storageKey)
            }
        }
        prune()
    }

    func replay(runID: String, callID: String) -> AgentToolExecutionLedgerLookup? {
        withLock {
            let timestamp = now()
            pruneUnlocked(referenceDate: timestamp)
            guard let entry = entries[AgentToolExecutionKey(runID: runID, callID: callID)] else {
                return nil
            }
            return lookup(for: entry, isReplay: true)
        }
    }

    @discardableResult
    func record(
        runID: String,
        callID: String,
        result: AgentToolExecutionResult
    ) -> AgentToolExecutionLedgerLookup {
        withLock {
            let timestamp = now()
            pruneUnlocked(referenceDate: timestamp)
            let key = AgentToolExecutionKey(runID: runID, callID: callID)
            if let existing = entries[key] {
                return lookup(for: existing, isReplay: true)
            }

            let entry = Entry(result: result, recordedAt: timestamp)
            entries[key] = entry
            persistUnlocked()
            return lookup(for: entry, isReplay: false)
        }
    }

    @discardableResult
    func execute(
        runID: String,
        callID: String,
        operation: () throws -> AgentToolExecutionResult
    ) rethrows -> AgentToolExecutionLedgerLookup {
        try withLock {
            let timestamp = now()
            pruneUnlocked(referenceDate: timestamp)
            let key = AgentToolExecutionKey(runID: runID, callID: callID)
            if let existing = entries[key] {
                return lookup(for: existing, isReplay: true)
            }

            let result = try operation()
            let entry = Entry(result: result, recordedAt: now())
            entries[key] = entry
            persistUnlocked()
            return lookup(for: entry, isReplay: false)
        }
    }

    func prune() {
        withLock { pruneUnlocked(referenceDate: now()) }
    }

    var count: Int {
        withLock {
            pruneUnlocked(referenceDate: now())
            return entries.count
        }
    }

    private func pruneUnlocked(referenceDate: Date) {
        let cutoff = referenceDate.addingTimeInterval(-retentionInterval)
        let retained = entries.filter { $0.value.recordedAt >= cutoff }
        guard retained.count != entries.count else { return }
        entries = retained
        persistUnlocked()
    }

    private func persistUnlocked() {
        guard let defaults, let storageKey else { return }
        let persisted = entries.map { PersistedEntry(key: $0.key, entry: $0.value) }
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func lookup(for entry: Entry, isReplay: Bool) -> AgentToolExecutionLedgerLookup {
        AgentToolExecutionLedgerLookup(
            result: entry.result,
            recordedAt: entry.recordedAt,
            isReplay: isReplay
        )
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
