import CryptoKit
import Foundation

enum AgentTraceStage: String, Codable, CaseIterable, Sendable {
    case inputReceived = "input_received"
    case localPreviewCompleted = "local_preview_completed"
    case remoteRequestStarted = "remote_request_started"
    case remoteResponseReceived = "remote_response_received"
    case structuredParseCompleted = "structured_parse_completed"
    case fallbackResolutionCompleted = "fallback_resolution_completed"
    case actionExecutionStarted = "action_execution_started"
    case actionExecutionCompleted = "action_execution_completed"
    case remindersRefreshCompleted = "reminders_refresh_completed"
    case replyFinalized = "reply_finalized"
}

enum AgentTraceStageStatus: String, Codable, Sendable {
    case success
    case failure
    case skipped
}

struct AgentTraceContentSummary: Codable, Equatable, Sendable {
    let length: Int
    let sha256: String
    let structure: [String]
    let sanitizedPreview: String?
}

struct AgentTraceStageRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let stage: AgentTraceStage
    let status: AgentTraceStageStatus
    let durationMilliseconds: Int?
    let actionType: String?
    let content: AgentTraceContentSummary?
    let errorCategory: String?
    let userVisibleErrorSummary: AgentTraceContentSummary?
}

struct AgentTrace: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var stages: [AgentTraceStageRecord]
}

struct AgentTraceRetentionPolicy: Sendable {
    let maximumTraceCount: Int
    let maximumAge: TimeInterval

    static let standard = AgentTraceRetentionPolicy(
        maximumTraceCount: 20,
        maximumAge: 7 * 24 * 60 * 60
    )
}

/// Produces non-reversible metadata by default and filters credentials even when previews are enabled.
enum AgentDiagnosticRedactor {
    static func summarize(
        _ text: String,
        structure: [String] = [],
        includesSanitizedPreview: Bool,
        knownSecrets: [String] = []
    ) -> AgentTraceContentSummary {
        let sanitized = sanitize(text, knownSecrets: knownSecrets)
        return AgentTraceContentSummary(
            length: text.utf8.count,
            sha256: sha256(text),
            structure: Array(Set(structure)).sorted(),
            sanitizedPreview: includesSanitizedPreview ? String(sanitized.prefix(4_000)) : nil
        )
    }

    static func sanitize(_ text: String, knownSecrets: [String] = []) -> String {
        var result = text
        for secret in knownSecrets where secret.isEmpty == false {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED]", options: [.caseInsensitive])
        }

        let replacements = [
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer [REDACTED]"),
            (#"(?i)(\"?(?:authorization|api[_-]?key|access[_-]?key|secret|token)\"?\s*[:=]\s*\"?)[^\"\s,;}]+"#, "$1[REDACTED]"),
            (#"\bsk-[A-Za-z0-9_-]{8,}\b"#, "[REDACTED]"),
            (#"\bAKLT[A-Za-z0-9_-]{8,}\b"#, "[REDACTED]")
        ]
        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

final class AgentTraceService: @unchecked Sendable {
    static let shared = AgentTraceService()

    private let defaults: UserDefaults
    private let storageKey: String
    private let fullDebugKey: String
    private let retentionPolicy: AgentTraceRetentionPolicy
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "aigtd.agent-traces.v1",
        fullDebugKey: String = "aigtd.agent-traces.full-debug-enabled",
        retentionPolicy: AgentTraceRetentionPolicy = .standard,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.fullDebugKey = fullDebugKey
        self.retentionPolicy = retentionPolicy
        self.now = now
        prune()
    }

    var isFullDebugEnabled: Bool {
        get { defaults.bool(forKey: fullDebugKey) }
        set {
            defaults.set(newValue, forKey: fullDebugKey)
            if newValue == false {
                removeStoredPreviews()
            }
        }
    }

    @discardableResult
    func beginTrace(traceID: UUID = UUID()) -> UUID {
        lock.withTraceLock {
            var traces = loadUnlocked()
            let timestamp = now()
            if traces.contains(where: { $0.id == traceID }) == false {
                traces.append(AgentTrace(id: traceID, createdAt: timestamp, updatedAt: timestamp, stages: []))
            }
            saveUnlocked(pruned(traces, referenceDate: timestamp))
        }
        return traceID
    }

    func record(
        traceID: UUID,
        stage: AgentTraceStage,
        status: AgentTraceStageStatus,
        durationMilliseconds: Int? = nil,
        actionType: String? = nil,
        summaryText: String? = nil,
        structure: [String] = [],
        errorCategory: String? = nil,
        userVisibleError: String? = nil,
        knownSecrets: [String] = []
    ) {
        lock.withTraceLock {
            var traces = loadUnlocked()
            let timestamp = now()
            let index: Int
            if let existing = traces.firstIndex(where: { $0.id == traceID }) {
                index = existing
            } else {
                traces.append(AgentTrace(id: traceID, createdAt: timestamp, updatedAt: timestamp, stages: []))
                index = traces.index(before: traces.endIndex)
            }

            let includePreview = defaults.bool(forKey: fullDebugKey)
            traces[index].stages.append(
                AgentTraceStageRecord(
                    id: UUID(),
                    timestamp: timestamp,
                    stage: stage,
                    status: status,
                    durationMilliseconds: durationMilliseconds,
                    actionType: actionType,
                    content: summaryText.map {
                        AgentDiagnosticRedactor.summarize(
                            $0,
                            structure: structure,
                            includesSanitizedPreview: includePreview,
                            knownSecrets: knownSecrets
                        )
                    },
                    errorCategory: errorCategory,
                    userVisibleErrorSummary: userVisibleError.map {
                        AgentDiagnosticRedactor.summarize(
                            $0,
                            includesSanitizedPreview: includePreview,
                            knownSecrets: knownSecrets
                        )
                    }
                )
            )
            traces[index].updatedAt = timestamp
            saveUnlocked(pruned(traces, referenceDate: timestamp))
        }
    }

    func traces() -> [AgentTrace] {
        lock.withTraceLock {
            let cleaned = pruned(loadUnlocked(), referenceDate: now())
            saveUnlocked(cleaned)
            return cleaned.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    func clear() {
        lock.withTraceLock { defaults.removeObject(forKey: storageKey) }
    }

    func prune() {
        lock.withTraceLock {
            saveUnlocked(pruned(loadUnlocked(), referenceDate: now()))
        }
    }

    private func removeStoredPreviews() {
        lock.withTraceLock {
            let traces = loadUnlocked().map { trace in
                AgentTrace(
                    id: trace.id,
                    createdAt: trace.createdAt,
                    updatedAt: trace.updatedAt,
                    stages: trace.stages.map { stage in
                        AgentTraceStageRecord(
                            id: stage.id,
                            timestamp: stage.timestamp,
                            stage: stage.stage,
                            status: stage.status,
                            durationMilliseconds: stage.durationMilliseconds,
                            actionType: stage.actionType,
                            content: stage.content.map {
                                AgentTraceContentSummary(length: $0.length, sha256: $0.sha256, structure: $0.structure, sanitizedPreview: nil)
                            },
                            errorCategory: stage.errorCategory,
                            userVisibleErrorSummary: stage.userVisibleErrorSummary.map {
                                AgentTraceContentSummary(length: $0.length, sha256: $0.sha256, structure: $0.structure, sanitizedPreview: nil)
                            }
                        )
                    }
                )
            }
            saveUnlocked(traces)
        }
    }

    private func loadUnlocked() -> [AgentTrace] {
        guard let data = defaults.data(forKey: storageKey),
              let traces = try? JSONDecoder().decode([AgentTrace].self, from: data) else {
            return []
        }
        return traces
    }

    private func saveUnlocked(_ traces: [AgentTrace]) {
        guard let data = try? JSONEncoder().encode(traces) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func pruned(_ traces: [AgentTrace], referenceDate: Date) -> [AgentTrace] {
        let cutoff = referenceDate.addingTimeInterval(-retentionPolicy.maximumAge)
        return traces
            .filter { $0.updatedAt >= cutoff }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(retentionPolicy.maximumTraceCount)
            .map { $0 }
    }
}

private extension NSLock {
    func withTraceLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
