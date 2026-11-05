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
                content.modifier(ResumeSync(isStarting: isStarting))
            }
            #else
            content.modifier(ResumeSync(isStarting: isStarting))
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
            await model.start()
            isStarting = false
        }
    }

    /// Saved training is usable at once, so only an account's first sync shows the loading screen.
    /// `isStarting` comes first: once it clears, this view stops observing `model.state`.
    @ViewBuilder private var content: some View {
        if isStarting, model.isSignedIn, model.state.lastSyncAt == nil {
            LoadingView { isStarting = false }
        } else {
            RootView()
                // The loading screen never returns, not even after signing out and back in.
                .onAppear { isStarting = false }
        }
    }
}

/// Syncs again when the app comes back from the background on a new day. It is attached only to the live
/// content: the DEBUG previews (which must not touch the live account) never get it, and only this modifier,
/// not StartupView's body, which builds the preview models, re-runs on every scene-phase change.
private struct ResumeSync: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false
    /// True while the first-sync screen is up; that screen owns the launch sync.
    let isStarting: Bool

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            // Only a real return from the background counts, not Control Center or a notification pull. Cold
            // launch never passes through .background, and a resume during the launch sync joins that sync.
            if phase == .background { wasInBackground = true; return }
            guard phase == .active, wasInBackground else { return }
            wasInBackground = false
            // A resumed app keeps yesterday's Today until something syncs.
            guard !isStarting, model.isSignedIn,
                  !(model.state.lastSyncAt.map { Calendar.current.isDateInToday($0) } ?? false) else { return }
            Task { await model.refresh() }
        }
    }
}
