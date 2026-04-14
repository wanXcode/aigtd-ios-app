import SwiftUI
import UIKit

struct RemindersOverviewView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openURL) private var openURL

    @State private var pendingFocusID: String?
    @State private var processingReminderIDs: Set<String> = []
    @State private var reminderPendingDeletion: ReminderItemInfo?

    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                if appModel.remindersAccessGranted == false {
                    permissionState
                } else if appModel.isLoadingReminderLists && groupedActiveSections.isEmpty {
                    loadingState
                } else if appModel.reminderListsErrorMessage.isEmpty == false && appModel.reminderLists.isEmpty {
                    errorState(proxy: proxy)
                } else if appModel.reminderLists.isEmpty {
                    starterTemplateState(proxy: proxy)
                } else if groupedActiveSections.isEmpty {
                    emptyState(proxy: proxy)
                } else {
                    dashboardContent(proxy: proxy)
                }
            }
            .navigationTitle("全部")
            .navigationBarTitleDisplayMode(.large)
            .task {
                await refreshDashboard(using: proxy, refreshPermission: true)
            }
            .confirmationDialog("删除这条提醒事项？", isPresented: deleteDialogBinding, titleVisibility: .visible) {
                if let item = reminderPendingDeletion {
                    Button("删除", role: .destructive) {
                        performDelete(item, using: proxy)
                    }
                }
            } message: {
                if let item = reminderPendingDeletion {
                    Text("“\(item.title)”会从系统 Reminders 中删除。")
                }
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

    private func dashboardContent(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(syncSectionTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedActiveSections) { section in
                            ReminderGroupSectionView(
                                section: section,
                                pendingFocusID: pendingFocusID,
                                processingReminderIDs: processingReminderIDs,
                                color: color(for: section.title),
                                dueDescriptor: dueDescriptor(for:),
                                onToggleCompletion: { item in
                                    performToggle(for: item, using: proxy)
                                },
                                onDelete: { item in
                                    reminderPendingDeletion = item
                                }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .refreshable {
            await refreshDashboard(using: proxy, refreshPermission: true)
        }
    }

    private var groupedActiveSections: [ReminderGroupSection] {
        let activeItems = appModel.reminderItems
            .filter { $0.isCompleted == false }

        let grouped = Dictionary(grouping: activeItems) { normalizedListTitle($0.listTitle) }

        let orderedKnownLists = appModel.reminderLists.map { list in
            let key = normalizedListTitle(list.title)
            return ReminderGroupSection(
                title: list.title,
                items: (grouped[key] ?? []).sorted(by: reminderSort)
            )
        }

        let knownKeys = Set(appModel.reminderLists.map { normalizedListTitle($0.title) })
        let remaining = grouped
            .filter { knownKeys.contains($0.key) == false }
            .map { key, items in
                ReminderGroupSection(
                    title: displayListTitle(for: key, fallbackItems: items),
                    items: items.sorted(by: reminderSort)
                )
            }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }

        return orderedKnownLists + remaining
    }

    private var completedReminderCount: Int {
        appModel.reminderItems.filter(\.isCompleted).count
    }

    private var permissionState: some View {
        RemindersStateView(
            title: "还没有连接到系统提醒事项",
            message: permissionDescription,
            primaryTitle: appModel.reminderPermissionStatus == .notDetermined ? "请求授权" : "去系统设置",
            primaryAction: {
                if appModel.reminderPermissionStatus == .notDetermined {
                    Task {
                        await appModel.requestReminderPermission()
                    }
                } else {
                    openSystemSettings()
                }
            },
            secondaryTitle: "重新检查",
            secondaryAction: {
                Task {
                    await appModel.refreshReminderPermission()
                }
            }
        )
    }

    private var syncSectionTitle: String {
        if appModel.isLoadingReminderLists {
            return "正在同步提醒事项…"
        }

        guard let lastReminderSyncAt = appModel.lastReminderSyncAt else {
            return "还没有同步过提醒事项"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "最新同步 \(formatter.localizedString(for: lastReminderSyncAt, relativeTo: .now))"
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("正在同步提醒事项…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func starterTemplateState(proxy: ScrollViewProxy) -> some View {
        RemindersStateView(
            title: "还没有提醒事项列表",
            message: "先创建一套起步列表，后面你在 Chat 里记下来的任务就能直接落进系统提醒事项。",
            primaryTitle: "创建推荐起步列表",
            primaryAction: {
                Task {
                    _ = await appModel.createStarterTemplate()
                    await refreshDashboard(using: proxy)
                }
            },
            secondaryTitle: "先去聊天",
            secondaryAction: {
                appModel.selectedTab = .chat
            }
        )
    }

    private func errorState(proxy: ScrollViewProxy) -> some View {
        RemindersStateView(
            title: "提醒事项暂时没同步成功",
            message: appModel.reminderListsErrorMessage,
            primaryTitle: "重新同步",
            primaryAction: {
                Task {
                    await refreshDashboard(using: proxy, refreshPermission: true)
                }
            },
            secondaryTitle: "去聊天",
            secondaryAction: {
                appModel.selectedTab = .chat
            }
        )
    }

    private func emptyState(proxy: ScrollViewProxy) -> some View {
        RemindersStateView(
            title: "现在没有未完成任务",
            message: completedReminderCount == 0
                ? "系统里暂时是空的。你可以回 Chat 再记一条，或者重新同步看看。"
                : "当前看到的任务都已经处理完了，已完成 \(completedReminderCount) 条。",
            primaryTitle: "去聊天记一条",
            primaryAction: {
                appModel.selectedTab = .chat
            },
            secondaryTitle: "重新同步",
            secondaryAction: {
                Task {
                    await refreshDashboard(using: proxy, refreshPermission: true)
                }
            }
        )
    }

    private var permissionDescription: String {
        switch appModel.reminderPermissionStatus {
        case .notDetermined:
            return "先给 AIGTD 打开提醒事项权限，这里才能显示系统里的全部清单。"
        case .denied:
            return "你之前拒绝了提醒事项权限，需要到系统设置里重新打开。"
        case .restricted:
            return "当前设备限制了提醒事项权限，需要先在系统层处理。"
        default:
            return "提醒事项权限暂时不可用，请重新检查。"
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { reminderPendingDeletion != nil },
            set: { newValue in
                if newValue == false {
                    reminderPendingDeletion = nil
                }
            }
        )
    }

    private func normalizedListTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func displayListTitle(for key: String, fallbackItems: [ReminderItemInfo]) -> String {
        if let title = fallbackItems.first?.listTitle.trimmingCharacters(in: .whitespacesAndNewlines),
           title.isEmpty == false {
            return title
        }
        return key.isEmpty ? "未分类" : key
    }

    private func reminderSort(lhs: ReminderItemInfo, rhs: ReminderItemInfo) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case let (left?, right?):
            if left != right { return left < right }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        return lhs.title.localizedCompare(rhs.title) == .orderedAscending
    }

    private func color(for title: String) -> Color {
        let key = normalizedListTitle(title)
        switch key {
        case let value where value.contains("收集箱"), let value where value.contains("inbox"):
            return Color(red: 0.31, green: 0.64, blue: 1.0)
        case let value where value.contains("下一步"), let value where value.contains("nextaction"):
            return Color(red: 1.0, green: 0.31, blue: 0.24)
        case let value where value.contains("项目"), let value where value.contains("project"):
            return Color(red: 1.0, green: 0.62, blue: 0.16)
        case let value where value.contains("等待"), let value where value.contains("waiting"):
            return Color(red: 0.39, green: 0.63, blue: 1.0)
        case let value where value.contains("也许"), let value where value.contains("maybe"):
            return Color(red: 0.62, green: 0.49, blue: 1.0)
        default:
            return .accentColor
        }
    }

    private func dueDescriptor(for item: ReminderItemInfo) -> ReminderDueDescriptor? {
        guard let dueDate = item.dueDate else { return nil }

        let isOverdue = dueDate < Calendar.current.startOfDay(for: .now)
        let tint: Color
        if isOverdue {
            tint = Color(red: 0.95, green: 0.33, blue: 0.29)
        } else if Calendar.current.isDateInToday(dueDate) {
            tint = Color(red: 1.0, green: 0.62, blue: 0.16)
        } else {
            tint = .secondary
        }

        return ReminderDueDescriptor(
            text: dueDate.formatted(date: .numeric, time: .omitted),
            tint: tint
        )
    }

    private func refreshDashboard(using proxy: ScrollViewProxy, refreshPermission: Bool = false) async {
        if refreshPermission {
            await appModel.refreshReminderPermission()
        } else {
            await appModel.refreshReminderLists()
        }

        pendingFocusID = appModel.consumePendingReminderFocusIdentifier()
        guard let focusID = pendingFocusID else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(focusID, anchor: .center)
            }
        }
    }

    private func performToggle(for item: ReminderItemInfo, using proxy: ScrollViewProxy) {
        guard processingReminderIDs.contains(item.id) == false else { return }
        processingReminderIDs.insert(item.id)

        Task {
            _ = await appModel.setReminderCompletion(identifier: item.id, isCompleted: !item.isCompleted)
            processingReminderIDs.remove(item.id)

            if let nextID = groupedActiveSections.flatMap(\.items).first?.id {
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(nextID, anchor: .top)
                    }
                }
            }
        }
    }

    private func performDelete(_ item: ReminderItemInfo, using proxy: ScrollViewProxy) {
        guard processingReminderIDs.contains(item.id) == false else { return }
        processingReminderIDs.insert(item.id)

        Task {
            _ = await appModel.deleteReminder(identifier: item.id)
            processingReminderIDs.remove(item.id)
            reminderPendingDeletion = nil

            if let nextID = groupedActiveSections.flatMap(\.items).first?.id {
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(nextID, anchor: .top)
                    }
                }
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

private struct ReminderGroupSection: Identifiable {
    let id: String
    let title: String
    let items: [ReminderItemInfo]

    init(title: String, items: [ReminderItemInfo]) {
        self.id = title
        self.title = title
        self.items = items
    }
}

private struct ReminderDueDescriptor {
    let text: String
    let tint: Color
}

private struct ReminderGroupSectionView: View {
    let section: ReminderGroupSection
    let pendingFocusID: String?
    let processingReminderIDs: Set<String>
    let color: Color
    let dueDescriptor: (ReminderItemInfo) -> ReminderDueDescriptor?
    let onToggleCompletion: (ReminderItemInfo) -> Void
    let onDelete: (ReminderItemInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(color)
                .padding(.bottom, 10)

            if section.items.isEmpty {
                Text("这个清单里暂时没有未完成任务")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 2)
            } else {
                ForEach(section.items) { item in
                    ReminderNativeRow(
                        item: item,
                        isFocused: item.id == pendingFocusID,
                        isProcessing: processingReminderIDs.contains(item.id),
                        dueDescriptor: dueDescriptor(item),
                        onToggleCompletion: {
                            onToggleCompletion(item)
                        }
                    )
                    .id(item.id)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("完成") {
                            onToggleCompletion(item)
                        }
                        .tint(.green)

                        Button("删除", role: .destructive) {
                            onDelete(item)
                        }
                    }
                }
            }

            Divider()
                .overlay(Color(.separator))
                .padding(.top, 14)
                .padding(.bottom, 12)
        }
    }
}

private struct ReminderNativeRow: View {
    let item: ReminderItemInfo
    let isFocused: Bool
    let isProcessing: Bool
    let dueDescriptor: ReminderDueDescriptor?
    let onToggleCompletion: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggleCompletion) {
                Group {
                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 24, height: 24, alignment: .top)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                if let dueDescriptor {
                    Text(dueDescriptor.text)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(dueDescriptor.tint)
                }
            }
            .padding(.top, 1)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? Color.accentColor.opacity(0.10) : Color.clear)
        )
    }
}

private struct RemindersStateView: View {
    let title: String
    let message: String
    let primaryTitle: String
    let primaryAction: () -> Void
    let secondaryTitle: String?
    let secondaryAction: (() -> Void)?

    init(
        title: String,
        message: String,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.primaryTitle = primaryTitle
        self.primaryAction = primaryAction
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(RemindersPrimaryButtonStyle())

                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .buttonStyle(RemindersSecondaryButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 22)
        .padding(.top, 28)
        .background(Color(.systemGroupedBackground))
    }
}

private struct RemindersPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1))
            )
    }
}

private struct RemindersSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }
}

#Preview {
    NavigationStack {
        RemindersOverviewView()
            .environment(AppModel.previewFinished)
    }
}
