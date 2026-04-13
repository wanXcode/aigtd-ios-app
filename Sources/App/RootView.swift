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
        .preferredColorScheme(.light)
        .task {
            AIGTDRemindersApp.mark("root_view_task_begin")
            await appModel.bootstrapAfterLaunch()
            AIGTDRemindersApp.mark("root_view_task_end")
        }
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}
