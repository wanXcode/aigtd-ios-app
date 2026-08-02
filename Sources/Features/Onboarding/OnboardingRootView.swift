import EventKit
import SwiftUI
import UIKit

struct OnboardingRootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
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
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active, step == .remindersPermission else { return }
            Task {
                await appModel.refreshReminderPermission()
            }
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
                        if appModel.remindersAccessGranted {
                            appModel.finishOnboarding()
                        }
                    }
                },
                onContinue: {
                    appModel.onboardingState.hasRequestedReminderPermission = true
                    appModel.finishOnboarding()
                },
                onOpenSettings: {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                },
                onSkip: {
                    appModel.onboardingState.hasRequestedReminderPermission = true
                    appModel.finishOnboarding()
                }
            )
        }
    }

    private func syncStep() {
        if !appModel.onboardingState.hasSeenWelcome {
            step = .welcome
        } else {
            step = .remindersPermission
        }
    }
}

private enum OnboardingStep: Equatable {
    case welcome
    case remindersPermission
}

private struct WelcomeStepView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.message.fill")
                .font(.system(size: 58))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text("认识小满")
                .font(.largeTitle.bold())
            Text("直接说出你想记下、调整或整理的事情，小满会帮你连接 Apple Reminders。")
                .font(.title3)
            Text("任务始终保存在 Apple Reminders 中，AIGTD 不会建立另一套任务数据库。")
                .foregroundStyle(.secondary)
            Spacer()
            Button("继续", action: onContinue)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct ReminderPermissionStepView: View {
    let permissionStatus: EKAuthorizationStatus
    let onAllow: () -> Void
    let onContinue: () -> Void
    let onOpenSettings: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Image(systemName: "checklist")
                .font(.system(size: 54))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text("连接提醒事项")
                .font(.largeTitle.bold())
            Text("允许访问后，小满才能查看、创建和调整你的 Apple Reminders 任务。")
                .font(.title3)
            Text("麦克风权限不会在这里请求，第一次使用语音时系统才会询问。")
                .foregroundStyle(.secondary)
            statusText
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            primaryButton
            Button("暂不连接", action: onSkip)
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch permissionStatus {
        case .fullAccess, .writeOnly, .authorized:
            Button("进入 AIGTD", action: onContinue)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .denied, .restricted:
            Button("前往系统设置", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .notDetermined:
            Button("允许并继续", action: onAllow)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        @unknown default:
            Button("进入 AIGTD", action: onContinue)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private var statusText: Text {
        switch permissionStatus {
        case .denied:
            return Text("你可以前往系统设置重新开启，或者选择暂不连接。")
        case .restricted:
            return Text("当前设备限制了提醒事项访问，任务读写暂时不可用。")
        case .fullAccess, .writeOnly, .authorized:
            return Text("提醒事项已经连接，可以进入 AIGTD。")
        default:
            return Text("AIGTD 只会在你发出明确请求后操作任务。")
        }
    }
}
