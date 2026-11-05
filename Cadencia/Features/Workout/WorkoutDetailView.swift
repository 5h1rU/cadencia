import SwiftUI
import CadenciaCore

/// A structured session block by block, with the reasoning that produced it.
struct WorkoutDetailView: View {
    @Environment(AppModel.self) private var model
    let workout: Workout
    let ftp: Int
    /// The route and outdoor screens are pushed from the list, not from their rows: the rows go away once today
    /// is completed or re-prescribed (a Refresh after the ride, a route import that asks the coach again), and a
    /// link leaving the screen would pop the screen it opened.
    @State private var showsRoute = false
    @State private var showsOutdoor = false

    private var ceilingWatts: Int? { workout.intensityCeiling.map { Int(($0 * Double(ftp)).rounded()) } }

    var body: some View {
        let rows = self.rows
        List {
            InfoSection {
                VStack(alignment: .leading, spacing: 12) {
                    WorkoutProfileView(workout: workout, ftp: ftp, ceilingWatts: ceilingWatts)
                        .frame(height: 200)
                    // One row while every stat fits on one line, otherwise stacked. In the row each column is at
                    // least its stat's natural width, so columns stay equal where they can and nothing wraps.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 8) {
                            Group { stats }
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        VStack(alignment: .leading, spacing: 8) { stats }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Workout profile")
            } information: {
                Text("Dashed line: FTP \(ftp) W. Red line: today's ceiling; ERG never pushes above it. Colors are power zones.")
            }

            Section("Why this session") {
                Text(workout.rationale)
            }

            if model.todayWorkout?.id == workout.id, !model.isTodayWorkoutCompleted,
               workout.kind != .rest, workout.kind != .strength, !workout.steps.isEmpty {
                Section {
                    Button { showsRoute = true } label: {
                        Label(model.plannedToday?.route == nil ? "Add a route (optional)" : "Review planned route", systemImage: "map")
                    }
                    Button { showsOutdoor = true } label: {
                        Label("Ride outdoors", systemImage: "bicycle")
                    }
                }
            }

            InfoSection(hasInformation: workout.steps.contains(where: \.isRamp)) {
                // The table where it fits untruncated; otherwise one block per row.
                ViewThatFits(in: .horizontal) {
                    blocksGrid(rows)
                    blocksList(rows)
                }
            } header: {
                Text("Blocks")
            } information: {
                if workout.steps.contains(where: \.isRamp) {
                    Text("Ramps show start→end watts; the trainer moves the target every second between them.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showsRoute) { PlannedRideRouteView(day: model.today) }
        // OutdoorWorkoutView shows the completed state and the debrief link itself, so it stays after the ride syncs.
        .navigationDestination(isPresented: $showsOutdoor) { OutdoorWorkoutView() }
    }

    private struct Row { let step: WorkoutStep; let start: TimeInterval }

    private var rows: [Row] {
        var t: TimeInterval = 0
        return workout.steps.map { step in
            defer { t += step.duration }
            return Row(step: step, start: t)
        }
    }

    @ViewBuilder private var stats: some View {
        stat("Duration", Format.minutes(workout.totalDuration))
        stat("Load", "\(workout.estimatedLoad) TSS")
        stat("IF", String(format: "%.2f", workout.averageIntensity))
        stat("Work", "\(Int((workout.averageIntensity * Double(ftp) * workout.totalDuration / 1000).rounded())) kJ")
        if let c = ceilingWatts { stat("Ceiling", "\(c) W") }
    }

    private func blocksGrid(_ rows: [Row]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("At").gridColumnAlignment(.trailing)
                Text("Block")
                Text("Length").gridColumnAlignment(.trailing)
                Text("Target").gridColumnAlignment(.trailing)
                Text("% FTP").gridColumnAlignment(.trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(Array(rows.enumerated()), id: \.element.step.id) { i, row in
                GridRow {
                    Text(Format.clock(row.start)).monospacedDigit().foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Circle().fill(Zone.color(for: row.step.startIntensity)).frame(width: 8, height: 8)
                            Text(row.step.name)
                        }
                        HStack(spacing: 4) {
                            Text(Zone.name(for: (row.step.startIntensity + row.step.endIntensity) / 2))
                            if let rpm = row.step.cadenceRPM { Text("· \(rpm) rpm") }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(Format.minutes(row.step.duration)).monospacedDigit()
                    Text(targetText(row.step)).monospacedDigit()
                    Text(percentText(row.step)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.subheadline)
                if i < rows.count - 1 { Divider() }
            }
        }
    }

    /// The same blocks without columns, for widths where the table would truncate names and targets.
    private func blocksList(_ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.element.step.id) { i, row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(Zone.color(for: row.step.startIntensity)).frame(width: 8, height: 8)
                        Text(row.step.name)
                    }
                    HStack(spacing: 4) {
                        Text(Zone.name(for: (row.step.startIntensity + row.step.endIntensity) / 2))
                        if let rpm = row.step.cadenceRPM { Text("· \(rpm) rpm") }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    Text(verbatim: "\(Format.clock(row.start)) · \(Format.minutes(row.step.duration)) · \(targetText(row.step)) · \(percentText(row.step)) % FTP")
                        .monospacedDigit()
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                if i < rows.count - 1 { Divider() }
            }
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func watts(_ i: Double) -> Int { Int((i * Double(ftp)).rounded()) }

    private func targetText(_ step: WorkoutStep) -> String {
        step.isRamp ? "\(watts(step.startIntensity))→\(watts(step.endIntensity)) W" : "\(watts(step.startIntensity)) W"
    }

    private func percentText(_ step: WorkoutStep) -> String {
        let a = Int((step.startIntensity * 100).rounded()), b = Int((step.endIntensity * 100).rounded())
        return step.isRamp ? "\(a)→\(b)" : "\(a)"
    }
}

/// Today's workout as Home and Plan push it, by value: it reads the live prescription, so the screen (and Ride
/// outdoors or a route opened from it) stays when the row that opened it changes, as when a sync completes the
/// day or the coach prescribes again. It keeps the workout after completion; switching to the debrief would pop
/// the screens pushed from here, and those show the completed state themselves.
struct TodayWorkoutDestination: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let workout = model.todayWorkout, let ftp = model.workingFTP {
            let outdoor = model.todayRideLocation == .outdoor
            WorkoutDetailView(workout: outdoor ? (model.outdoorWorkout?.workout ?? workout) : workout,
                              ftp: outdoor ? (model.outdoorFTP ?? ftp) : ftp)
        } else {
            // A new day, or a new plan, until the coach decides.
            Group {
                if model.coachThinking {
                    ProgressView("The coach is reading your data…")
                } else {
                    ContentUnavailableView("No workout yet", systemImage: "bicycle",
                                           description: Text("Ask the coach for today's cycling session first."))
                }
            }
            .navigationTitle("Today's workout")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    NavigationStack { WorkoutDetailView(workout: PreviewData.state.today!.workout, ftp: 240) }
}
