import Foundation

enum AgentSchedulePlanItemStatus: String, Codable, Equatable, Sendable {
    case pending
    case applied
    case unchanged
    case failed
    case skipped
    case cancelled
}

struct AgentSchedulePlanItem: Codable, Equatable, Sendable {
    let id: String
    let reminderID: String
    let title: String?
    let originalDueDate: Date?
    let targetDueDate: Date
    let includesTime: Bool
    let dependencyIDs: [String]
    var status: AgentSchedulePlanItemStatus
    var errorCategory: AgentToolErrorCategory?
    var userVisibleError: String?

    init(
        id: String,
        reminderID: String,
        title: String? = nil,
        originalDueDate: Date?,
        targetDueDate: Date,
        includesTime: Bool,
        dependencyIDs: [String] = [],
        status: AgentSchedulePlanItemStatus = .pending,
        errorCategory: AgentToolErrorCategory? = nil,
        userVisibleError: String? = nil
    ) {
        self.id = id
        self.reminderID = reminderID
        self.title = title
        self.originalDueDate = originalDueDate
        self.targetDueDate = targetDueDate
        self.includesTime = includesTime
        self.dependencyIDs = dependencyIDs
        self.status = status
        self.errorCategory = errorCategory
        self.userVisibleError = userVisibleError
    }
}

enum AgentSchedulePlanStatus: String, Codable, Equatable, Sendable {
    case awaitingConfirmation = "awaiting_confirmation"
    case executing
    case succeeded
    case partial
    case failed
    case cancelled
    case expired
}

struct AgentSchedulePlan: Codable, Equatable, Sendable {
    let id: UUID
    let runID: UUID
    let sessionID: UUID?
    let createdAt: Date
    let expiresAt: Date
    var status: AgentSchedulePlanStatus
    var items: [AgentSchedulePlanItem]

    var successfulCount: Int {
        items.lazy.filter { $0.status == .applied || $0.status == .unchanged }.count
    }

    var failedCount: Int {
        items.lazy.filter { $0.status == .failed || $0.status == .skipped }.count
    }
}

final class AgentSchedulePlanStore: @unchecked Sendable {
    static let shared = AgentSchedulePlanStore()
    static let defaultRetentionInterval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let storageKey: String
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var plans: [UUID: AgentSchedulePlan]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "aigtd.agent.schedule.plans.v1",
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.now = now
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([UUID: AgentSchedulePlan].self, from: data) {
            plans = decoded
        } else {
            plans = [:]
            if defaults.object(forKey: storageKey) != nil {
                defaults.removeObject(forKey: storageKey)
            }
        }
        removeExpiredPlans()
    }

    @discardableResult
    func create(
        runID: UUID,
        sessionID: UUID? = nil,
        items: [AgentSchedulePlanItem]
    ) throws -> AgentSchedulePlan {
        guard items.isEmpty == false else {
            throw AgentToolError(category: .invalidArguments, userVisibleMessage: "排期方案不能为空。")
        }
        let itemIDs = items.map(\.id)
        guard Set(itemIDs).count == itemIDs.count,
              items.allSatisfy({ $0.id.isEmpty == false && $0.reminderID.isEmpty == false }) else {
            throw AgentToolError(category: .invalidArguments, userVisibleMessage: "排期方案包含无效或重复项目。")
        }
        let knownIDs = Set(itemIDs)
        guard items.allSatisfy({ Set($0.dependencyIDs).isSubset(of: knownIDs) && !$0.dependencyIDs.contains($0.id) }) else {
            throw AgentToolError(category: .invalidArguments, userVisibleMessage: "排期方案包含无效依赖。")
        }

        return lock.withLock {
            purgeExpiredLocked()
            let timestamp = now()
            let plan = AgentSchedulePlan(
                id: UUID(),
                runID: runID,
                sessionID: sessionID,
                createdAt: timestamp,
                expiresAt: timestamp.addingTimeInterval(Self.defaultRetentionInterval),
                status: .awaitingConfirmation,
                items: items
            )
            plans[plan.id] = plan
            persistLocked()
            return plan
        }
    }

    func load(id: UUID, runID: UUID? = nil, sessionID: UUID? = nil) throws -> AgentSchedulePlan {
        try lock.withLock {
            guard let plan = plans[id] else {
                throw AgentToolError(category: .notFound, userVisibleMessage: "没有找到排期方案。")
            }
            guard plan.expiresAt > now() else {
                plans.removeValue(forKey: id)
                persistLocked()
                throw AgentToolError(category: .planExpired, userVisibleMessage: "排期方案已过期，请重新生成。")
            }
            if let runID, plan.runID != runID {
                throw AgentToolError(category: .staleReference, userVisibleMessage: "该方案不属于当前操作。")
            }
            if let sessionID, plan.sessionID != sessionID {
                throw AgentToolError(category: .staleReference, userVisibleMessage: "该方案不属于当前会话。")
            }
            return plan
        }
    }

    @discardableResult
    func markExecuting(id: UUID) throws -> AgentSchedulePlan {
        try update(id: id) { plan in
            guard plan.status == .awaitingConfirmation || plan.status == .partial || plan.status == .failed else {
                if plan.status == .succeeded { return }
                throw AgentToolError(category: .invalidArguments, userVisibleMessage: "该方案当前不可执行。")
            }
            plan.status = .executing
        }
    }

    @discardableResult
    func record(
        planID: UUID,
        itemID: String,
        status: AgentSchedulePlanItemStatus,
        error: AgentToolError? = nil
    ) throws -> AgentSchedulePlan {
        try update(id: planID) { plan in
            guard let index = plan.items.firstIndex(where: { $0.id == itemID }) else {
                throw AgentToolError(category: .notFound, userVisibleMessage: "方案中没有该项目。")
            }
            plan.items[index].status = status
            plan.items[index].errorCategory = error?.category
            plan.items[index].userVisibleError = error?.userVisibleMessage
            plan.status = Self.aggregateStatus(items: plan.items)
        }
    }

    @discardableResult
    func cancel(id: UUID) throws -> AgentSchedulePlan {
        try update(id: id) { plan in
            guard plan.status != .succeeded else { return }
            plan.status = .cancelled
            for index in plan.items.indices where plan.items[index].status == .pending {
                plan.items[index].status = .cancelled
            }
        }
    }

    func removeExpiredPlans() {
        lock.withLock {
            purgeExpiredLocked()
        }
    }

    static func aggregateStatus(items: [AgentSchedulePlanItem]) -> AgentSchedulePlanStatus {
        let successful = items.filter { $0.status == .applied || $0.status == .unchanged }.count
        let terminal = items.filter { $0.status != .pending }.count
        if terminal < items.count { return .executing }
        if successful == items.count { return .succeeded }
        if successful > 0 { return .partial }
        if items.allSatisfy({ $0.status == .cancelled }) { return .cancelled }
        return .failed
    }

    private func update(id: UUID, mutation: (inout AgentSchedulePlan) throws -> Void) throws -> AgentSchedulePlan {
        try lock.withLock {
            guard var plan = plans[id] else {
                throw AgentToolError(category: .notFound, userVisibleMessage: "没有找到排期方案。")
            }
            guard plan.expiresAt > now() else {
                plans.removeValue(forKey: id)
                persistLocked()
                throw AgentToolError(category: .planExpired, userVisibleMessage: "排期方案已过期，请重新生成。")
            }
            try mutation(&plan)
            plans[id] = plan
            persistLocked()
            return plan
        }
    }

    private func purgeExpiredLocked() {
        let timestamp = now()
        let retained = plans.filter { $0.value.expiresAt > timestamp }
        guard retained.count != plans.count else { return }
        plans = retained
        persistLocked()
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(plans) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
