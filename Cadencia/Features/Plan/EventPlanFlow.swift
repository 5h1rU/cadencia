import SwiftUI
import CoreLocation
import CadenciaCore

/// Route → event → preparation → confirmation. All edits remain local until Create plan.
struct EventPlanFlow: View {
    @Environment(AppModel.self) private var model
    let finished: () -> Void
    @State private var draft = EventPlanDraft()
    @State private var step: Step = .course
    @State private var initialized = false
    @State private var importID: UUID?
    @State private var importStatus = GPXImportStatus.preparing
    @State private var importingFileName = ""
    @State private var importTask: Task<Void, Never>?
    @State private var showingImporter = false
    @State private var pendingRoutes: [GPXRoute] = []
    @State private var pendingFile = ""
    @State private var choosingRoute = false
    @State private var importError: String?
    @State private var locating = false
    @State private var locationError: String?
    @State private var geocoder = CLGeocoder()
    @State private var locationRequest = UUID()
    @State private var saving = false

    private var importing: Bool { importID != nil }

    private enum Step: Int, CaseIterable {
        case course, event, preparation, review
        var title: LocalizedStringKey {
            switch self {
            case .course: return "Your route"
            case .event: return "Your event"
            case .preparation: return "Your preparation"
            case .review: return "Review your plan"
            }
        }
    }
    private var canContinue: Bool {
        switch step {
        case .course: return draft.validCourse
        case .event: return draft.validEvent && Day(draft.date) >= model.today
        case .preparation: return draft.validPreparation
        case .review: return draft.validCourse && draft.validEvent && draft.validPreparation && Day(draft.date) >= model.today
        }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Step \(step.rawValue + 1) of 4").font(.subheadline).foregroundStyle(.secondary)
                    ProgressView(value: Double(step.rawValue + 1), total: 4)
                        .accessibilityLabel("Setup progress")
                }
            }
            .listRowBackground(Color.clear)
            switch step {
            case .course: courseSections
            case .event: eventSections
            case .preparation: preparationSections
            case .review: reviewSections
            }
        }
        .id(step)
        .scrollDismissesKeyboard(.interactively)
        .disabled(saving || importing)
        .accessibilityHidden(importing)
        .navigationTitle(step.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(step != .course || saving || importing)
        .toolbar {
            if step != .course {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.left") { step = Step(rawValue: step.rawValue - 1)! }.disabled(saving || importing)
                }
            }
            ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { finished() }.disabled(saving || importing) }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                if step == .review { Task { await create() } }
                else { step = Step(rawValue: step.rawValue + 1)! }
            } label: {
                HStack {
                    if saving { ProgressView().tint(.white) }
                    Text(step == .review ? "Create plan" : "Continue").frame(maxWidth: .infinity)
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue || importing || saving)
            .padding().background(.bar)
        }
        .interactiveDismissDisabled(saving || importing)
        .overlay {
            if importing {
                GPXImportProgressView(fileName: importingFileName, status: importStatus, cancel: cancelImport)
            }
        }
        .sheet(isPresented: $showingImporter) {
            GPXDocumentPicker(picked: { url in
                showingImporter = false
                startImport(url)
            }, cancelled: { showingImporter = false })
        }
        .sheet(isPresented: $choosingRoute) { routePicker }
        .alert("Couldn’t import route", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "") }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            if let availability = model.state.plan?.availability {
                draft.minutesByWeekday = availability.minutesByWeekday
                draft.longRideDay = availability.longRideWeekday
            }
        }
        .onDisappear { geocoder.cancelGeocode(); cancelImport() }
        .task(id: draft.route?.id) {
            if draft.route != nil { await findLocation(reverse: true) }
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--cadencia-preview-event-gpx") {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("route-preview.gpx")
                startImport(url)
            }
            #endif
        }
    }

    @ViewBuilder private var courseSections: some View {
        Section {
            Label("Start with the route", systemImage: "map").font(.headline)
            Text("Import the organizer’s GPX to review the course, or enter the details yourself.")
                .foregroundStyle(.secondary)
            Button { showingImporter = true } label: {
                Label(draft.route == nil ? "Import route GPX" : "Replace GPX", systemImage: "square.and.arrow.down")
            }
            .disabled(importing)
            if draft.route == nil && !draft.manualCourse {
                Button("Enter course manually") { draft.manualCourse = true }
            }
        }
        if let route = draft.route {
            Section {
                EventRoutePreview(route: route)
                if let file = draft.fileName { LabeledContent("Route file", value: file) }
                if !route.name.isEmpty { LabeledContent("Selected route", value: route.name) }
                Button("Remove GPX", role: .destructive) {
                    draft.route = nil; draft.fileName = nil; draft.manualCourse = true
                }
            }
        }
        if draft.route != nil || draft.manualCourse {
            Section {
                EventNumberField("Distance (km)", text: $draft.distance, required: true)
                EventNumberField("Elevation gain (m)", text: $draft.gain)
                DisclosureGroup("Altitude and descent") {
                    EventNumberField("Elevation loss (m)", text: $draft.loss)
                    EventNumberField("Start altitude (m)", text: $draft.startAltitude, signed: true)
                    EventNumberField("Lowest altitude (m)", text: $draft.minAltitude, signed: true)
                    EventNumberField("Highest altitude (m)", text: $draft.maxAltitude, signed: true)
                }
            } header: { Text("Confirm course details") } footer: {
                Text("Elevation gain is how much you climb. Altitude is how high the route is above sea level. Leave unknown values blank.")
            }
            Section("Terrain") {
                Picker("Surface", selection: $draft.surface) {
                    Text("Unknown").tag(EventCourse.Surface?.none)
                    ForEach(EventCourse.Surface.allCases, id: \.self) { Text($0.title).tag(EventCourse.Surface?.some($0)) }
                }
                Picker("Technical difficulty", selection: $draft.technical) {
                    Text("Unknown").tag(EventCourse.TechnicalDifficulty?.none)
                    ForEach(EventCourse.TechnicalDifficulty.allCases, id: \.self) { Text($0.title).tag(EventCourse.TechnicalDifficulty?.some($0)) }
                }
            }
            if let route = draft.route { EventClimbsSection(route: route) }
            if !draft.validCourse {
                Section { Text("Enter a distance above zero and check that the lowest altitude does not exceed the highest. Optional numbers must be valid.").font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private var eventSections: some View {
        Section("Event") {
            TextField("Event name", text: $draft.name).autocorrectionDisabled()
            DatePicker("Date", selection: $draft.date, in: model.today.date()..., displayedComponents: .date)
            Picker("Discipline", selection: $draft.discipline) {
                ForEach(EventDetails.Discipline.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("It's a race", isOn: $draft.isRace)
            Picker("Priority", selection: $draft.priority) {
                Text("A · the one that matters").tag(TrainingEvent.Priority.a)
                Text("B · important").tag(TrainingEvent.Priority.b)
                Text("C · training ride").tag(TrainingEvent.Priority.c)
            }
        }
        Section {
            TextField("City or start location", text: $draft.location).autocorrectionDisabled()
            Button { Task { await findLocation(reverse: false) } } label: {
                if locating { ProgressView("Finding location…") } else { Label("Find location", systemImage: "mappin.and.ellipse") }
            }.disabled(locating || EventPlanDraft.text(draft.location) == nil)
            if let latitude = draft.latitude, let longitude = draft.longitude {
                LabeledContent("Coordinates", value: String(format: "%.4f, %.4f", latitude, longitude))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let locationError { Text(locationError).font(.footnote).foregroundStyle(.secondary) }
            Picker("Event time zone", selection: $draft.timeZoneID) {
                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
            }
            Toggle("I know the start time", isOn: $draft.knowsStartTime)
            if draft.knowsStartTime { DatePicker("Local start time", selection: $draft.startTime, displayedComponents: .hourAndMinute) }
        } header: { Text("Where and when") } footer: {
            Text("Confirm the event location and its local time zone. A GPX timestamp is not the event date or start time.")
        }
    }

    @ViewBuilder private var preparationSections: some View {
        Section("What would success look like?") {
            Picker("Your goal", selection: $draft.goal) {
                ForEach(EventDetails.Goal.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            EventNumberField(draft.goal == .targetTime ? "Target time (hours)" : "Expected duration (hours)", text: $draft.durationHours, required: draft.goal == .targetTime)
            EventNumberField("Cutoff time (hours)", text: $draft.cutoffHours)
            TextField("Anything else about your objective?", text: $draft.objective, axis: .vertical)
        }
        Section {
            EventNumberField("Usual training altitude (m)", text: $draft.usualAltitude, signed: true)
            Toggle("I know my arrival date", isOn: $draft.knowsArrival)
            if draft.knowsArrival { DatePicker("Arrival date", selection: $draft.arrival, in: ...draft.date, displayedComponents: .date) }
            TextField("Experience with similar terrain or altitude", text: $draft.experience, axis: .vertical)
        } header: { Text("Travel and familiarity") } footer: {
            Text("Your usual altitude and arrival date help the coach understand how this event differs from your regular rides.")
        }
        Section {
            DisclosureGroup("Expected conditions (optional)") {
                EventNumberField("Expected temperature (°C)", text: $draft.temperature, signed: true)
                EventNumberField("Expected humidity (%)", text: $draft.humidity)
                TextField("Heat, wind, rain or other conditions", text: $draft.conditions, axis: .vertical)
            }
            TextField("Aid stations, fueling or support", text: $draft.support, axis: .vertical)
            TextField("Access to hills, indoor training or other limits", text: $draft.constraints, axis: .vertical)
        } header: { Text("Other preparation details") } footer: {
            Text("These are your expectations, not a weather forecast. Leave unknown details blank.")
        }
        EventAvailabilityEditor(minutes: $draft.minutesByWeekday, longRideDay: $draft.longRideDay)
        if !draft.validPreparation {
            Section { Text("Check optional numbers, choose at least one training day and keep arrival on or before the event. A target-time goal needs a time.").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var reviewSections: some View {
        Section {
            Text(draft.event.name).font(.title3.bold())
            LabeledContent("Date", value: draft.event.day.date().formatted(date: .long, time: .omitted))
            LabeledContent("Location", value: draft.location)
            LabeledContent("Discipline", value: draft.discipline.title)
            LabeledContent("Priority", value: draft.priority.rawValue.uppercased())
            LabeledContent("Your goal", value: draft.goal.title)
            if let time = draft.event.details?.localStartTime { LabeledContent("Local start time", value: time) }
            LabeledContent("Event time zone", value: draft.timeZoneID.replacingOccurrences(of: "_", with: " "))
        }
        Section("Course") {
            if let route = draft.route { EventRoutePreview(route: route) }
            EventCourseSummary(event: draft.event)
        }
        if let route = draft.route { EventClimbsSection(route: route) }
        Section("Preparation") { EventPreparationSummary(event: draft.event) }
        if let duration = draft.event.details?.expectedDurationMinutes, let cutoff = draft.event.details?.cutoffMinutes, duration > cutoff {
            Section { Label("Your expected duration exceeds the cutoff. Review your objective and the event’s time limit.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
        Section("Availability") {
            ForEach([2, 3, 4, 5, 6, 7, 1].filter { draft.minutesByWeekday[$0] != nil }, id: \.self) { day in
                LabeledContent(Calendar.current.standaloneWeekdaySymbols[day - 1].capitalized,
                               value: Format.minutes(TimeInterval((draft.minutesByWeekday[day] ?? 0) * 60)))
            }
        }
        Section {
            Label("How this shapes your plan", systemImage: "sparkles").font(.headline)
            Text("The coach uses the course’s climbing, altitude, terrain and your objective to guide event-specific preparation. Travel, expected conditions and available training time add context. Daily recovery still sets the ceiling.")
            Text("Future sessions remain provisional. Creating this plan saves it and syncs the coming week to Intervals.icu.")
                .font(.footnote).foregroundStyle(.secondary)
            if draft.route?.hasCompleteElevation == false {
                Text("Some GPX elevations are missing. Confirm any climbing and altitude figures you entered.").foregroundStyle(.orange)
            }
        }
    }

    private var routePicker: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(pendingRoutes.enumerated()), id: \.element.id) { index, route in
                        Button {
                            draft.apply(route, fileName: pendingFile)
                            choosingRoute = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(route.name.isEmpty ? String(localized: "Route \(index + 1)") : route.name).foregroundStyle(.primary)
                                Text("\(route.distanceKm.formatted(.number.precision(.fractionLength(1)))) km").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: { Text("Choose the event route or stage you want to prepare for. Separate routes are not combined.") }
            }
            .navigationTitle("Choose a route").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosingRoute = false } } }
        }
    }

    @MainActor private func startImport(_ url: URL) {
        importTask?.cancel()
        let id = UUID()
        importID = id
        importingFileName = url.lastPathComponent
        importStatus = .preparing
        // UIKit can dismiss its document picker without SwiftUI delivering onDismiss. Selection
        // must start the job itself; otherwise the progress panel can wait with no worker running.
        importTask = Task { await importRoute(url, id: id) }
    }

    @MainActor private func cancelImport() {
        importTask?.cancel()
        importTask = nil
        importID = nil
    }

    @MainActor private func importRoute(_ url: URL, id: UUID) async {
        defer {
            if importID == id { importID = nil; importTask = nil }
        }
        do {
            for try await update in GPXImportService().updates(for: url) {
                guard !Task.isCancelled, importID == id else { return }
                switch update {
                case .progress(let status): importStatus = status
                case .finished(let routes, _):
                    if routes.count == 1 { draft.apply(routes[0], fileName: url.lastPathComponent) }
                    else { pendingRoutes = routes; pendingFile = url.lastPathComponent; choosingRoute = true }
                }
            }
        } catch is CancellationError {
            // Cancelling keeps the previous course and returns to the editable form.
        } catch let error as GPXImporter.ImportError {
            guard !Task.isCancelled, importID == id else { return }
            switch error {
            case .tooLarge, .tooManyPoints: importError = String(localized: "This route is too large. Use a GPX under 20 MB with fewer than 200,000 points.")
            case .noRoute: importError = String(localized: "No usable route was found. Choose a GPX with a track or route containing at least two different points.")
            case .invalidXML, .invalidCoordinate: importError = String(localized: "This GPX is invalid. Export the route again or enter the course manually.")
            }
        } catch {
            guard !Task.isCancelled, importID == id else { return }
            importError = String(localized: "The file couldn’t be read. Save a local copy and try again.")
        }
    }

    @MainActor private func findLocation(reverse: Bool) async {
        geocoder.cancelGeocode()
        let request = UUID(); locationRequest = request
        let originalName = draft.location, originalZone = draft.timeZoneID
        locating = true; locationError = nil
        defer { if locationRequest == request { locating = false } }
        do {
            let placemarks: [CLPlacemark]
            if reverse, let lat = draft.latitude, let lon = draft.longitude {
                placemarks = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon))
            } else { placemarks = try await geocoder.geocodeAddressString(draft.location) }
            guard !Task.isCancelled, locationRequest == request, draft.location == originalName else { return }
            guard let place = placemarks.first else {
                locationError = String(localized: "Location couldn’t be found. Enter the place and confirm its time zone manually.")
                return
            }
            if draft.location == originalName {
                let components = [place.locality, place.administrativeArea, place.country].compactMap { $0 }
                if !components.isEmpty { draft.location = components.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ") }
                if !reverse { draft.latitude = place.location?.coordinate.latitude; draft.longitude = place.location?.coordinate.longitude }
            }
            if draft.timeZoneID == originalZone, let zone = place.timeZone { draft.timeZoneID = zone.identifier }
        } catch {
            if !Task.isCancelled, locationRequest == request {
                locationError = String(localized: "Location couldn’t be found. Enter the place and confirm its time zone manually.")
            }
        }
    }

    @MainActor private func create() async {
        guard canContinue, !saving else { return }
        saving = true
        let request = PlanBuilder.Request(goal: .event, startDay: model.today, endDay: draft.event.day,
                                          event: draft.event, availability: draft.availability, currentCTL: model.latestLoad?.ctl)
        await model.createPlan(request)
        finished()
    }
}

struct EventNumberField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    var required = false
    var signed = false
    init(_ title: LocalizedStringKey, text: Binding<String>, required: Bool = false, signed: Bool = false) {
        self.title = title; _text = text; self.required = required; self.signed = signed
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            TextField(required ? "Required" : "Unknown", text: $text)
                .keyboardType(signed ? .numbersAndPunctuation : .decimalPad)
                .accessibilityLabel(Text(title))
        }.padding(.vertical, 2)
    }
}

private struct EventAvailabilityEditor: View {
    @Binding var minutes: [Int: Int]
    @Binding var longRideDay: Int
    var body: some View {
        Section {
            DisclosureGroup("Training days and time") {
                ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                    Toggle(Calendar.current.standaloneWeekdaySymbols[day - 1].capitalized,
                           isOn: Binding(get: { minutes[day] != nil }, set: { enabled in
                        minutes[day] = enabled ? (day == 1 || day == 7 ? 150 : 60) : nil
                        if minutes[longRideDay] == nil, let next = minutes.keys.sorted().first { longRideDay = next }
                    }))
                    if let value = minutes[day] {
                        Stepper(Format.minutes(TimeInterval(value * 60)),
                                value: Binding(get: { minutes[day] ?? 60 }, set: { minutes[day] = $0 }), in: 15...720, step: 15)
                    }
                }
            }
            if !minutes.isEmpty {
                Picker("Long ride", selection: $longRideDay) {
                    ForEach(minutes.keys.sorted(), id: \.self) { day in Text(Calendar.current.standaloneWeekdaySymbols[day - 1].capitalized).tag(day) }
                }
            }
            LabeledContent("Weekly training time", value: Format.minutes(TimeInterval(minutes.values.reduce(0, +) * 60)))
        } header: { Text("Availability") } footer: { Text("We start with your current plan’s availability when available. Adjust any day before creating the new plan.") }
    }
}

#if DEBUG
/// Isolated local state and no Intervals credential for Simulator interaction checks.
struct EventPlanPreview: View {
    @Environment(AppModel.self) private var model
    @State private var creating = true
    var body: some View {
        NavigationStack {
            if let event = model.state.plan?.event { EventPrepView(event: event) }
        }
        .sheet(isPresented: $creating) { CreatePlanView() }
    }
}
#endif
