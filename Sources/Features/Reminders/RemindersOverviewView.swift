import SwiftUI

struct RemindersOverviewView: View {
    @Environment(AppModel.self) private var appModel
    @State private var pendingFocusID: String?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    Text("这里会展示 Reminders 列表和任务。")
                    Text("当前版本已经接入系统提醒事项列表和任务读取。")
                        .foregroundStyle(.secondary)
                }

                if appModel.isLoadingReminderLists {
                    Section {
                        ProgressView("正在加载提醒事项列表…")
                    }
                } else if appModel.reminderLists.isEmpty {
                    Section("当前没有列表") {
                        Text("你还没有任何提醒事项列表。可以先用推荐模板快速开始。")
                            .foregroundStyle(.secondary)
                        Button("创建推荐起步列表") {
                            Task {
                                _ = await appModel.createStarterTemplate()
                                await syncFocusAndRefresh(using: proxy)
                            }
                        }
                    }
                } else {
                    Section("系统列表") {
                        ForEach(appModel.reminderLists) { item in
                            HStack {
                                Text(item.title)
                                Spacer()
                                Text(listItemCount(for: item.title))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    ForEach(reminderSections) { section in
                        Section(section.title) {
                            ForEach(section.items) { item in
                                ReminderItemRow(
                                    item: item,
                                    isFocused: item.id == pendingFocusID
                                )
                                .id(item.id)
                            }
                        }
                    }
                }

                if appModel.reminderListsErrorMessage.isEmpty == false {
                    Section("提示") {
                        Text(appModel.reminderListsErrorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Reminders")
            .task {
                await syncFocusAndRefresh(using: proxy)
            }
            .refreshable {
                await syncFocusAndRefresh(using: proxy)
            }
            .onChange(of: pendingFocusID) { _, newValue in
                guard let newValue else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }

    private var reminderSections: [ReminderListSection] {
        let grouped = Dictionary(grouping: appModel.reminderItems) { item in
            normalizedListTitle(item.listTitle)
        }

        let orderedKnownLists = appModel.reminderLists.compactMap { list -> ReminderListSection? in
            guard let items = grouped[normalizedListTitle(list.title)], items.isEmpty == false else {
                return nil
            }
            return ReminderListSection(title: list.title, items: items)
        }

        let knownListKeys = Set(appModel.reminderLists.map { normalizedListTitle($0.title) })
        let remainingSections = grouped
            .filter { knownListKeys.contains($0.key) == false }
            .map { key, items in
                ReminderListSection(title: displayListTitle(for: key, fallbackItems: items), items: items)
            }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }

        return orderedKnownLists + remainingSections
    }

    private func listItemCount(for listTitle: String) -> String {
        let count = appModel.reminderItems.filter { normalizedListTitle($0.listTitle) == normalizedListTitle(listTitle) }.count
        return count == 0 ? "" : "\(count)"
    }

    private func displayListTitle(for key: String, fallbackItems: [ReminderItemInfo]) -> String {
        if key.isEmpty == false {
            if let title = fallbackItems.first?.listTitle.trimmingCharacters(in: .whitespacesAndNewlines),
               title.isEmpty == false {
                return title
            }
            return key
        }
        return "未分类"
    }

    private func normalizedListTitle(_ title: String) -> String {
        title
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
    }

    private func syncFocusAndRefresh(using proxy: ScrollViewProxy) async {
        await appModel.refreshReminderLists()
        pendingFocusID = appModel.consumePendingReminderFocusIdentifier()
        guard let focusID = pendingFocusID else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(focusID, anchor: .center)
            }
        }
    }
}

private struct ReminderListSection: Identifiable {
    let id: String
    let title: String
    let items: [ReminderItemInfo]

    init(title: String, items: [ReminderItemInfo]) {
        self.id = title
        self.title = title
        self.items = items
    }
}

private struct ReminderItemRow: View {
    let item: ReminderItemInfo
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isCompleted ? .green : .secondary)
                Text(item.title)
                    .font(.body.weight(.medium))
                    .strikethrough(item.isCompleted, color: .secondary)
                Spacer(minLength: 8)
                Text(item.listTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let dueDate = item.dueDate {
                Text("提醒时间：\(dueDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if item.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                Text(item.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isFocused ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }
}

#Preview {
    NavigationStack {
        RemindersOverviewView()
            .environment(AppModel.previewFinished)
    }
}
