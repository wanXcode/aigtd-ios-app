import Foundation

struct AppleRemindersMappingRuleEngine {
    struct ResolvedMapping: Sendable {
        let targetListName: String?
        let matchedRuleID: String?
    }

    private struct CanonicalList {
        let id: String
        let synonyms: [String]
    }

    private let canonicalLists: [CanonicalList] = [
        CanonicalList(id: "inbox", synonyms: ["收集箱", "Inbox", "收件箱"]),
        CanonicalList(id: "project", synonyms: ["项目", "Project", "Projects"]),
        CanonicalList(id: "next_action", synonyms: ["下一步行动", "Next Action", "Next"]),
        CanonicalList(id: "waiting_for", synonyms: ["等待中", "等待", "Waiting For", "Waiting"]),
        CanonicalList(id: "maybe", synonyms: ["也许以后", "可能的事", "Maybe", "Someday"])
    ]

    func resolveTargetList(
        explicitListName: String?,
        category: String,
        tags: [String],
        bucket: String,
        text: String,
        note: String,
        reminderLists: [ReminderListInfo]
    ) -> ResolvedMapping {
        if let explicitListName,
           let explicit = reminderLists.first(where: { normalize($0.title) == normalize(explicitListName) }) {
            return ResolvedMapping(targetListName: explicit.title, matchedRuleID: "explicit_list_match")
        }

        if tags.contains(where: { ["WAIT", "FOLLOWUP", "FOLLOW_UP"].contains($0.uppercased()) }),
           let waiting = resolveCanonicalList(id: "waiting_for", reminderLists: reminderLists) {
            return ResolvedMapping(targetListName: waiting, matchedRuleID: "manual_wait_tag")
        }

        if let categoryList = resolveCanonicalList(id: category, reminderLists: reminderLists) {
            return ResolvedMapping(targetListName: categoryList, matchedRuleID: "category_\(category)")
        }

        let waitingKeywords = ["等待", "等", "确认", "回复", "回信", "跟进", "催", "反馈"]
        if containsAny(text, keywords: waitingKeywords) || containsAny(note, keywords: waitingKeywords),
           let waiting = resolveCanonicalList(id: "waiting_for", reminderLists: reminderLists) {
            return ResolvedMapping(targetListName: waiting, matchedRuleID: "keyword_waiting_for")
        }

        if bucket == "future",
           let maybe = resolveCanonicalList(id: "maybe", reminderLists: reminderLists) {
            return ResolvedMapping(targetListName: maybe, matchedRuleID: "bucket_future_to_maybe")
        }

        if let inbox = resolveCanonicalList(id: "inbox", reminderLists: reminderLists) {
            return ResolvedMapping(targetListName: inbox, matchedRuleID: "fallback_open_tasks")
        }

        return ResolvedMapping(targetListName: nil, matchedRuleID: nil)
    }

    private func resolveCanonicalList(id: String, reminderLists: [ReminderListInfo]) -> String? {
        guard let canonical = canonicalLists.first(where: { $0.id == id }) else { return nil }
        for synonym in canonical.synonyms {
            if let matched = reminderLists.first(where: { normalize($0.title) == normalize(synonym) }) {
                return matched.title
            }
        }
        return nil
    }

    private func containsAny(_ text: String, keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private func normalize(_ title: String) -> String {
        let primary = title.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? title
        return primary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
