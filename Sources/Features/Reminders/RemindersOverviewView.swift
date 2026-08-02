import SwiftUI
import UIKit

struct RemindersOverviewView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    @State private var pendingFocusID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                overviewBackground.ignoresSafeArea()

                if appModel.remindersAccessGranted == false {
                    permissionState
                } else if appModel.isLoadingReminderLists && overviewSections.isEmpty {
                    loadingState
                } else if appModel.reminderListsErrorMessage.isEmpty == false && appModel.reminderLists.isEmpty {
                    errorState(proxy: proxy)
                } else if appModel.reminderLists.isEmpty {
                    noListsState(proxy: proxy)
                } else {
                    dashboardContent(proxy: proxy)
                }
            }
            .navigationTitle("任务")
            .navigationBarTitleDisplayMode(.large)
            .task {
                await refreshDashboard(using: proxy, refreshPermission: true)
            }
            .onChange(of: pendingFocusID) { _, newValue in
                guard let newValue else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }

    private var overviewSections: [ReminderOverviewSection] {
        ReminderOverviewPolicy.sections(
            lists: appModel.reminderLists,
            items: appModel.reminderItems
        )
    }

    private func dashboardContent(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                overviewHeader

                if appModel.reminderListsErrorMessage.isEmpty == false {
                    syncFailureBanner(proxy: proxy)
                }

                ForEach(overviewSections) { section in
                    ReminderOverviewListCard(
                        section: section,
                        pendingFocusID: pendingFocusID,
                        accent: accentColor(for: section.title)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .refreshable {
            await refreshDashboard(using: proxy, refreshPermission: true)
        }
    }

    private var overviewHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(red: 0.94, green: 0.48, blue: 0.19))
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(Color(red: 1.0, green: 0.86, blue: 0.70).opacity(0.48))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("AIGTD 任务概览")
                        .font(.headline.weight(.bold))
                    Text("来自 Apple 提醒事项")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            Text("这里用于确认任务状态。需要修改时，让小满来处理。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Label(
                    ReminderOverviewPolicy.syncDescription(
                        isLoading: appModel.isLoadingReminderLists,
                        lastSyncAt: appModel.lastReminderSyncAt,
                        now: timeline.date
                    ),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(18)
        .background(overviewCardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.accentColor.opacity(0.10), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func syncFailureBanner(proxy: ScrollViewProxy) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text("同步未完成，当前显示上次结果")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("重试") {
                Task {
                    await refreshDashboard(using: proxy)
                }
            }
            .font(.subheadline.weight(.semibold))
            .disabled(appModel.isLoadingReminderLists)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(overviewCardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        }
    }

    private var permissionState: some View {
        RemindersOverviewStateView(
            title: "连接你的提醒事项",
            message: permissionDescription,
            primaryTitle: appModel.reminderPermissionStatus == .notDetermined ? "允许访问" : "去系统设置",
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

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(.accentColor)
            Text("正在同步任务概览…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noListsState(proxy: ScrollViewProxy) -> some View {
        RemindersOverviewStateView(
            title: "还没有可显示的清单",
            message: "任务会继续保存在 Apple 提醒事项。你可以先去 AIGTD 告诉小满想记下什么。",
            primaryTitle: "去找小满",
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

    private func errorState(proxy: ScrollViewProxy) -> some View {
        RemindersOverviewStateView(
            title: "任务暂时没有同步好",
            message: "请稍后重试。你在 Apple 提醒事项中的任务不会受到影响。",
            primaryTitle: "重新同步",
            primaryAction: {
                Task {
                    await refreshDashboard(using: proxy, refreshPermission: true)
                }
            },
            secondaryTitle: "去找小满",
            secondaryAction: {
                appModel.selectedTab = .chat
            }
        )
    }

    private var permissionDescription: String {
        switch appModel.reminderPermissionStatus {
        case .notDetermined:
            return "允许 AIGTD 读取 Apple 提醒事项后，这里会显示你的清单和任务。"
        case .denied:
            return "需要在系统设置中允许 AIGTD 访问提醒事项，才能显示任务概览。"
        case .restricted:
            return "当前设备限制了提醒事项访问，请先检查系统限制。"
        default:
            return "提醒事项访问暂时不可用，请重新检查。"
        }
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
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo(focusID, anchor: .center)
            }
        }
    }

    private func accentColor(for title: String) -> Color {
        let key = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case let value where value.contains("收集箱"), let value where value.contains("inbox"):
            return Color(red: 0.16, green: 0.55, blue: 0.96)
        case let value where value.contains("项目"), let value where value.contains("project"):
            return Color(red: 0.94, green: 0.48, blue: 0.19)
        case let value where value.contains("等待"), let value where value.contains("waiting"):
            return Color(red: 0.20, green: 0.67, blue: 0.59)
        default:
            return Color(red: 0.30, green: 0.53, blue: 0.95)
        }
    }

    private var overviewBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.095, blue: 0.09)
            : Color(red: 0.975, green: 0.965, blue: 0.94)
    }

    private var overviewCardBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.15, blue: 0.14)
            : Color.white.opacity(0.88)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

private struct ReminderOverviewListCard: View {
    let section: ReminderOverviewSection
    let pendingFocusID: String?
    let accent: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(accent)
                    .frame(width: 5, height: 24)

                Text(section.title)
                    .font(.title3.weight(.bold))

                Spacer(minLength: 8)

                Text("\(section.items.count) 项")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if section.items.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "tray")
                        .foregroundStyle(accent.opacity(0.75))
                    Text("这个清单暂时没有任务")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 10) {
                    ForEach(section.items) { item in
                        NavigationLink {
                            ReminderReadOnlyDetailView(
                                item: item,
                                onAskXiaomanToAdjust: { appModel in
                                    appModel.routeToChatForReminderAdjustment(item)
                                },
                                onOpenInReminders: openReminder
                            )
                        } label: {
                            ReminderOverviewTaskCard(
                                item: item,
                                isFocused: item.id == pendingFocusID,
                                accent: accent
                            )
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
            }
        }
        .padding(16)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(accent.opacity(0.12), lineWidth: 1)
        }
    }

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.15, blue: 0.14)
            : Color.white.opacity(0.88)
    }

    private func openReminder(_ item: ReminderItemInfo, openURL: OpenURLAction) {
        guard let encodedID = item.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let itemURL = URL(string: "x-apple-reminderkit://REMCDReminder/\(encodedID)") else {
            openRemindersApp(using: openURL)
            return
        }

        openURL(itemURL) { accepted in
            if accepted == false {
                openRemindersApp(using: openURL)
            }
        }
    }

    private func openRemindersApp(using openURL: OpenURLAction) {
        guard let url = URL(string: "x-apple-reminderkit://") else { return }
        openURL(url)
    }
}

private struct ReminderOverviewTaskCard: View {
    let item: ReminderItemInfo
    let isFocused: Bool
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.isCompleted ? "checkmark.sparkles" : "text.badge.checkmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Label(reminderDateDescription(item.dueDate), systemImage: "calendar")
                    Text("·")
                    Text(item.listTitle.isEmpty ? "未分类" : item.listTitle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

                Text(reminderStatusDescription(item))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(statusTint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(statusTint.opacity(0.10), in: Capsule(style: .continuous))
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isFocused ? accent.opacity(0.12) : Color.primary.opacity(0.035))
        )
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(accent.opacity(0.32), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开只读任务详情")
    }

    private var statusTint: Color {
        if item.isCompleted {
            return Color(red: 0.20, green: 0.64, blue: 0.43)
        }
        if let dueDate = item.dueDate,
           dueDate < Calendar.current.startOfDay(for: .now) {
            return Color(red: 0.86, green: 0.31, blue: 0.27)
        }
        return accent
    }
}

struct ReminderReadOnlyDetailView: View {
    let item: ReminderItemInfo
    let onAskXiaomanToAdjust: (AppModel) -> Void
    let onOpenInReminders: (ReminderItemInfo, OpenURLAction) -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Color(red: 0.94, green: 0.48, blue: 0.19))
                            .frame(width: 38, height: 38)
                            .background(Color.orange.opacity(0.12), in: Circle())

                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title)
                                .font(.title2.weight(.bold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text("只读任务详情")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("这条任务保存在 Apple 提醒事项中。AIGTD 不会在这个页面直接修改它。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .background(detailCardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                VStack(spacing: 0) {
                    ReminderDetailValueRow(label: "时间", value: reminderDateDescription(item.dueDate))
                    Divider().padding(.leading, 16)
                    ReminderDetailValueRow(label: "清单", value: item.listTitle.isEmpty ? "未分类" : item.listTitle)
                    Divider().padding(.leading, 16)
                    ReminderDetailValueRow(label: "状态", value: reminderStatusDescription(item))
                }
                .background(detailCardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                if item.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("备注")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(item.notes)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(detailCardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                VStack(spacing: 12) {
                    Button {
                        onAskXiaomanToAdjust(appModel)
                    } label: {
                        Label("让小满调整", systemImage: "bubble.left.and.sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RemindersOverviewPrimaryButtonStyle())

                    Button {
                        onOpenInReminders(item, openURL)
                    } label: {
                        Label("在提醒事项中打开", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RemindersOverviewSecondaryButtonStyle())
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(detailBackground.ignoresSafeArea())
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var detailBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.10, green: 0.095, blue: 0.09)
            : Color(red: 0.975, green: 0.965, blue: 0.94)
    }

    private var detailCardBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.16, green: 0.15, blue: 0.14)
            : Color.white.opacity(0.90)
    }
}

private struct ReminderDetailValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }
        .padding(16)
    }
}

private struct RemindersOverviewStateView: View {
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
            Image(systemName: "sparkles")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color(red: 0.94, green: 0.48, blue: 0.19))

            Text(title)
                .font(.title2.weight(.bold))

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(RemindersOverviewPrimaryButtonStyle())

                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .buttonStyle(RemindersOverviewSecondaryButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 22)
        .padding(.top, 30)
    }
}

private struct RemindersOverviewPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(minHeight: 48)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.78 : 1))
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct RemindersOverviewSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(minHeight: 48)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.09 : 0.055))
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private func reminderDateDescription(_ dueDate: Date?) -> String {
    guard let dueDate else { return "未设置时间" }

    let components = Calendar.current.dateComponents([.hour, .minute, .second], from: dueDate)
    let hasExplicitTime = components.hour != 0 || components.minute != 0 || components.second != 0
    return dueDate.formatted(
        date: .abbreviated,
        time: hasExplicitTime ? .shortened : .omitted
    )
}

private func reminderStatusDescription(_ item: ReminderItemInfo) -> String {
    if item.isCompleted {
        return "已完成"
    }
    if let dueDate = item.dueDate,
       dueDate < Calendar.current.startOfDay(for: .now) {
        return "已逾期"
    }
    return "待处理"
}

#Preview {
    NavigationStack {
        RemindersOverviewView()
            .environment(AppModel.previewFinished)
    }
}
