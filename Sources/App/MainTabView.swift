@preconcurrency import EventKit
import Foundation
import Observation
import SwiftUI
import UIKit

struct MainTabView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var welcomeStore = XiaomanWelcomeStore()
    @StateObject private var voiceInteraction = VoiceInteractionState()
    @State private var showsSettings = false
    @State private var reminderRefreshTask: Task<Void, Never>?
#if DEBUG || INTERNAL
    @State private var showsDeveloperSettings = false
#endif

    var body: some View {
        ZStack {
            TabView(selection: Binding(
                get: { publicTabSelection },
                set: { appModel.selectedTab = $0 }
            )) {
                NavigationStack {
                    ChatHomeView(voiceInteraction: voiceInteraction)
                        .environment(welcomeStore)
                        .toolbar { settingsToolbar }
                }
                .tag(AppTab.chat)
                .tabItem {
                    Label("AIGTD", systemImage: "message.fill")
                }

                NavigationStack {
                    RemindersOverviewView()
                        .toolbar { settingsToolbar }
                }
                .tag(AppTab.reminders)
                .tabItem {
                    Label("任务", systemImage: "checklist")
                }
            }
            .accessibilityHidden(voiceInteraction.showsCaptureOverlay)

            if voiceInteraction.showsCaptureOverlay {
                VoiceCaptureOverlay(state: voiceInteraction)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .animation(.easeOut(duration: 0.16), value: voiceInteraction.showsCaptureOverlay)
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                PublicSettingsView()
            }
        }
#if DEBUG || INTERNAL
        .sheet(isPresented: $showsDeveloperSettings) {
            NavigationStack {
                AgentHomeView()
            }
        }
#endif
        .onChange(of: appModel.selectedTab) { _, selectedTab in
            if selectedTab == .reminders {
                scheduleReminderRefresh(delay: .zero)
            }
            guard selectedTab == .agent else { return }
            appModel.selectedTab = .chat
#if DEBUG || INTERNAL
            showsDeveloperSettings = true
#else
            showsSettings = true
#endif
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            scheduleReminderRefresh(delay: .zero)
        }
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            scheduleReminderRefresh(delay: .milliseconds(250))
        }
        .onChange(of: voiceInteraction.phase) { _, phase in
            announceVoicePhaseIfNeeded(phase)
        }
        .onDisappear {
            reminderRefreshTask?.cancel()
        }
    }

    private var publicTabSelection: AppTab {
        appModel.selectedTab == .reminders ? .reminders : .chat
    }

    private func scheduleReminderRefresh(delay: Duration) {
        reminderRefreshTask?.cancel()
        reminderRefreshTask = Task { @MainActor in
            if delay != .zero {
                try? await Task.sleep(for: delay)
            }
            guard Task.isCancelled == false else { return }
            await appModel.refreshReminderLists()
        }
    }

    private func announceVoicePhaseIfNeeded(_ phase: VoiceInteractionState.Phase) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let message: String? = switch phase {
        case .recording: "已开始录音，上滑取消，松手转成文字。"
        case .cancelling: "已进入取消区域，松手取消语音输入。"
        case .finalizing: "录音结束，正在转成文字。"
        case .failed: voiceInteraction.noticeText
        case .idle, .requestingPermission, .starting, .draftReady: nil
        }
        if let message {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("设置")
        }
    }
}

@MainActor
@Observable
final class XiaomanWelcomeStore {
    static let welcomeMessage = "你好，我是小满，你的 AIGTD 事务助理。你可以直接告诉我想记下、调整或整理什么。"

    private let defaults: UserDefaults
    private let storageKey: String
    private(set) var hasPresentedWelcome: Bool

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "aigtd.xiaoman.welcome.presented.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        hasPresentedWelcome = defaults.bool(forKey: storageKey)
    }

    var shouldPresentWelcome: Bool {
        hasPresentedWelcome == false
    }

    func pendingWelcomeMessage() -> String? {
        shouldPresentWelcome ? Self.welcomeMessage : nil
    }

    func markWelcomePresented() {
        guard shouldPresentWelcome else { return }
        hasPresentedWelcome = true
        defaults.set(true, forKey: storageKey)
    }

    /// Kept as a convenience for callers that do not need transactional storage.
    func consumeWelcomeMessage() -> String? {
        guard let message = pendingWelcomeMessage() else { return nil }
        markWelcomePresented()
        return message
    }
}

#Preview {
    MainTabView()
        .environment(AppModel.previewFinished)
}
