import SwiftUI
import CadenciaCore

struct PlanConsultationReviewView: View {
    @Environment(AppModel.self) private var model
    let draft: PlanConsultation.Draft
    let sessionID: UUID
    let finished: () -> Void
    @State private var confirmReplace = false
    @State private var saving = false
    @State private var notice: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: draft.title).font(.title2.weight(.semibold))
                    Text(verbatim: draft.details.objective)
                    Text(verbatim: draft.details.rationale).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                LabeledContent("From", value: Format.day(draft.startDay))
                LabeledContent("To", value: Format.day(draft.endDay))
                if let event = draft.event { LabeledContent("Event", value: event.name) }
            }
            if let plan = try? draft.makePlan(today: model.today) {
                Section("First week") {
                    ForEach(plan.sessions.filter { $0.day < plan.startDay.adding(days: 7) }) { session in
                        LabeledContent {
                            Text("\(Text(session.kind.title)) · \(Format.minutes(Double(session.targetMinutes) * 60))")
                        } label: { Text(Format.day(session.day)) }
                    }
                    if plan.sessions.allSatisfy({ $0.day >= plan.startDay.adding(days: 7) }) {
                        Text("No cycling scheduled in the first week.")
                    }
                }
                Section("Phases") {
                    ForEach(plan.phases) { phase in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(phase.focus.title).fontWeight(.semibold)
                            Group {
                                if phase.startWeek == phase.endWeek { Text("Week \(phase.startWeek)") }
                                else { Text("Weeks \(phase.startWeek)–\(phase.endWeek)") }
                            }
                            .foregroundStyle(.secondary)
                            Text(verbatim: phase.summary)
                        }
                    }
                }
            }
            if !draft.details.otherTraining.isEmpty {
                Section("Other training") {
                    ForEach(draft.details.otherTraining) { activity in
                        OtherTrainingRow(activity: activity)
                    }
                }
            }
            if !draft.details.timeAway.isEmpty {
                Section("Time away") {
                    ForEach(draft.details.timeAway) { period in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(Format.day(period.start)) – \(Format.day(period.end))")
                            if !period.reason.isEmpty { Text(verbatim: period.reason).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if model.workingFTP == nil {
                Text("Add FTP in your cyclist profile to generate power-based workouts.")
                    .foregroundStyle(.secondary)
            }
            if let notice { Text(verbatim: notice).foregroundStyle(.secondary) }
            Section {
                Button {
                    if model.state.plan != nil { confirmReplace = true }
                    else { Task { await activate() } }
                } label: {
                    // The title keeps its place so the button never resizes. The spinner stays untinted
                    // (the disabled fill is gray) and regular-size rather than inheriting `.large`.
                    Text("Start plan")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .opacity(saving ? 0 : 1)
                        .overlay { if saving { ProgressView().controlSize(.regular) } }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(saving || model.consultationBusy)
                .accessibilityIdentifier("consultation-start-plan")
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            } footer: {
                Text("Go back to the consultation if you want to change anything.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Review plan")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Replace your current plan?", isPresented: $confirmReplace, titleVisibility: .visible) {
            // Destructive: the current plan is replaced and can't be restored.
            Button("Start plan", role: .destructive) { Task { await activate() } }
        } message: {
            Text("Your future cycling sessions will follow this plan. Completed rides stay in your history.")
        }
    }

    private func activate() async {
        guard !saving else { return }
        saving = true
        do {
            try await model.activateConsultationPlan(draft, sessionID: sessionID)
            // Success closes the cover. `saving` stays set, as in EventPlanFlow.create, so the spinner
            // stays (and a second start stays blocked) while the cover slides away.
            finished()
        } catch {
            saving = false
            notice = String(localized: "This draft needs an update. Go back and ask the coach to revise it.")
        }
    }
}

struct OtherTrainingRow: View {
    var activity: PlanConsultation.OtherTraining
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: activity.name).fontWeight(.semibold)
            Text(activity.weekdays.sorted().map { Calendar.current.shortStandaloneWeekdaySymbols[$0 - 1] }.formatted(.list(type: .and)))
            Text("\(Format.minutes(Double(activity.minutes) * 60)) · \(Text(intensity))")
                .foregroundStyle(.secondary)
        }
    }
    private var intensity: LocalizedStringKey {
        switch activity.intensity {
        case .easy: "Easy"
        case .moderate: "Moderate"
        case .hard: "Hard"
        }
    }
}
