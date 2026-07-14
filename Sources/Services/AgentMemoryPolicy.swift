import Foundation

struct AgentMemoryCandidate: Equatable, Sendable {
    let category: UserMemoryCategory
    let value: String
    let readableDescription: String
    let sourceMessageID: UUID?
}

enum AgentMemoryRejectionReason: String, Equatable, Sendable {
    case sensitiveContact = "联系方式不允许进入长期记忆"
    case sensitiveAddress = "地址信息不允许进入长期记忆"
    case sensitiveHealth = "健康信息不允许进入长期记忆"
    case sensitiveFinancial = "财务信息不允许进入长期记忆"
    case credential = "凭证或系统诊断信息不允许进入长期记忆"
    case oneTimeTask = "单次任务不属于长期记忆"
    case ordinaryEmotion = "普通情绪不属于长期记忆"
    case outsideWhitelist = "内容不属于长期记忆白名单"
    case emptyValue = "没有可保存的长期规则"
}

enum AgentMemoryPolicyDecision: Equatable, Sendable {
    case candidate(AgentMemoryCandidate)
    case rejected(AgentMemoryRejectionReason)
    case notLongTerm
}

struct AgentMemoryPolicy: Sendable {
    func validationErrorForEditedValue(_ value: String) -> AgentMemoryRejectionReason? {
        let normalized = normalize(value)
        if normalized.isEmpty { return .emptyValue }
        if matchesAny(normalized, sensitiveContactSignals) { return .sensitiveContact }
        if matchesAny(normalized, sensitiveAddressSignals) { return .sensitiveAddress }
        if matchesAny(normalized, sensitiveHealthSignals) { return .sensitiveHealth }
        if matchesAny(normalized, sensitiveFinancialSignals) { return .sensitiveFinancial }
        if matchesAny(normalized, credentialSignals) { return .credential }
        return nil
    }

    func evaluate(message: String, sourceMessageID: UUID? = nil) -> AgentMemoryPolicyDecision {
        let normalized = normalize(message)
        guard normalized.isEmpty == false else { return .notLongTerm }

        if matchesAny(normalized, sensitiveContactSignals) { return .rejected(.sensitiveContact) }
        if matchesAny(normalized, sensitiveAddressSignals) { return .rejected(.sensitiveAddress) }
        if matchesAny(normalized, sensitiveHealthSignals) { return .rejected(.sensitiveHealth) }
        if matchesAny(normalized, sensitiveFinancialSignals) { return .rejected(.sensitiveFinancial) }
        if matchesAny(normalized, credentialSignals) { return .rejected(.credential) }
        guard hasExplicitLongTermMeaning(normalized) else { return .notLongTerm }
        if matchesAny(normalized, ordinaryEmotionSignals) { return .rejected(.ordinaryEmotion) }
        if isOneTimeTask(normalized) { return .rejected(.oneTimeTask) }
        guard let category = category(for: normalized) else { return .rejected(.outsideWhitelist) }

        let value = candidateValue(from: normalized)
        guard value.isEmpty == false else { return .rejected(.emptyValue) }
        return .candidate(
            AgentMemoryCandidate(
                category: category,
                value: value,
                readableDescription: "\(readableName(for: category))：\(value)",
                sourceMessageID: sourceMessageID
            )
        )
    }

    private func hasExplicitLongTermMeaning(_ text: String) -> Bool {
        matchesAny(text, [
            "以后", "今后", "从现在起", "默认", "总是", "一直", "每次", "一律", "记住", "长期",
            "from now on", "by default", "always", "every time", "remember"
        ])
    }

    private func category(for text: String) -> UserMemoryCategory? {
        if matchesAny(text, ["叫我", "称呼我", "我的名字", "call me", "my name"]) { return .preferredName }
        if matchesAny(text, ["时区", "time zone", "timezone"]) { return .timeZone }
        if matchesAny(text, ["默认清单", "默认列表", "default list"]) { return .defaultList }
        if matchesAny(text, ["默认任务时间", "默认提醒时间", "默认时间", "default task time", "default reminder time"])
            || (matchesAny(text, ["默认", "by default"])
                && matchesAny(text, ["点", "上午", "下午", "早上", "晚上", "am", "pm"])) {
            return .defaultTaskTime
        }
        if matchesAny(text, ["工作日", "工作时间", "工作时段", "上班时间", "workday", "weekdays", "work hours", "working hours"]) {
            return .workingSchedule
        }
        if matchesAny(text, ["任务", "提醒", "事项", "清单", "完成", "删除", "改期", "移动", "task", "reminder", "todo"]) {
            return .transactionRule
        }
        return nil
    }

    private func candidateValue(from text: String) -> String {
        var value = text
        let removablePrefixes = [
            "请记住", "记住", "以后", "今后", "从现在起", "长期", "please remember", "remember", "from now on"
        ]
        for prefix in removablePrefixes where value.lowercased().hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            break
        }
        return value
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,：:。.!！")))
            .prefix(240)
            .description
    }

    private func isOneTimeTask(_ text: String) -> Bool {
        let hasSingleOccurrence = matchesAny(text, [
            "今天", "明天", "后天", "这次", "本次", "一次", "稍后", "今晚", "下周", "today", "tomorrow", "tonight", "this time", "once"
        ])
        let hasTaskAction = matchesAny(text, ["提醒", "创建", "加一个", "安排", "任务", "remind", "create", "schedule", "task"])
        return hasSingleOccurrence && hasTaskAction
    }

    private func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchesAny(_ text: String, _ signals: [String]) -> Bool {
        let lowered = text.lowercased()
        return signals.contains { lowered.contains($0) }
    }

    private func readableName(for category: UserMemoryCategory) -> String {
        switch category {
        case .preferredName: "用户称呼"
        case .timeZone: "默认时区"
        case .defaultTaskTime: "默认任务时间"
        case .defaultList: "默认清单"
        case .workingSchedule: "工作时间偏好"
        case .transactionRule: "事务规则"
        }
    }

    private var sensitiveContactSignals: [String] {
        ["手机号", "电话号码", "联系电话", "邮箱", "电子邮件", "微信号", "qq号", "phone number", "email address", "wechat"]
    }

    private var sensitiveAddressSignals: [String] {
        ["地址", "住址", "门牌号", "邮政编码", "address", "postal code"]
    }

    private var sensitiveHealthSignals: [String] {
        ["病史", "疾病", "生病", "糖尿病", "高血压", "抑郁", "诊断", "用药", "药物", "过敏", "血压", "血糖", "医院", "health", "diagnosis", "medication", "allergy"]
    }

    private var sensitiveFinancialSignals: [String] {
        ["银行卡", "银行账户", "卡号", "工资", "收入", "余额", "资产", "债务", "负债", "投资", "财务", "bank account", "credit card", "salary", "income", "financial"]
    }

    private var credentialSignals: [String] {
        ["api key", "apikey", "authorization", "bearer ", "password", "token", "secret", "sk-", "密码", "密钥", "凭证", "诊断日志"]
    }

    private var ordinaryEmotionSignals: [String] {
        ["我很开心", "我好开心", "我很难过", "我好难过", "心情", "焦虑", "生气", "happy", "sad", "angry", "anxious", "mood"]
    }
}
