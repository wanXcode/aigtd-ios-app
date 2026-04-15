import Foundation

enum MockAgentIntent: String, Sendable {
    case createReminder = "create_reminder"
    case createList = "create_list"
    case summarizeLists = "summarize_lists"
    case captureMessage = "capture_message"
    case moveReminder = "move_reminder"
    case completeReminder = "complete_reminder"
    case deleteReminder = "delete_reminder"
    case fallback = "fallback"
}

struct MockAgentAction: Sendable {
    let intent: MockAgentIntent
    let title: String
    let entities: [String: String]
    let requiresConfirmation: Bool

    func payload() -> MockAgentActionPayload {
        MockAgentActionPayload(
            intent: intent.rawValue,
            title: title,
            entities: entities,
            requiresConfirmation: requiresConfirmation
        )
    }
}

struct MockAgentActionPayload: Codable, Sendable {
    let intent: String
    let title: String
    let entities: [String: String]
    let requiresConfirmation: Bool
}

struct MockAgentEnvelope: Codable, Sendable {
    let action: MockAgentActionPayload
    let confidence: Double
    let summary: String
    let followUpPrompt: String?
    let matchedSignals: [String]
}

struct MockAgentResult: Sendable {
    let reply: String
    let summary: String
    let actionType: String?
    let payloadJSON: String
    let confidence: Double
    let followUpPrompt: String?
}

struct MockAgentService {
    private let mappingRuleEngine = AppleRemindersMappingRuleEngine()
    private let preferredUserAddress = "哥哥"

    private let stopPrefixes = [
        "提醒我", "帮我", "记得", "记一下", "记录一下", "新增任务", "加个任务",
        "新建任务", "创建任务", "记一个任务", "记个任务", "帮我记一个任务", "帮我记个任务",
        "帮我记个待办", "帮我记一个待办", "待办", "todo", "todo:", "todo："
    ]

    private let trimTails = [
        "先放未来", "放未来", "记一下", "提醒我", "帮我", "这件事", "这个事情"
    ]

    private let noteHints = [
        "下周", "下下周", "月底", "月末", "周末", "等确认", "等回复", "后续推进",
        "已出初步方案", "需要确认", "等老板", "等对方"
    ]

    private let casualProbeHints = [
        "测试一下", "测试下", "试一下", "试试", "看看这个系统", "这个系统怎么样",
        "你在吗", "在吗", "hello", "hi", "你好", "测试系统"
    ]

    private let categoryHints: [String: [String]] = [
        "waiting_for": ["等确认", "等回复", "等待", "待确认", "待回复", "跟进", "催一下", "等对方"],
        "project": ["项目", "规划", "方案", "系统", "版本", "升级", "搭建", "建设"],
        "next_action": ["给", "整理", "发送", "沟通", "安排", "处理", "推进", "确认一下", "回信"],
        "maybe": ["以后", "先放未来", "晚点", "有空再", "再说", "也许", "可能"]
    ]

    func respond(
        to content: String,
        reminderLists: [ReminderListInfo],
        reminderItems: [ReminderItemInfo],
        agentContext: AIGTDAgentRuntimeContext? = nil
    ) -> MockAgentResult {
        let preferredUserAddress = resolvedUserAddress(from: agentContext)

        if let reminder = detectReminderCreation(from: content, reminderLists: reminderLists) {
            let action = MockAgentAction(
                intent: .createReminder,
                title: "创建任务",
                entities: reminder.entities,
                requiresConfirmation: false
            )
            return makeResult(
                reply: reminder.reply,
                summary: reminder.summary,
                action: action,
                confidence: reminder.confidence,
                followUpPrompt: reminder.followUpPrompt,
                matchedSignals: reminder.signals
            )
        }

        if isCasualProbe(content) {
            let action = MockAgentAction(
                intent: .captureMessage,
                title: "接住这句话",
                entities: [
                    "text": content
                ],
                requiresConfirmation: false
            )
            return makeResult(
                reply: "我在，\(preferredUserAddress)。你直接告诉我要记什么、改什么，或者问我今天还有什么事就行。",
                summary: "这句我先接住了，还没往提醒事项里创建内容",
                action: action,
                confidence: 0.96,
                followUpPrompt: "比如你可以直接说：明天提醒我给张闯回信。",
                matchedSignals: ["casual_probe"]
            )
        }

        if let deletion = detectDeletion(from: content) {
            let action = MockAgentAction(
                intent: .deleteReminder,
                title: "删除任务",
                entities: [
                    "target": deletion.target
                ],
                requiresConfirmation: false
            )
            return makeResult(
                reply: "我来帮你删掉这条提醒事项。",
                summary: "准备删除：\(deletion.target)",
                action: action,
                confidence: deletion.confidence,
                followUpPrompt: "如果你指的是刚才那条任务，我也可以直接按最近一条来处理。",
                matchedSignals: deletion.signals
            )
        }

        if let completion = detectCompletion(from: content) {
            let action = MockAgentAction(
                intent: .completeReminder,
                title: "标记完成",
                entities: [
                    "target": completion.target
                ],
                requiresConfirmation: false
            )
            return makeResult(
                reply: "好的，\(preferredUserAddress)。这条我帮你标记完成。",
                summary: "准备完成：\(completion.target)",
                action: action,
                confidence: completion.confidence,
                followUpPrompt: "如果你愿意，我也可以继续帮你挪清单、补备注，或者看看今天还剩什么。",
                matchedSignals: completion.signals
            )
        }

        if let movement = detectMove(from: content) {
            let action = MockAgentAction(
                intent: .moveReminder,
                title: "移动到列表",
                entities: [
                    "target": movement.target,
                    "destination_list": movement.destinationList
                ],
                requiresConfirmation: false
            )
            return makeResult(
                reply: "改好了，\(preferredUserAddress)。这条我帮你挪过去。",
                summary: "准备移动到：\(movement.destinationList)",
                action: action,
                confidence: movement.confidence,
                followUpPrompt: "如果这类事情以后都放这里，我也可以顺手帮你把清单整理一下。",
                matchedSignals: movement.signals
            )
        }

        if let listName = extractListCreationName(from: content) {
            let action = MockAgentAction(
                intent: .createList,
                title: "创建列表",
                entities: [
                    "list_name": listName
                ],
                requiresConfirmation: false
            )
            return makeResult(
                reply: "记好了，\(preferredUserAddress)。我帮你建这个清单。",
                summary: "准备创建列表：\(listName)",
                action: action,
                confidence: 0.94,
                followUpPrompt: "接下来你可以直接告诉我，哪些事情要放进这个清单。",
                matchedSignals: ["list_creation"]
            )
        }

        if let summary = detectSummaryRequest(
            from: content,
            reminderLists: reminderLists,
            reminderItems: reminderItems,
            preferredUserAddress: preferredUserAddress
        ) {
            let action = MockAgentAction(
                intent: .summarizeLists,
                title: "查看提醒事项",
                entities: summary.entities,
                requiresConfirmation: false
            )
            return makeResult(
                reply: summary.reply,
                summary: summary.summary,
                action: action,
                confidence: summary.confidence,
                followUpPrompt: summary.followUpPrompt,
                matchedSignals: summary.signals
            )
        }

        let action = MockAgentAction(
            intent: .captureMessage,
            title: "记录输入",
            entities: [
                "text": content
            ],
            requiresConfirmation: false
        )
        return makeResult(
            reply: "收到，\(preferredUserAddress)。你继续说，我来帮你收口成任务或安排。",
            summary: "先替你记下来了",
            action: action,
            confidence: 0.68,
            followUpPrompt: "你可以直接补一句时间、清单名，或者告诉我要创建、移动、完成哪条。",
            matchedSignals: ["capture"]
        )
    }

    private func resolvedUserAddress(from agentContext: AIGTDAgentRuntimeContext?) -> String {
        guard let memory = agentContext?.memory, memory.isEmpty == false else {
            return preferredUserAddress
        }

        let patterns = [
            #"称呼[：:]\s*([^\n]+)"#,
            #"用户称呼[：:]\s*([^\n]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(memory.startIndex..<memory.endIndex, in: memory)
            guard let match = regex.firstMatch(in: memory, range: nsRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: memory) else {
                continue
            }
            let value = String(memory[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: "- ").union(.whitespacesAndNewlines))
            if value.isEmpty == false {
                return value
            }
        }

        return preferredUserAddress
    }

    private func isCasualProbe(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.isEmpty == false else { return false }

        let explicitTaskSignals = [
            "任务", "待办", "提醒我", "记一下", "记一个", "记个", "创建", "新建", "帮我记"
        ]
        if matchesAny(trimmed, keywords: explicitTaskSignals) {
            return false
        }

        if matchesAny(trimmed, keywords: casualProbeHints.map { $0.lowercased() }) {
            return true
        }

        let looksLikeTask = matchesAny(trimmed, keywords: [
            "提醒我", "新建任务", "创建任务", "明天", "今天", "后天", "下周",
            "完成", "移到", "放到", "列表", "清单", "回信", "整理", "报销"
        ])
        return looksLikeTask == false && trimmed.contains("测试")
    }

    private func detectSummaryRequest(
        from text: String,
        reminderLists: [ReminderListInfo],
        reminderItems: [ReminderItemInfo],
        preferredUserAddress: String
    ) -> (
        entities: [String: String],
        reply: String,
        summary: String,
        confidence: Double,
        followUpPrompt: String?,
        signals: [String]
    )? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let openItems = reminderItems.filter { $0.isCompleted == false }
        let calendar = Calendar.current
        let summaryMode = detectSummaryMode(
            from: trimmed,
            reminderLists: reminderLists,
            openItems: openItems,
            calendar: calendar
        )
        guard let summaryMode else { return nil }

        let filteredItems = summaryMode.items
        let previewItems = filteredItems.prefix(3).map(\.title)
        let reply = makeSummaryReply(
            address: preferredUserAddress,
            mode: summaryMode,
            previewItems: previewItems,
            reminderListCount: reminderLists.count,
            openItemCount: openItems.count
        )

        return (
            entities: [
                "scope": summaryMode.scopeLabel,
                "list_count": String(reminderLists.count),
                "open_count": String(openItems.count),
                "item_count": String(filteredItems.count),
                "top_items": previewItems.joined(separator: "、"),
                "target_list": summaryMode.targetListTitle ?? ""
            ],
            reply: reply,
            summary: "我先替你看了一眼\(summaryMode.scopeLabel)的提醒事项",
            confidence: summaryMode.confidence,
            followUpPrompt: reminderLists.isEmpty ? "要不要我先帮你建一套起步分类？" : "你也可以直接说把其中一条完成、改时间，或者换到别的清单。",
            signals: ["list_summary", summaryMode.scopeLabel]
        )
    }

    func extractListCreationName(from text: String) -> String? {
        if let quoted = quotedText(in: text) {
            let lower = quoted.lowercased()
            if lower.contains("列表") || lower.contains("清单") {
                return quoted.replacingOccurrences(of: "列表", with: "").replacingOccurrences(of: "清单", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if matchesAny(text, keywords: ["建一个", "创建", "新建", "新做", "加一个"]) , text.contains("列表") || text.contains("清单") {
            return text
                .replacingOccurrences(of: "帮我", with: "")
                .replacingOccurrences(of: "创建", with: "")
                .replacingOccurrences(of: "新建", with: "")
                .replacingOccurrences(of: "建一个", with: "")
                .replacingOccurrences(of: "加一个", with: "")
                .replacingOccurrences(of: "列表", with: "")
                .replacingOccurrences(of: "清单", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private func detectReminderCreation(
        from text: String,
        reminderLists: [ReminderListInfo]
    ) -> (
        entities: [String: String],
        reply: String,
        summary: String,
        confidence: Double,
        followUpPrompt: String?,
        signals: [String]
    )? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let creationKeywords = [
            "新建任务", "创建任务", "提醒我", "记得", "待办", "todo", "待办事项",
            "记一个任务", "记个任务", "帮我记一个任务", "帮我记个任务",
            "记一个待办", "记个待办", "帮我记一个待办", "帮我记个待办"
        ]
        let hasCreationKeyword = matchesAny(trimmed.lowercased(), keywords: creationKeywords.map { $0.lowercased() })
        let hasFutureSignal = matchesAny(trimmed, keywords: ["明天", "今天", "今晚", "上午", "下午", "晚上", "后天", "下周", "周一", "周二", "周三", "周四", "周五", "周六", "周日", "周天"])

        guard hasCreationKeyword || hasFutureSignal else {
            return nil
        }

        let dueDate = detectDueDate(from: trimmed)
        let dueDateISO = dueDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        let note = extractNote(from: trimmed)
        let bucket = detectBucket(from: trimmed, dueDate: dueDate)
        let tags = detectTags(from: trimmed)
        let category = detectCategory(from: trimmed, tags: tags)
        let explicitListName = explicitlyMentionedListName(
            in: trimmed,
            reminderLists: reminderLists
        )
        let mapping = mappingRuleEngine.resolveTargetList(
            explicitListName: explicitListName,
            category: category,
            tags: tags,
            bucket: bucket,
            text: trimmed,
            note: note,
            reminderLists: reminderLists
        )
        let preferredList = mapping.targetListName
        let title = deriveReminderTitle(from: trimmed, reminderLists: reminderLists)

        guard title.isEmpty == false else {
            return nil
        }

        let entities: [String: String] = [
            "title": title,
            "due_date": dueDateISO,
            "preferred_list_name": preferredList ?? "",
            "note": note,
            "bucket": bucket,
            "category": category,
            "tags": tags.joined(separator: ","),
            "matched_rule_id": mapping.matchedRuleID ?? "",
            "source_text": trimmed
        ]

        let dueText = dueDateISO.isEmpty ? "时间还可以后面再补" : "时间我会一起带上"
        let listText = preferredList == nil ? "" : "，放进“\(preferredList!)”"
        return (
            entities: entities,
            reply: "记好了，\(preferredUserAddress)。这条我帮你建进提醒事项\(listText)。",
            summary: "准备创建任务：\(title)",
            confidence: dueDateISO.isEmpty ? 0.76 : 0.88,
            followUpPrompt: "如果你愿意，我也可以继续帮你补备注、改时间，或者换到别的清单。",
            signals: ["create_reminder", dueText]
        )
    }

    private func detectBucket(from text: String, dueDate: Date?) -> String {
        let calendar = Calendar.current
        if let dueDate {
            if calendar.isDateInToday(dueDate) { return "today" }
            if calendar.isDateInTomorrow(dueDate) { return "tomorrow" }
            return "future"
        }
        if matchesAny(text, keywords: ["今天", "今日", "今晚", "今天内", "今天处理", "今天做"]) {
            return "today"
        }
        if matchesAny(text, keywords: ["明天", "明日", "明早", "明晚", "明天下午", "明天上午"]) {
            return "tomorrow"
        }
        if matchesRegex(text, pattern: #"下周|以后|晚点|过几天|之后|有空"#) {
            return "future"
        }
        return "future"
    }

    private func detectTags(from text: String) -> [String] {
        var tags = Set<String>()
        let hashtagPattern = #"#([A-Za-z][A-Za-z0-9_-]*)"#
        if let regex = try? NSRegularExpression(pattern: hashtagPattern) {
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: nsRange) {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: text) else { continue }
                tags.insert(String(text[range]).uppercased())
            }
        }
        if matchesAny(text, keywords: ["等确认", "等回复", "等待", "待确认", "待回复"]) {
            tags.insert("WAIT")
        }
        return tags.sorted()
    }

    private func detectCategory(from text: String, tags: [String]) -> String {
        if tags.contains(where: { ["WAIT", "FOLLOWUP", "FOLLOW_UP"].contains($0.uppercased()) }) {
            return "waiting_for"
        }
        if matchesAny(text, keywords: categoryHints["waiting_for"] ?? []) {
            return "waiting_for"
        }
        if matchesAny(text, keywords: categoryHints["maybe"] ?? []) {
            return "maybe"
        }
        if matchesAny(text, keywords: categoryHints["project"] ?? []) {
            return "project"
        }
        if matchesAny(text, keywords: categoryHints["next_action"] ?? []) {
            return "next_action"
        }
        return "inbox"
    }

    private func extractNote(from text: String) -> String {
        var notes: [String] = []

        if let explicit = firstMatch(in: text, pattern: #"(?:备注|note)\s*[:：]\s*(.+)$"#)?.first {
            let cleaned = cleanupNote(explicit)
            if cleaned.isEmpty == false {
                notes.append(cleaned)
            }
        }

        for hint in noteHints where text.contains(hint) {
            let escaped = NSRegularExpression.escapedPattern(for: hint)
            if let segment = firstMatch(in: text, pattern: "([^。；;，,]*\(escaped)[^。；;]*)")?.first {
                let cleaned = cleanupNote(segment)
                if cleaned.isEmpty == false && cleaned.count <= 30 && notes.contains(cleaned) == false {
                    notes.append(cleaned)
                }
            }
        }

        return notes.joined(separator: "；")
    }

    private func detectDueDate(from text: String) -> Date? {
        let calendar = Calendar.current
        let now = Date()

        if text.contains("今天") || text.contains("今日") || text.contains("今晚") {
            return now
        }
        if text.contains("明天") || text.contains("明日") {
            return calendar.date(byAdding: .day, value: 1, to: now)
        }
        if text.contains("后天") {
            return calendar.date(byAdding: .day, value: 2, to: now)
        }

        if let explicit = parseExplicitMonthDay(from: text) {
            return explicit
        }
        if let weekday = parseWeekday(from: text) {
            return weekday
        }

        return nil
    }

    private func parseExplicitMonthDay(from text: String) -> Date? {
        let calendar = Calendar.current
        let now = Date()
        let fullPattern = #"(?:截止到|截止|到|在)?\s*(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})日?"#
        if let match = firstMatch(in: text, pattern: fullPattern), match.count == 3 {
            let comps = DateComponents(
                timeZone: .current,
                year: Int(match[0]),
                month: Int(match[1]),
                day: Int(match[2])
            )
            return calendar.date(from: comps)
        }

        let shortPattern = #"(?:截止到|截止|到|在)?\s*(\d{1,2})[-/.月](\d{1,2})日?"#
        guard let match = firstMatch(in: text, pattern: shortPattern), match.count == 2 else {
            return nil
        }
        guard let month = Int(match[0]), let day = Int(match[1]) else {
            return nil
        }

        let currentYear = calendar.component(.year, from: now)
        var comps = DateComponents(timeZone: .current, year: currentYear, month: month, day: day)
        if let candidate = calendar.date(from: comps), candidate >= calendar.startOfDay(for: now) {
            return candidate
        }
        comps.year = currentYear + 1
        return calendar.date(from: comps)
    }

    private func parseWeekday(from text: String) -> Date? {
        let pattern = #"(下周)?周([一二三四五六日天])"#
        guard let match = firstMatch(in: text, pattern: pattern), match.count == 2 else {
            return nil
        }

        let nextWeek = match[0].isEmpty == false
        let targetToken = match[1]
        let weekdayMap: [String: Int] = ["一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7, "日": 1, "天": 1]
        guard let targetWeekday = weekdayMap[targetToken] else { return nil }

        let calendar = Calendar.current
        let now = Date()
        let currentWeekday = calendar.component(.weekday, from: now)
        var delta = targetWeekday - currentWeekday
        if delta <= 0 {
            delta += 7
        }
        if nextWeek {
            delta += 7
        }
        return calendar.date(byAdding: .day, value: delta, to: now)
    }

    private func deriveReminderTitle(from text: String, reminderLists: [ReminderListInfo]) -> String {
        var title = text

        for prefix in stopPrefixes {
            title = title.replacingOccurrences(of: "\(prefix)：", with: "")
            title = title.replacingOccurrences(of: "\(prefix):", with: "")
            if title.hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count))
            }
        }

        let metaPatterns = [
            #"今天"#, #"今日"#, #"今晚"#, #"明天"#, #"明日"#, #"后天"#, #"下周"#,
            #"(?:下周)?周[一二三四五六日天]"#,
            #"\d{4}[-/.年]\d{1,2}[-/.月]\d{1,2}日?"#,
            #"\d{1,2}[-/.月]\d{1,2}日?"#,
            #"上午"#, #"下午"#, #"晚上"#
        ]
        for pattern in metaPatterns {
            title = replacingRegex(pattern, in: title, with: " ")
        }

        for list in reminderLists where list.title.isEmpty == false {
            title = title.replacingOccurrences(of: list.title, with: " ")
        }

        title = replacingRegex(#"^(把|将|给|替|去|要|先|再)\s*"#, in: title, with: "")
        title = replacingRegex(#"\s*[，,]\s*"#, in: title, with: " ")
        for tail in trimTails where title.hasSuffix(tail) {
            title = String(title.dropLast(tail.count))
        }
        title = replacingRegex(#"^(一下|一个|这件事|这个事情)\s*"#, in: title, with: "")
        return title.trimmingCharacters(in: CharacterSet(charactersIn: " ，,。；;:：").union(.whitespacesAndNewlines))
    }

    private func explicitlyMentionedListName(
        in text: String,
        reminderLists: [ReminderListInfo]
    ) -> String? {
        if let explicit = reminderLists
            .sorted(by: { $0.title.count > $1.title.count })
            .first(where: { text.contains($0.title) })?
            .title {
            return explicit
        }
        return nil
    }

    private func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private struct SummaryMode {
        let scopeLabel: String
        let targetListTitle: String?
        let items: [ReminderItemInfo]
        let confidence: Double
    }

    private func detectSummaryMode(
        from text: String,
        reminderLists: [ReminderListInfo],
        openItems: [ReminderItemInfo],
        calendar: Calendar
    ) -> SummaryMode? {
        let summaryKeywords = [
            "看看", "看下", "看看我", "还有什么", "有哪些", "现在有什么", "当前有什么", "我有什么", "帮我看看"
        ]
        guard matchesAny(text, keywords: summaryKeywords) || containsAnyScopeKeyword(text) else {
            return nil
        }

        if text.contains("今天") {
            let items = openItems.filter { item in
                guard let dueDate = item.dueDate else { return false }
                return calendar.isDateInToday(dueDate)
            }
            return SummaryMode(scopeLabel: "今天", targetListTitle: nil, items: items, confidence: 0.88)
        }

        if text.contains("明天") {
            let items = openItems.filter { item in
                guard let dueDate = item.dueDate else { return false }
                return calendar.isDateInTomorrow(dueDate)
            }
            return SummaryMode(scopeLabel: "明天", targetListTitle: nil, items: items, confidence: 0.88)
        }

        if let matched = matchSummaryListTitle(in: text, reminderLists: reminderLists) {
            let items = openItems.filter { normalize($0.listTitle) == normalize(matched) }
            return SummaryMode(scopeLabel: matched, targetListTitle: matched, items: items, confidence: 0.9)
        }

        if text.contains("等待中") || text.contains("等待") || text.contains("waiting") {
            let items = openItems.filter { item in
                let value = normalize(item.listTitle)
                return value.contains("等待") || value.contains("wait")
            }
            return SummaryMode(scopeLabel: "等待中", targetListTitle: nil, items: items, confidence: 0.84)
        }

        if text.contains("项目") || text.contains("project") {
            let items = openItems.filter { item in
                let value = normalize(item.listTitle)
                return value.contains("项目") || value.contains("project")
            }
            return SummaryMode(scopeLabel: "项目", targetListTitle: nil, items: items, confidence: 0.84)
        }

        if text.contains("收集箱") || text.contains("inbox") {
            let items = openItems.filter { item in
                let value = normalize(item.listTitle)
                return value.contains("收集箱") || value.contains("inbox")
            }
            return SummaryMode(scopeLabel: "收集箱", targetListTitle: nil, items: items, confidence: 0.84)
        }

        if text.contains("也许") || text.contains("未来") || text.contains("maybe") {
            let items = openItems.filter { item in
                if let dueDate = item.dueDate {
                    return calendar.isDateInTomorrow(dueDate) == false && calendar.isDateInToday(dueDate) == false
                }
                return true
            }
            return SummaryMode(scopeLabel: "未来", targetListTitle: nil, items: items, confidence: 0.8)
        }

        let currentItems = openItems
        return SummaryMode(scopeLabel: "当前", targetListTitle: nil, items: currentItems, confidence: 0.82)
    }

    private func containsAnyScopeKeyword(_ text: String) -> Bool {
        matchesAny(text, keywords: ["今天", "明天", "当前", "现在", "收集箱", "项目", "等待中", "等待", "未来", "也许", "inbox", "project", "waiting", "maybe"])
    }

    private func matchSummaryListTitle(in text: String, reminderLists: [ReminderListInfo]) -> String? {
        let normalizedText = normalize(text)
        let aliases: [(label: String, keywords: [String])] = [
            ("收集箱", ["收集箱", "inbox"]),
            ("下一步行动", ["下一步行动", "下一步", "next action", "next"]),
            ("项目", ["项目", "project"]),
            ("等待中", ["等待中", "等待", "waiting"]),
            ("也许以后", ["也许以后", "也许", "maybe", "future"])
        ]

        for alias in aliases {
            if alias.keywords.contains(where: { normalizedText.contains(normalize($0)) }) {
                if let matchedList = reminderLists.first(where: { list in
                    let normalizedList = normalize(list.title)
                    return alias.keywords.contains(where: { normalizedList.contains(normalize($0)) })
                }) {
                    return matchedList.title
                }
                return alias.label
            }
        }

        return explicitlyMentionedListName(in: text, reminderLists: reminderLists)
    }

    private func makeSummaryReply(
        address: String,
        mode: SummaryMode,
        previewItems: [String],
        reminderListCount: Int,
        openItemCount: Int
    ) -> String {
        if reminderListCount == 0 {
            return "\(address)，你现在还没有提醒事项清单。要的话我先帮你搭一套。"
        }

        if mode.items.isEmpty {
            switch mode.scopeLabel {
            case "今天":
                return "\(address)，你今天暂时没有到期的提醒。"
            case "明天":
                return "\(address)，你明天暂时还没有安排。"
            case "收集箱":
                return "\(address)，收集箱里现在还空着。"
            case "项目":
                return "\(address)，项目这边我暂时没看到新的内容。"
            case "等待中":
                return "\(address)，等待中的事情现在还没有新的。"
            case "也许以后", "未来":
                return "\(address)，未来清单里现在暂时没有要补的。"
            default:
                return "\(address)，当前暂时没有新的提醒。"
            }
        }

        let itemsText = previewItems.joined(separator: "、")
        let suffix = mode.items.count > previewItems.count ? "，另外还有 \(mode.items.count - previewItems.count) 条" : ""

        switch mode.scopeLabel {
        case "今天":
            return "\(address)，你今天主要还有：\(itemsText)\(suffix)。"
        case "明天":
            return "\(address)，你明天主要有：\(itemsText)\(suffix)。"
        case "收集箱":
            return "\(address)，收集箱里我先看到：\(itemsText)\(suffix)。"
        case "项目":
            return "\(address)，项目这边我先帮你看到了：\(itemsText)\(suffix)。"
        case "等待中":
            return "\(address)，等待中的事情主要有：\(itemsText)\(suffix)。"
        case "也许以后", "未来":
            return "\(address)，未来这边先看见：\(itemsText)\(suffix)。"
        case "当前":
            return "\(address)，你现在主要还有：\(itemsText)\(suffix)。"
        default:
            return "\(address)，\(mode.scopeLabel)主要有：\(itemsText)\(suffix)。"
        }
    }

    private func firstMatch(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }

    private func replacingRegex(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let replaced = regex.stringByReplacingMatches(in: text, range: nsRange, withTemplate: template)
        return replaced.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func matchesRegex(_ text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: nsRange) != nil
    }

    private func cleanupNote(_ text: String) -> String {
        var value = text
        value = replacingRegex(#"#[A-Za-z][A-Za-z0-9_-]*"#, in: value, with: " ")
        value = replacingRegex(#"^(把|将)\s*"#, in: value, with: "")
        value = replacingRegex(#"(?:提醒我|帮我|记得|记一下|记录一下)\s*"#, in: value, with: " ")
        value = replacingRegex(#"(?:今天|今日|今晚|明天|明日|下周|以后)\s*"#, in: value, with: " ")
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " ，,。；;:：").union(.whitespacesAndNewlines))
    }

    private func detectMove(from text: String) -> (target: String, destinationList: String, confidence: Double, signals: [String])? {
        guard matchesAny(text, keywords: ["移到", "移去", "放到", "放进", "转到", "改到", "切到"]) else {
            return nil
        }

        guard let destination = quotedText(in: text) else {
            return nil
        }

        let target = findTargetText(in: text) ?? "当前这条"
        return (target: target, destinationList: destination, confidence: 0.88, signals: ["move", "destination:\(destination)"])
    }

    private func detectCompletion(from text: String) -> (target: String, confidence: Double, signals: [String])? {
        guard matchesAny(text, keywords: ["完成", "搞定", "做完", "标记完成", "已完成"]) else {
            return nil
        }

        let target = findCompletionTarget(in: text) ?? findTargetText(in: text) ?? "当前这条"
        return (target: target, confidence: 0.9, signals: ["complete"])
    }

    private func detectDeletion(from text: String) -> (target: String, confidence: Double, signals: [String])? {
        guard matchesAny(text, keywords: ["删除", "删掉", "删了", "移除"]) else {
            return nil
        }

        let likelyListDeletion = matchesAny(text, keywords: ["清单", "列表"]) &&
            matchesAny(text, keywords: ["任务", "待办", "提醒", "这条", "那条", "上一条", "刚才", "刚刚"]) == false
        guard likelyListDeletion == false else {
            return nil
        }

        let target = findDeletionTarget(in: text) ?? findTargetText(in: text) ?? "当前这条"
        return (target: target, confidence: 0.9, signals: ["delete"])
    }

    private func findDeletionTarget(in text: String) -> String? {
        let patterns = [
            #"(?:删除|删掉|删了|移除)\s*[“\"‘']?(.+?)[”\"’']?$"#,
            #"把\s*[“\"‘']?(.+?)[”\"’']?\s*(?:删除|删掉|删了|移除)$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: nsRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else {
                continue
            }

            let extracted = String(text[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ，,。；;:：\"'“”‘’").union(.whitespacesAndNewlines))
            if extracted.isEmpty == false {
                return extracted
            }
        }

        return nil
    }

    private func findCompletionTarget(in text: String) -> String? {
        let patterns = [
            #"(?:标记完成|已完成|完成|搞定|做完)\s*[“\"‘']?(.+?)[”\"’']?$"#,
            #"把\s*[“\"‘']?(.+?)[”\"’']?\s*(?:标记完成|完成|搞定|做完)$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: nsRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else {
                continue
            }

            let extracted = String(text[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ，,。；;:：\"'“”‘’").union(.whitespacesAndNewlines))
            if extracted.isEmpty == false {
                return extracted
            }
        }

        return nil
    }

    private func findTargetText(in text: String) -> String? {
        if let quoted = quotedText(in: text) {
            return quoted
        }

        if text.contains("这条") || text.contains("这件事") || text.contains("这个") {
            return "当前这条"
        }

        return nil
    }

    private func quotedText(in text: String) -> String? {
        let pairs: [(String, String)] = [("“", "”"), ("\"", "\""), ("‘", "’")]
        for pair in pairs {
            if let range = text.range(of: pair.0),
               let endRange = text[range.upperBound...].range(of: pair.1) {
                let value = String(text[range.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty == false {
                    return value
                }
            }
        }
        return nil
    }

    private func matchesAny(_ text: String, keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private func makeResult(
        reply: String,
        summary: String,
        action: MockAgentAction,
        confidence: Double,
        followUpPrompt: String?,
        matchedSignals: [String]
    ) -> MockAgentResult {
        let envelope = MockAgentEnvelope(
            action: action.payload(),
            confidence: confidence,
            summary: summary,
            followUpPrompt: followUpPrompt,
            matchedSignals: matchedSignals
        )
        return MockAgentResult(
            reply: reply,
            summary: summary,
            actionType: action.intent.rawValue,
            payloadJSON: jsonPayload(envelope),
            confidence: confidence,
            followUpPrompt: followUpPrompt
        )
    }

    private func jsonPayload<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
