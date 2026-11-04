import SwiftUI
import CadenciaCore

/// A day in the coach's outlook. Future sessions remain intentions until the daily prescription.
struct PlannedDayView: View {
    @Environment(AppModel.self) private var model
    let day: DailyPrescription.DayOutlook

    /// An outlook can be newer than the plan; only supplement it with matching session details.
    private var session: PlannedSession? {
        guard let session = model.state.session(on: day.day), session.kind == day.kind,
              session.targetMinutes == day.minutes else { return nil }
        return session
    }

    private var note: String? {
        for candidate in [day.note, session?.note] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        return nil
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(Format.day(day.day)).font(.subheadline).foregroundStyle(.secondary)
                    Label(day.kind.title, systemImage: day.kind.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(day.kind.tint)
                    Text(day.title).font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)

                if day.kind != .rest {
                    LabeledContent("Duration", value: day.minutes > 0
                                   ? Format.minutes(TimeInterval(day.minutes * 60))
                                   : String(localized: "Time TBD"))
                    if let load = session?.targetLoad {
                        LabeledContent("Load", value: "\(load) TSS")
                    }
                }
                if session?.isPriority == true {
                    Label("Priority session", systemImage: "star")
                        .foregroundStyle(.secondary)
                }
            }

            if let note {
                Section("Coach's note") { Text(note) }
            }

            if day.kind != .rest, day.kind != .strength, day.day >= model.today {
                Section {
                    NavigationLink { PlannedRideRouteView(day: day.day) } label: {
                        Label(model.state.session(on: day.day)?.route == nil ? "Add a route (optional)" : "Review planned route", systemImage: "map")
                    }
                }
            }

            if day.kind == .rest {
                Section("Recovery") {
                    Text("No ride planned. Take the day to recover before your next session.")
                }
            }

            if day.day > model.today {
                Section {
                    Text("Only today is a fixed workout; the rest adapts to recovery.")
                        .foregroundStyle(.secondary)
                }
            } else if day.day == model.today, let workout = model.todayWorkout, !workout.rationale.isEmpty {
                Section("Why this session") { Text(workout.rationale) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(day.day == model.today ? String(localized: "Today") : Format.shortDay(day.day))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        PlannedDayView(day: PreviewData.state.today!.ai!.week[1])
    }
    .environment(PreviewData.model())
}
