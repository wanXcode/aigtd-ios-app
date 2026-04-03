import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if appModel.onboardingState.isFinished {
                MainTabView()
            } else {
                OnboardingRootView()
            }
        }
        .task {
            await appModel.refreshReminderPermission()
        }
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}
