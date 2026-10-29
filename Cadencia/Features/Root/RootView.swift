import SwiftUI
import CadenciaCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Screen = .today

    enum Screen: Hashable { case today, coach, plan, settings }

    var body: some View {
        if model.isSignedIn {
            TabView(selection: $tab) {
                Tab("Today", systemImage: "sun.max", value: .today) { TodayView() }
                Tab("Coach", systemImage: "waveform.and.mic", value: .coach) { CoachView() }
                Tab("Plan", systemImage: "calendar", value: .plan) { PlanView() }
                Tab("Settings", systemImage: "gearshape", value: .settings) { SettingsView() }
            }
        } else {
            SignInView()
        }
    }
}

#Preview("Signed in") {
    RootView().environment(PreviewData.model())
}

#Preview("Signed out") {
    RootView().environment(PreviewData.model(signedIn: false))
}
