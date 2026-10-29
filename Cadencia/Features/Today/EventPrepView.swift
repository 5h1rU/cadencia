import SwiftUI
import CadenciaCore

/// Days to the event, what the last week looks like and why.
struct EventPrepView: View {
    @Environment(AppModel.self) private var model
    let event: TrainingEvent

    private var sessions: [PlannedSession] {
        model.state.plan?.sessions.filter { $0.day >= model.today && $0.day <= event.day }.sorted { $0.day < $1.day } ?? []
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Date", value: Format.day(event.day))
                LabeledContent("In", value: "\(model.today.days(until: event.day)) days")
                if let km = event.distanceKm { LabeledContent("Distance", value: String(format: "%.0f km", km)) }
                LabeledContent("Priority", value: event.priority.rawValue.uppercased())
                if !event.objective.isEmpty { LabeledContent("Objective", value: event.objective) }
            }

            Section {
                ForEach(sessions) { s in
                    SessionRow(session: s, isToday: s.day == model.today)
                }
            } header: {
                Text("Until the event")
            } footer: {
                Text("Two days out intensity stops; the day before is a short opener so the legs arrive sharp, not tired.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(event.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One planned session in a list: day, kind, duration, status.
struct SessionRow: View {
    let session: PlannedSession
    var isToday = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(session.day.date().formatted(.dateTime.weekday(.abbreviated))).font(.caption2).foregroundStyle(.secondary).textCase(.uppercase)
                Text("\(session.day.day)").font(.headline.monospacedDigit())
            }
            .frame(width: 36)
            Image(systemName: session.kind.symbol).foregroundStyle(session.kind.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).fontWeight(isToday ? .semibold : .regular)
                HStack(spacing: 6) {
                    Text(session.kind.title)
                    if session.kind != .rest { Text("·"); Text(Format.minutes(TimeInterval(session.targetMinutes * 60))) }
                    if let load = session.targetLoad { Text("·"); Text("\(load) TSS") }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer()
            statusIcon
        }
        .opacity(session.status == .skipped ? 0.5 : 1)
    }

    @ViewBuilder private var statusIcon: some View {
        switch session.status {
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .generated: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .provisional: EmptyView()
        }
    }
}

#Preview {
    NavigationStack { EventPrepView(event: PreviewData.plan.event!) }.environment(PreviewData.model())
}
