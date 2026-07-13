import Foundation

struct RemoteResponseDebugSnapshot: Codable, Sendable {
    let createdAt: Date
    let endpoint: String
    let wireAPI: String
    let statusCode: Int?
    let bodyLength: Int
    let bodySHA256: String
    let structure: [String]
    let sanitizedBody: String?
}

/// A short-lived local diagnostic snapshot. Raw response bodies are never persisted by default.
final class RemoteResponseDebugStore: @unchecked Sendable {
    static let shared = RemoteResponseDebugStore()

    private let defaults: UserDefaults
    private let storageKey: String
    private let fullDebugKey: String
    private let maximumSnapshotCount: Int
    private let maximumAge: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "aigtd.remote-response-debug-snapshots.v2",
        fullDebugKey: String = "aigtd.agent-traces.full-debug-enabled",
        maximumSnapshotCount: Int = 20,
        maximumAge: TimeInterval = 7 * 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.fullDebugKey = fullDebugKey
        self.maximumSnapshotCount = maximumSnapshotCount
        self.maximumAge = maximumAge
        self.now = now
    }

    var isFullDebugEnabled: Bool {
        get { defaults.bool(forKey: fullDebugKey) }
        set {
            defaults.set(newValue, forKey: fullDebugKey)
            if newValue == false {
                removeStoredBodies()
            }
        }
    }

    func save(
        endpoint: String,
        wireAPI: String,
        statusCode: Int?,
        body: String,
        knownSecrets: [String] = []
    ) {
        let structure = Self.structureKeys(in: body)
        let summary = AgentDiagnosticRedactor.summarize(
            body,
            structure: structure,
            includesSanitizedPreview: isFullDebugEnabled,
            knownSecrets: knownSecrets
        )
        let sanitizedEndpoint = AgentDiagnosticRedactor.sanitize(endpoint, knownSecrets: knownSecrets)
        let snapshot = RemoteResponseDebugSnapshot(
            createdAt: now(),
            endpoint: sanitizedEndpoint,
            wireAPI: wireAPI,
            statusCode: statusCode,
            bodyLength: summary.length,
            bodySHA256: summary.sha256,
            structure: summary.structure,
            sanitizedBody: summary.sanitizedPreview
        )

        lock.withDebugLock {
            var snapshots = loadAllUnlocked()
            snapshots.append(snapshot)
            saveUnlocked(pruned(snapshots, referenceDate: now()))
            defaults.removeObject(forKey: "aigtd.remote-response-debug-snapshot")
        }
    }

    func saveRaw(
        endpoint: String,
        wireAPI: String,
        statusCode: Int?,
        data: Data,
        knownSecrets: [String] = []
    ) {
        let body: String
        if let utf8 = String(data: data, encoding: .utf8), utf8.isEmpty == false {
            body = utf8
        } else {
            body = "<binary response: \(data.count) bytes>"
        }
        save(
            endpoint: endpoint,
            wireAPI: wireAPI,
            statusCode: statusCode,
            body: body,
            knownSecrets: knownSecrets
        )
    }

    func load() -> RemoteResponseDebugSnapshot? {
        loadAll().first
    }

    func loadAll() -> [RemoteResponseDebugSnapshot] {
        lock.withDebugLock {
            let snapshots = pruned(loadAllUnlocked(), referenceDate: now())
            saveUnlocked(snapshots)
            return snapshots.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func clear() {
        lock.withDebugLock {
            defaults.removeObject(forKey: storageKey)
            defaults.removeObject(forKey: "aigtd.remote-response-debug-snapshot")
        }
    }

    private func loadAllUnlocked() -> [RemoteResponseDebugSnapshot] {
        guard let data = defaults.data(forKey: storageKey),
              let snapshots = try? JSONDecoder().decode([RemoteResponseDebugSnapshot].self, from: data) else {
            return []
        }
        return snapshots
    }

    private func saveUnlocked(_ snapshots: [RemoteResponseDebugSnapshot]) {
        guard snapshots.isEmpty == false else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func removeStoredBodies() {
        lock.withDebugLock {
            let snapshots = loadAllUnlocked().map {
                RemoteResponseDebugSnapshot(
                    createdAt: $0.createdAt,
                    endpoint: $0.endpoint,
                    wireAPI: $0.wireAPI,
                    statusCode: $0.statusCode,
                    bodyLength: $0.bodyLength,
                    bodySHA256: $0.bodySHA256,
                    structure: $0.structure,
                    sanitizedBody: nil
                )
            }
            saveUnlocked(snapshots)
        }
    }

    private func pruned(
        _ snapshots: [RemoteResponseDebugSnapshot],
        referenceDate: Date
    ) -> [RemoteResponseDebugSnapshot] {
        let cutoff = referenceDate.addingTimeInterval(-maximumAge)
        return snapshots
            .filter { $0.createdAt >= cutoff }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(maximumSnapshotCount)
            .map { $0 }
    }

    private static func structureKeys(in body: String) -> [String] {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        if let dictionary = object as? [String: Any] {
            return dictionary.keys.sorted()
        }
        if object is [Any] {
            return ["array"]
        }
        return []
    }
}

private extension NSLock {
    func withDebugLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
