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
                LabeledContent("Date", value: event.day.date().formatted(date: .long, time: .omitted))
                LabeledContent("In", value: "\(model.today.days(until: event.day)) days")
                LabeledContent("Priority", value: event.priority.rawValue.uppercased())
                if let location = event.details?.locationName { LabeledContent("Location", value: location) }
                if let time = event.details?.localStartTime { LabeledContent("Local start time", value: time) }
                if let zone = event.details?.timeZoneIdentifier { LabeledContent("Event time zone", value: zone.replacingOccurrences(of: "_", with: " ")) }
                if let discipline = event.details?.discipline { LabeledContent("Discipline", value: discipline.title) }
                if let goal = event.details?.goal { LabeledContent("Your goal", value: goal.title) }
            }

            Section("Course") {
                if let route = event.course?.route { EventRoutePreview(route: route) }
                EventCourseSummary(event: event)
            }
            if let route = event.course?.route { EventClimbsSection(route: route) }
            Section("Preparation") { EventPreparationSummary(event: event) }

            InfoSection {
                ForEach(sessions) { s in
                    SessionRow(session: s, isToday: s.day == model.today)
                }
            } header: {
                Text("Until the event")
            } information: {
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let session: PlannedSession
    var isToday = false

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            dateLabel
            VStack(alignment: .leading, spacing: 6) {
                Text(session.title)
                    .fontWeight(isToday ? .semibold : .regular)
                    .foregroundStyle(session.status == .skipped ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                metadata
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let problem = calendarProblem {
                    Label { Text(problem) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var dateLabel: some View {
        VStack(spacing: 6) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Text(session.day.date(), format: .dateTime.weekday(.abbreviated).day())
                        .font(.subheadline.weight(.semibold))
                } else {
                    VStack(spacing: 2) {
                        Text(session.day.date(), format: .dateTime.weekday(.abbreviated))
                            .font(.caption2)
                            .textCase(.uppercase)
                        Text("\(session.day.day)")
                            .font(.headline.monospacedDigit())
                    }
                    .frame(width: 40)
                }
            }
            .foregroundStyle(isToday ? Color.accentColor : Color.secondary)
            .padding(.vertical, 4)
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
            .background(isToday ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Format.day(session.day)))
            .accessibilityValue(isToday ? Text("Today") : Text(""))
            statusIcon
                .font(.caption)
        }
    }

    /// One text flow lets the kind and metrics wrap naturally without competing for width.
    private var metadata: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: session.kind.symbol)
                .foregroundStyle(session.kind.tint)
                .accessibilityHidden(true)
            metadataText
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var metadataText: Text {
        var text = Text(session.kind.title)
        if session.kind != .rest {
            let duration = Format.minutes(TimeInterval(session.targetMinutes * 60))
                .replacingOccurrences(of: " ", with: "\u{00a0}")
            text = text + Text(verbatim: " · ") + Text(verbatim: duration)
        }
        if let load = session.targetLoad {
            text = text + Text(verbatim: " · ") + Text("\(load) TSS")
        }
        return text
    }

    /// Why the plan's session is not on the Intervals calendar, while it is still to be ridden.
    private var calendarProblem: LocalizedStringKey? {
        guard session.status != .completed, session.status != .skipped else { return nil }
        switch session.calendarProblem {
        case .notConnected?: return "Not on your Intervals calendar. Sign in to Cadencia again in Settings to reconnect."
        case .refused?: return "Intervals.icu refused this session, so it isn't on your calendar."
        case nil: return nil
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch session.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .accessibilityLabel("Completed")
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
                .accessibilityLabel("Skipped")
        case .generated:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                .accessibilityLabel("Workout ready")
        case .provisional: EmptyView()
        }
    }
}

#Preview {
    NavigationStack { EventPrepView(event: PreviewData.plan.event!) }.environment(PreviewData.model())
}
