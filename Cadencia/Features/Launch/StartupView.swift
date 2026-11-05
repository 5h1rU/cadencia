import SwiftUI

struct StartupView: View {
    @Environment(AppModel.self) private var model
    @State private var isStarting = true

    var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--cadencia-preview-consultation") {
                PlanConsultationPreview()
            } else if ProcessInfo.processInfo.arguments.contains("--cadencia-preview-zones") {
                RideZoneLayoutPreview()
            } else if ProcessInfo.processInfo.arguments.contains("--cadencia-preview-ride-hud") {
                RideHUDPreview()
            } else if ProcessInfo.processInfo.arguments.contains("--cadencia-preview-ride-routes") {
                RideRoutesFeaturePreview()
            } else if ProcessInfo.processInfo.arguments.contains("--cadencia-preview-gpx-progress") {
                GPXImportProgressPreview()
            } else if ProcessInfo.processInfo.arguments.contains("--cadencia-preview-home") {
                RootView().environment(PreviewData.homeModel())
            } else if ProcessInfo.processInfo.arguments.contains("--cadencia-preview-event") {
                EventPlanPreview().environment(PreviewData.model(signedIn: false))
            } else if ProcessInfo.processInfo.arguments.contains("--cadencia-preview-completed") {
                RootView().environment(PreviewData.completedModel())
            } else if ProcessInfo.processInfo.arguments.contains("--cadencia-preview-outdoor") {
                NavigationStack { OutdoorWorkoutView() }
                    .environment(PreviewData.model(signedIn: false))
            } else if ProcessInfo.processInfo.arguments.contains("--cadencia-preview-loading") {
                LoadingView(onContinue: {})
            } else {
                content
            }
            #else
            content
            #endif
        }
        .task {
            #if DEBUG
            guard !ProcessInfo.processInfo.arguments.contains("--cadencia-preview-consultation") else { return }
            guard !ProcessInfo.processInfo.arguments.contains("--cadencia-preview-zones") else { return }
            // Show the loading design without network calls, permissions, or account changes.
            guard !ProcessInfo.processInfo.arguments.contains("--cadencia-preview-ride-hud") else { return }
            guard !ProcessInfo.processInfo.arguments.contains("--cadencia-preview-ride-routes") else { return }
            guard !ProcessInfo.processInfo.arguments.contains("--cadencia-preview-gpx-progress") else { return }
            guard !ProcessInfo.processInfo.arguments.contains("--cadencia-preview-home") else { return }
            guard !ProcessInfo.processInfo.arguments.contains("--cadencia-preview-event") else { return }
            guard !ProcessInfo.processInfo.arguments.contains("--cadencia-preview-loading") else { return }
            guard !ProcessInfo.processInfo.arguments.contains("--cadencia-preview-outdoor") else { return }
            guard !ProcessInfo.processInfo.arguments.contains("--cadencia-preview-completed") else { return }
            #endif
            // Saved training is usable immediately. Only an account's first sync needs this screen.
            if !model.isSignedIn || model.state.lastSyncAt != nil { isStarting = false }
            await model.start()
            isStarting = false
        }
    }

    @ViewBuilder private var content: some View {
        if isStarting {
            LoadingView { isStarting = false }
        } else {
            RootView()
        }
    }
}
