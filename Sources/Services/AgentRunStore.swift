import Foundation

enum AgentRunPayloadValueKind: String, Codable, Hashable, Sendable {
    case string
    case integer
    case number
    case bool
    case object
    case array
    case null
}

struct AgentRunPayloadField: Codable, Hashable, Sendable {
    let path: String
    let kind: AgentRunPayloadValueKind
}

/// A non-reversible representation of a payload. Raw argument and result values are never stored.
struct AgentRunPayloadSummary: Codable, Equatable, Sendable {
    let sha256: String
    let fields: [AgentRunPayloadField]

    init(arguments: AgentToolArguments) {
        self = Self.summarize(arguments.values)
    }

    private static func summarize(_ values: [String: AgentJSONValue]) -> Self {
        let canonical = canonicalObject(values)
        return AgentRunPayloadSummary(
            sha256: AgentRunSHA256.hexDigest(Data(canonical.utf8)),
            fields: fieldStructure(values)
        )
    }

    private init(sha256: String, fields: [AgentRunPayloadField]) {
        self.sha256 = sha256
        self.fields = fields
    }

    private static func fieldStructure(_ values: [String: AgentJSONValue]) -> [AgentRunPayloadField] {
        var fields: Set<AgentRunPayloadField> = []
        for key in values.keys.sorted() {
            appendStructure(for: values[key]!, path: key, to: &fields)
        }
        return fields.sorted {
            $0.path == $1.path ? $0.kind.rawValue < $1.kind.rawValue : $0.path < $1.path
        }
    }

    private static func appendStructure(
        for value: AgentJSONValue,
        path: String,
        to fields: inout Set<AgentRunPayloadField>
    ) {
        let kind = kind(of: value)
        fields.insert(AgentRunPayloadField(path: path, kind: kind))

        switch value {
        case let .object(object):
            for key in object.keys.sorted() {
                appendStructure(for: object[key]!, path: "\(path).\(key)", to: &fields)
            }
        case let .array(array):
            for element in array {
                appendStructure(for: element, path: "\(path)[]", to: &fields)
            }
        default:
            break
        }
    }

    private static func kind(of value: AgentJSONValue) -> AgentRunPayloadValueKind {
        switch value {
        case .string: .string
        case .integer: .integer
        case .number: .number
        case .bool: .bool
        case .object: .object
        case .array: .array
        case .null: .null
        }
    }

    private static func canonicalObject(_ object: [String: AgentJSONValue]) -> String {
        let contents = object.keys.sorted().map { key in
            "\(framed(key))\(canonical(object[key]!))"
        }.joined(separator: ",")
        return "{\(contents)}"
    }

    private static func canonical(_ value: AgentJSONValue) -> String {
        switch value {
        case let .string(value):
            return "s\(framed(value))"
        case let .integer(value):
            return "i\(value)"
        case let .number(value):
            return "d\(value.bitPattern)"
        case let .bool(value):
            return value ? "b1" : "b0"
        case let .object(value):
            return "o\(canonicalObject(value))"
        case let .array(value):
            return "a[\(value.map(canonical).joined(separator: ","))]"
        case .null:
            return "n"
        }
    }

    private static func framed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}

struct AgentModelTurnRecord: Codable, Sendable {
    let turn: Int
    let phase: AgentModelDecisionPhase?
    let startedAt: Date
    let endedAt: Date?
    let errorCategory: AgentToolErrorCategory?

    init(
        turn: Int,
        phase: AgentModelDecisionPhase? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        errorCategory: AgentToolErrorCategory? = nil
    ) {
        self.turn = turn
        self.phase = phase
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.errorCategory = errorCategory
    }

    private enum CodingKeys: String, CodingKey {
        case turn
        case phase
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case errorCategory = "error_category"
    }
}

struct AgentToolInvocation: Codable, Identifiable, Sendable {
    let id: UUID
    let runID: UUID
    let callID: String
    let toolName: AgentToolName
    let riskLevel: AgentToolRiskLevel
    let arguments: AgentRunPayloadSummary
    let status: AgentToolExecutionStatus
    let result: AgentRunPayloadSummary?
    let errorCategory: AgentToolErrorCategory?
    let startedAt: Date
    let endedAt: Date?
    let idempotencyKey: String

    init(
        id: UUID = UUID(),
        runID: UUID,
        callID: String,
        toolName: AgentToolName,
        riskLevel: AgentToolRiskLevel,
        arguments: AgentRunPayloadSummary,
        status: AgentToolExecutionStatus,
        result: AgentRunPayloadSummary? = nil,
        errorCategory: AgentToolErrorCategory? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        idempotencyKey: String
    ) {
        self.id = id
        self.runID = runID
        self.callID = callID
        self.toolName = toolName
        self.riskLevel = riskLevel
        self.arguments = arguments
        self.status = status
        self.result = result
        self.errorCategory = errorCategory
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.idempotencyKey = idempotencyKey
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case runID = "run_id"
        case callID = "call_id"
        case toolName = "tool_name"
        case riskLevel = "risk_level"
        case arguments
        case status
        case result
        case errorCategory = "error_category"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case idempotencyKey = "idempotency_key"
    }
}

struct AgentRunLog: Codable, Identifiable, Sendable {
    var id: UUID { runID }

    let runID: UUID
    var status: AgentRunStatus
    var modelTurns: [AgentModelTurnRecord]
    var toolInvocations: [AgentToolInvocation]
    let startedAt: Date
    var endedAt: Date?
    var errorCategory: AgentToolErrorCategory?

    init(
        runID: UUID,
        status: AgentRunStatus,
        modelTurns: [AgentModelTurnRecord] = [],
        toolInvocations: [AgentToolInvocation] = [],
        startedAt: Date,
        endedAt: Date? = nil,
        errorCategory: AgentToolErrorCategory? = nil
    ) {
        self.runID = runID
        self.status = status
        self.modelTurns = modelTurns
        self.toolInvocations = toolInvocations
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.errorCategory = errorCategory
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case status
        case modelTurns = "model_turns"
        case toolInvocations = "tool_invocations"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case errorCategory = "error_category"
    }
}

private struct AgentRunStoreEnvelope: Codable {
    let schemaVersion: Int
    var runs: [AgentRunLog]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runs
    }
}

final class AgentRunStore: @unchecked Sendable {
    static let shared = AgentRunStore()
    static let currentSchemaVersion = 1
    static let defaultStorageKey = "aigtd.agent-runs.v1"

    private let defaults: UserDefaults
    private let storageKey: String
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = AgentRunStore.defaultStorageKey,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.now = now
    }

    @discardableResult
    func beginRun(
        runID: UUID = UUID(),
        status: AgentRunStatus = .preparingContext,
        startedAt: Date? = nil
    ) -> AgentRunLog {
        withLock {
            var runs = loadUnlocked()
            if let existing = runs.first(where: { $0.runID == runID }) {
                return existing
            }
            let run = AgentRunLog(
                runID: runID,
                status: status,
                startedAt: startedAt ?? now()
            )
            runs.append(run)
            saveUnlocked(runs)
            return run
        }
    }

    @discardableResult
    func updateStatus(
        runID: UUID,
        status: AgentRunStatus,
        endedAt: Date? = nil,
        errorCategory: AgentToolErrorCategory? = nil
    ) -> AgentRunLog? {
        withLock {
            var runs = loadUnlocked()
            guard let index = runs.firstIndex(where: { $0.runID == runID }) else { return nil }
            runs[index].status = status
            runs[index].endedAt = endedAt ?? runs[index].endedAt
            runs[index].errorCategory = errorCategory ?? runs[index].errorCategory
            let run = runs[index]
            saveUnlocked(runs)
            return run
        }
    }

    @discardableResult
    func recordModelTurn(
        runID: UUID,
        turn: Int,
        phase: AgentModelDecisionPhase? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        errorCategory: AgentToolErrorCategory? = nil
    ) -> AgentModelTurnRecord? {
        withLock {
            var runs = loadUnlocked()
            guard let runIndex = runs.firstIndex(where: { $0.runID == runID }) else { return nil }
            let timestamp = startedAt ?? now()
            let record = AgentModelTurnRecord(
                turn: turn,
                phase: phase,
                startedAt: timestamp,
                endedAt: endedAt,
                errorCategory: errorCategory
            )
            if let turnIndex = runs[runIndex].modelTurns.firstIndex(where: { $0.turn == turn }) {
                runs[runIndex].modelTurns[turnIndex] = record
            } else {
                runs[runIndex].modelTurns.append(record)
                runs[runIndex].modelTurns.sort { $0.turn < $1.turn }
            }
            saveUnlocked(runs)
            return record
        }
    }

    @discardableResult
    func recordToolInvocation(
        runID: UUID,
        call: AgentToolCall,
        riskLevel: AgentToolRiskLevel,
        status: AgentToolExecutionStatus,
        result: AgentToolArguments? = nil,
        errorCategory: AgentToolErrorCategory? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        idempotencyKey: String? = nil
    ) -> AgentToolInvocation? {
        withLock {
            var runs = loadUnlocked()
            guard let runIndex = runs.firstIndex(where: { $0.runID == runID }) else { return nil }
            let existingIndex = runs[runIndex].toolInvocations.firstIndex { $0.callID == call.callID }
            let existing = existingIndex.map { runs[runIndex].toolInvocations[$0] }
            let invocation = AgentToolInvocation(
                id: existing?.id ?? UUID(),
                runID: runID,
                callID: call.callID,
                toolName: call.tool,
                riskLevel: riskLevel,
                arguments: AgentRunPayloadSummary(arguments: call.arguments),
                status: status,
                result: result.map(AgentRunPayloadSummary.init(arguments:)),
                errorCategory: errorCategory,
                startedAt: startedAt ?? existing?.startedAt ?? now(),
                endedAt: endedAt,
                idempotencyKey: idempotencyKey ?? existing?.idempotencyKey ?? "\(runID.uuidString):\(call.callID)"
            )
            if let existingIndex {
                runs[runIndex].toolInvocations[existingIndex] = invocation
            } else {
                runs[runIndex].toolInvocations.append(invocation)
            }
            saveUnlocked(runs)
            return invocation
        }
    }

    @discardableResult
    func finishRun(
        runID: UUID,
        status: AgentRunStatus,
        errorCategory: AgentToolErrorCategory? = nil,
        endedAt: Date? = nil
    ) -> AgentRunLog? {
        updateStatus(
            runID: runID,
            status: status,
            endedAt: endedAt ?? now(),
            errorCategory: errorCategory
        )
    }

    func run(for runID: UUID) -> AgentRunLog? {
        withLock { loadUnlocked().first { $0.runID == runID } }
    }

    func runs() -> [AgentRunLog] {
        withLock { loadUnlocked().sorted { $0.startedAt > $1.startedAt } }
    }

    func remove(runID: UUID) {
        withLock { saveUnlocked(loadUnlocked().filter { $0.runID != runID }) }
    }

    func clear() {
        withLock { defaults.removeObject(forKey: storageKey) }
    }

    private func loadUnlocked() -> [AgentRunLog] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        guard let envelope = try? JSONDecoder().decode(AgentRunStoreEnvelope.self, from: data),
              envelope.schemaVersion == Self.currentSchemaVersion else {
            defaults.removeObject(forKey: storageKey)
            return []
        }
        return envelope.runs
    }

    private func saveUnlocked(_ runs: [AgentRunLog]) {
        guard runs.isEmpty == false else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        let envelope = AgentRunStoreEnvelope(schemaVersion: Self.currentSchemaVersion, runs: runs)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private enum AgentRunSHA256 {
    private static let initialHash: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]

    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func hexDigest(_ data: Data) -> String {
        var bytes = Array(data)
        let bitCount = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        bytes.append(contentsOf: withUnsafeBytes(of: bitCount.bigEndian, Array.init))

        var hash = initialHash
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let start = offset + index * 4
                words[index] = UInt32(bytes[start]) << 24
                    | UInt32(bytes[start + 1]) << 16
                    | UInt32(bytes[start + 2]) << 8
                    | UInt32(bytes[start + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(words[index - 15], by: 7)
                    ^ rotateRight(words[index - 15], by: 18)
                    ^ (words[index - 15] >> 3)
                let s1 = rotateRight(words[index - 2], by: 17)
                    ^ rotateRight(words[index - 2], by: 19)
                    ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }

            var a = hash[0]
            var b = hash[1]
            var c = hash[2]
            var d = hash[3]
            var e = hash[4]
            var f = hash[5]
            var g = hash[6]
            var h = hash[7]
            for index in 0..<64 {
                let sum1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
                let choice = (e & f) ^ ((~e) & g)
                let temporary1 = h &+ sum1 &+ choice &+ constants[index] &+ words[index]
                let sum0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temporary2 = sum0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temporary1
                d = c
                c = b
                b = a
                a = temporary1 &+ temporary2
            }
            hash[0] &+= a
            hash[1] &+= b
            hash[2] &+= c
            hash[3] &+= d
            hash[4] &+= e
            hash[5] &+= f
            hash[6] &+= g
            hash[7] &+= h
        }
        return hash.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotateRight(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
