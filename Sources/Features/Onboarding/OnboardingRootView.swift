import EventKit
import SwiftUI

struct OnboardingRootView: View {
    @Environment(AppModel.self) private var appModel
    @State private var step: OnboardingStep = .welcome

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .padding()
        }
        .task {
            await appModel.refreshReminderPermission()
            syncStep()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            WelcomeStepView(
                onContinue: {
                    appModel.onboardingState.hasSeenWelcome = true
                    step = .remindersPermission
                }
            )
        case .remindersPermission:
            ReminderPermissionStepView(
                permissionStatus: appModel.reminderPermissionStatus,
                onAllow: {
                    Task {
                        await appModel.requestReminderPermission()
                        step = appModel.remindersAccessGranted && appModel.isReminderStoreEmpty ? .starterTemplate : .chatIntro
                    }
                },
                onSkip: {
                    appModel.onboardingState.hasRequestedReminderPermission = true
                    step = .chatIntro
                }
            )
        case .starterTemplate:
            StarterTemplateStepView(
                lists: appModel.starterLists,
                isCreating: appModel.isLoadingReminderLists,
                errorMessage: appModel.reminderListsErrorMessage,
                onUseTemplate: {
                    Task {
                        let created = await appModel.createStarterTemplate()
                        appModel.onboardingState.hasSeenStarterTemplate = true
                        if created {
                            step = .chatIntro
                        }
                    }
                },
                onSkip: {
                    appModel.onboardingState.hasSeenStarterTemplate = true
                    step = .chatIntro
                }
            )
        case .chatIntro:
            ChatIntroStepView(
                onEnterChat: {
                    appModel.finishOnboarding()
                }
            )
        }
    }

    private func syncStep() {
        if !appModel.onboardingState.hasSeenWelcome {
            step = .welcome
        } else if !appModel.onboardingState.hasRequestedReminderPermission {
            step = .remindersPermission
        } else if appModel.remindersAccessGranted && appModel.isReminderStoreEmpty && !appModel.onboardingState.hasSeenStarterTemplate {
            step = .starterTemplate
        } else {
            step = .chatIntro
        }
    }
}

private enum OnboardingStep {
    case welcome
    case remindersPermission
    case starterTemplate
    case chatIntro
}

private struct WelcomeStepView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Text("把提醒事项交给 AIGTD")
                .font(.largeTitle.bold())
            Text("你直接说，App 帮你整理并操作 Apple Reminders。")
                .font(.title3)
            Text("任务仍然留在提醒事项里，这里只负责理解、整理和执行。")
                .foregroundStyle(.secondary)
            Spacer()
            Button("开始使用", action: onContinue)
                .buttonStyle(.borderedProminent)
            Button("了解工作方式") {}
                .buttonStyle(.bordered)
        }
    }
}

private struct ReminderPermissionStepView: View {
    let permissionStatus: EKAuthorizationStatus
    let onAllow: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Text("需要访问提醒事项")
                .font(.largeTitle.bold())
            Text("这样 AIGTD 才能读取、创建和更新你的提醒事项。")
                .font(.title3)
            Text("你的任务数据只保存在 Apple Reminders 中。")
                .foregroundStyle(.secondary)
            statusText
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("允许访问", action: onAllow)
                .buttonStyle(.borderedProminent)
            Button("稍后再说", action: onSkip)
                .buttonStyle(.bordered)
        }
    }

    private var statusText: Text {
        switch permissionStatus {
        case .denied:
            return Text("如果你拒绝了，也可以之后在系统设置里开启。")
        case .restricted:
            return Text("当前设备限制了提醒事项访问，后续某些功能可能不可用。")
        default:
            return Text("允许后，你就能直接通过对话创建和调整提醒事项。")
        }
    }
}

private struct StarterTemplateStepView: View {
    let lists: [String]
    let isCreating: Bool
    let errorMessage: String
    let onUseTemplate: () -> Void
    let onSkip: () -> Void

    private let descriptions: [String: String] = [
        "收集箱": "先把想到的事都放这里",
        "项目": "需要多步推进的事情",
        "下一步行动": "现在就能做的一步",
        "等待中": "正在等别人回复或确认",
        "也许以后": "暂时不做，但先保留下来"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("先给你一套起步列表")
                .font(.largeTitle.bold())
            Text("如果你现在还没有任何提醒事项，可以先用这套结构快速开始。")
                .font(.title3)
            Text("这是一套可选模板，创建前你可以改名、删减或调整顺序。")
                .foregroundStyle(.secondary)

            List(lists, id: \.self) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item).font(.headline)
                    Text(descriptions[item] ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)

            if errorMessage.isEmpty == false {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button("使用这套模板", action: onUseTemplate)
                .buttonStyle(.borderedProminent)
                .disabled(isCreating)
            Button("先跳过", action: onSkip)
                .buttonStyle(.bordered)
                .disabled(isCreating)
            Button("创建前可修改") {}
                .buttonStyle(.plain)
                .disabled(isCreating)

            if isCreating {
                ProgressView("正在创建起步列表…")
                    .padding(.top, 4)
            }
        }
    }
}

private struct ChatIntroStepView: View {
    let onEnterChat: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Text("现在可以开始了")
                .font(.largeTitle.bold())
            Text("直接告诉我你要做什么。")
                .font(.title3)
            Text("你先看看界面、试着说一句话就行。第一次发送时，如果还没配置模型，我会再提醒你去设置。")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Text("示例")
                    .font(.headline)
                ForEach([
                    "明天提醒我给张闯回信",
                    "帮我建一个“报销”列表",
                    "把这条移到“等待中”",
                    "今天我还有什么事"
                ], id: \.self) { item in
                    Text(item)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            Spacer()
            Button("发送消息", action: onEnterChat)
                .buttonStyle(.borderedProminent)
            Button("查看示例") {}
                .buttonStyle(.bordered)
        }
    }
}
