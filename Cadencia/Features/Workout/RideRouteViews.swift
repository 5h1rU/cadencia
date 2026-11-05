import SwiftUI
import CadenciaCore

struct GPXRouteImportResult {
    let route: GPXRoute
    let source: Data
    let fileName: String
    let index: Int
}

/// Shared Files handoff with real import progress, cancellation, and multi-route selection.
struct RideRouteImportSheet: View {
    let selected: (GPXRouteImportResult) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picking = true
    @State private var routes: [GPXRoute] = []
    @State private var source = Data()
    @State private var fileName = ""
    @State private var status = GPXImportStatus.preparing
    @State private var importID: UUID?
    @State private var worker: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if routes.isEmpty {
                    Section {
                        Text("Choose a GPX to analyze its distance, elevation and climbs.")
                        Button("Choose GPX", systemImage: "folder") { picking = true }
                    }
                } else {
                    Section {
                        ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
                            Button { accept(index) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(route.name.isEmpty ? String(localized: "Route \(index + 1)") : route.name).foregroundStyle(.primary)
                                    Text(ClimbFormat.km(route.distanceKm)).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } footer: { Text("Choose one route. Other routes in the file stay separate.") }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) } }
            }
            .disabled(importID != nil).accessibilityHidden(importID != nil)
            .navigationTitle("Import route GPX").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel(); dismiss() } } }
            .overlay { if importID != nil { GPXImportProgressView(fileName: fileName, status: status, cancel: cancel) } }
            .sheet(isPresented: $picking) {
                GPXDocumentPicker(picked: { url in picking = false; start(url) }, cancelled: { picking = false })
            }
            .interactiveDismissDisabled(importID != nil)
            .onDisappear { cancel() }
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--cadencia-preview-ride-route-gpx") {
                    picking = false
                    start(FileManager.default.temporaryDirectory.appendingPathComponent("route-preview.gpx"))
                }
                #endif
            }
        }
    }
    private func cancel() { worker?.cancel(); worker = nil; importID = nil }
    private func start(_ url: URL) {
        cancel(); let id = UUID(); importID = id; fileName = url.lastPathComponent; status = .preparing; error = nil
        worker = Task {
            defer { if importID == id { importID = nil; worker = nil } }
            do {
                for try await update in GPXImportService().updates(for: url) {
                    guard !Task.isCancelled, importID == id else { return }
                    switch update {
                    case .progress(let value): status = value
                    case .finished(let values, let data):
                        routes = values; source = data
                        if values.count == 1 { try await save(0) }
                    }
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = String(localized: "Couldn’t import this GPX. Choose a valid route under 20 MB and try again.") } }
        }
    }
    private func accept(_ index: Int) {
        let id = UUID(); importID = id; status = .init(stage: .ready, fractionCompleted: 1)
        worker = Task {
            defer { if importID == id { importID = nil; worker = nil } }
            do { try await save(index) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func save(_ index: Int) async throws {
        try Task.checkCancellation()
        try await selected(.init(route: routes[index], source: source, fileName: fileName, index: index))
        dismiss()
    }
}

struct PlannedRideRouteView: View {
    @Environment(AppModel.self) private var model
    @State private var date: Date
    @State private var minutes = 90
    let chooseDate: Bool
    @State private var importing = false
    @State private var exporting = false
    @State private var exportURL: URL?
    @State private var garminFile: GPXShareFile?
    @State private var error: String?
    @State private var confirmRemoveRoute = false
    private var day: Day { Day(date) }
    private var session: PlannedSession? { model.state.session(on: day) }
    private var attachment: AppState.RideRoutePlan? { model.state.routePlan(on: day) }
    private var editable: Bool {
        day >= model.today && !model.state.isWorkoutCompleted(on: day) &&
        (session.map { $0.kind != .rest && $0.kind != .strength && $0.status != .skipped } ?? true)
    }
    init(day: Day, chooseDate: Bool = false) { _date = State(initialValue: day.date()); self.chooseDate = chooseDate }

    var body: some View {
        List {
            Section {
                if chooseDate {
                    DatePicker("Ride date", selection: $date, in: model.today.date()..., displayedComponents: .date)
                } else { LabeledContent("Date", value: Format.day(day)) }
                if let session { Text(session.title).font(.headline) }
                else { Stepper("\(minutes) minutes", value: $minutes, in: 15...720, step: 15) }
                if editable {
                    Button { importing = true } label: { Label(session?.route == nil ? "Import route GPX" : "Replace GPX", systemImage: "square.and.arrow.down") }
                }
            } footer: {
                Text("A route is optional. Ride freely without one, or attach a course to this day before leaving. Recovery still sets your training limits.")
            }
            if let route = attachment?.route {
                Section("Planned route") {
                    EventRoutePreview(route: route, context: .plannedRide)
                    RideRouteMetrics(route: route)
                    if let name = attachment?.fileName { LabeledContent("Route file", value: name) }
                    Button {
                        guard !exporting else { return }
                        exporting = true; error = nil
                        let exportDay = day
                        Task {
                            defer { exporting = false }
                            do {
                                let url = try await model.exportRideRoute(on: exportDay)
                                if day == exportDay {
                                    exportURL = url
                                    garminFile = GPXShareFile(url: url)
                                }
                            }
                            catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        HStack {
                            Label("Send to Garmin Connect", systemImage: "arrow.up.forward.app")
                            if exporting { Spacer(); ProgressView().accessibilityLabel("Preparing file…") }
                        }
                    }
                    .disabled(exporting)
                    if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                    Text("Choose Garmin Connect in the share menu (More if needed). Choose a cycling course type, save it, then use Send to Device and sync your Edge.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("Garmin course import help", destination: URL(string: "https://support.garmin.com/en-GB/?faq=wKuZXCaZRP4mWPX5aRz5h5")!)
                        .font(.footnote)
                    if let exportURL { ShareLink(item: exportURL) { Label("Share route GPX", systemImage: "square.and.arrow.up") } }
                    if day >= model.today, !model.state.isWorkoutCompleted(on: day) { Button("Remove GPX", role: .destructive) { confirmRemoveRoute = true } }
                }
                EventClimbsSection(route: route)
                Section {
                    Text("The route GPX is for navigation. Send the structured workout separately using Ride outdoors. Sharing a route does not confirm it reached your bike computer.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if !editable {
                Section { Text("Choose an upcoming cycling session to attach a planned route.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Planned route").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $importing) {
            RideRouteImportSheet { result in
                try await model.attachRideRoute(result.route, source: result.source, fileName: result.fileName,
                                                sourceIndex: result.index, day: day, minutes: minutes)
            }
        }
        .sheet(item: $garminFile) { file in
            GPXShareSheet(file: file.url) { message in
                garminFile = nil
                if let message { error = message }
            }
            .presentationDetents([.medium, .large])
        }
        // Removing deletes Cadencia's copy of the GPX; only a new import brings the route back.
        .confirmationDialog("Remove this route?", isPresented: $confirmRemoveRoute, titleVisibility: .visible) {
            Button("Remove GPX", role: .destructive) { model.removeRideRoute(on: day) }
        } message: {
            Text("Your session stays planned. To use this route later, import its GPX again.")
        }
        .onChange(of: attachment?.route.id) { _, _ in exportURL = nil; error = nil }
    }
}

struct RideRouteMetrics: View {
    let route: GPXRoute
    var body: some View {
        LabeledContent("Distance", value: ClimbFormat.km(route.distanceKm))
        if let gain = route.elevationGainM { LabeledContent("Elevation gain", value: ClimbFormat.meters(gain)) }
        if let altitude = route.maxAltitudeM { LabeledContent("Highest altitude", value: ClimbFormat.meters(altitude)) }
    }
}

struct RecordedRideRouteSections: View {
    @Environment(AppModel.self) private var model
    let ride: RideRecording
    @State private var importing = false
    var body: some View {
        Section("Recorded route") {
            if let route = ride.recordedRoute {
                EventRoutePreview(route: route, context: .recordedRide)
                RideRouteMetrics(route: route)
            } else {
                if model.rideRouteStatus[ride.id] == .loading { ProgressView("Loading recorded route…") }
                else {
                    Text("Your recorded GPS route appears here after the activity syncs. A planned route is not required.")
                        .foregroundStyle(.secondary)
                    if case .failed(let message) = model.rideRouteStatus[ride.id] { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    Button("Retry recorded route", systemImage: "arrow.clockwise") { Task { await model.loadRideRoute(ride.id, retry: true) } }
                    Button("Import recorded GPX", systemImage: "square.and.arrow.down") { importing = true }
                }
            }
        }
        .sheet(isPresented: $importing) { RideRouteImportSheet { try model.attachRecordedRoute($0.route, to: ride.id) } }
        if let route = ride.recordedRoute { EventClimbsSection(route: route) }
        if let planned = ride.plannedRoute {
            Section("Planned course") {
                NavigationLink { List { Section { EventRoutePreview(route: planned, context: .plannedRide); RideRouteMetrics(route: planned) }; EventClimbsSection(route: planned) }.navigationTitle("Planned course") } label: {
                    Label("Review planned course", systemImage: "map")
                }
                Text("Saved before the ride. The recorded route above shows where you actually rode.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct RideHistoryView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            if model.state.rideIndex.isEmpty { ContentUnavailableView("No rides yet", systemImage: "bicycle", description: Text("Refresh after your bike computer syncs to Intervals.icu.")) }
            ForEach(model.state.rideIndex.sorted { $0.startedAt > $1.startedAt }) { ride in
                NavigationLink { RideDebriefView(rideID: ride.id) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(ride.name).font(.headline)
                        Text(ride.startedAt, format: .dateTime.day().month(.abbreviated).year()).font(.subheadline).foregroundStyle(.secondary)
                        Text(Format.minutes(ride.duration)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Ride history")
        .refreshable { await model.refresh() }
    }
}

#if DEBUG
struct RideRoutesFeaturePreview: View {
    @State private var model = makeModel()
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Plan a route") { PlannedRideRouteView(day: model.today, chooseDate: true) }
                NavigationLink("Ride history") { RideHistoryView() }
                NavigationLink("Plan") { PlanView() }
            }.navigationTitle("Ride routes")
        }.environment(model)
    }
    @MainActor private static func makeModel() -> AppModel {
        var state = PreviewData.state
        state.settings.llmEnabled = false; state.settings.readHealth = false
        let store = JSONStore.temporary(), startedAt = PreviewData.today.adding(days: -1).date()
        let activity = ActivitySummary(id: "preview-free-ride", name: "Free outdoor ride", type: "Ride", startDateLocal: startedAt, movingTime: 3_600)
        var ride = RideRecording(athleteID: state.athlete?.id ?? "0", workout: Workout(name: activity.name, kind: .endurance, steps: []),
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(3_600), sourceActivity: activity, ftpUsed: 240)
        if !ProcessInfo.processInfo.arguments.contains("--cadencia-preview-ride-no-gps"),
           let data = try? Data(contentsOf: FileManager.default.temporaryDirectory.appendingPathComponent("route-preview.gpx")) {
            ride.recordedRoute = try? GPXImporter().parse(data, combineTracks: true).first
        }
        try? store.save(ride, at: "rides/\(ride.id.uuidString).json")
        state.rideIndex = [.init(id: ride.id, name: activity.name, kind: .endurance, startedAt: startedAt, duration: 3_600)]
        struct Offline: HTTPTransport { func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw HTTPError.invalidResponse } }
        return AppModel(state: state, credential: nil, store: store, keychain: KeychainStore(service: "preview.ride.routes"), transport: Offline())
    }
}
#endif
