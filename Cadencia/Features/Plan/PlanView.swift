import SwiftUI
import CadenciaCore

/// The adaptive plan: this week in detail, the month as intentions, the whole arc as phases.
struct PlanView: View {
    @Environment(AppModel.self) private var model
    @State private var scope: Scope = .week
    @State private var weekOffset = 0
    @State private var creating = false
    @State private var confirmDiscard = false

    enum Scope: String, CaseIterable, Identifiable {
        case week, month, plan
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .week: return "Week"
            case .month: return "Month"
            case .plan: return "Plan"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let plan = model.state.plan {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(plan.title)
                                    .font(.title2.bold())
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Picker("Scope", selection: $scope) {
                                    ForEach(Scope.allCases) { Text($0.title).tag($0) }
                                }
                                .pickerStyle(.segmented)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 8)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                        }
                        switch scope {
                        case .week: weekSections(plan)
                        case .month: monthSections(plan)
                        case .plan: planSections(plan)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .listSectionSpacing(16)
                    .contentMargins(.top, 12, for: .scrollContent)
                } else {
                    ContentUnavailableView {
                        Label("No plan yet", systemImage: "calendar.badge.plus")
                    } description: {
                        Text("Tell your coach what you want from your riding. We’ll shape a plan around your history, your week and the training you want to include.")
                    } actions: {
                        Button(model.state.planConsultation == nil ? "Create a plan" : "Continue consultation") { creating = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.state.plan != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("New plan", systemImage: "plus") { creating = true }
                            Button("Discard plan", systemImage: "trash", role: .destructive) { confirmDiscard = true }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Plan options")
                    }
                }
            }
            .fullScreenCover(isPresented: $creating) { CreatePlanView() }
            .confirmationDialog("Discard this plan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { Task { await model.discardPlan() } }
            } message: {
                Text("Planned sessions are removed from your Intervals calendar. Completed rides stay.")
            }
        }
    }

    // MARK: Week

    @ViewBuilder private func weekSections(_ plan: TrainingPlan) -> some View {
        let anchor = model.today.adding(days: weekOffset * 7)
        let sessions = plan.sessions(inWeekOf: anchor)
        let start = anchor.startOfWeek()
        let load = sessions.compactMap(\.targetLoad).reduce(0, +)
        let minutes = sessions.map(\.targetMinutes).reduce(0, +)
        Section {
            ForEach(sessions) { s in
                if let ride = model.completedRide(for: s) {
                    NavigationLink { RideDebriefView(rideID: ride.id) } label: {
                        SessionRow(session: s, isToday: s.day == model.today)
                    }
                } else if s.day == model.today, let w = model.todayWorkout, let ftp = model.workingFTP {
                    NavigationLink {
                        WorkoutDetailView(workout: model.todayRideLocation == .outdoor ? (model.outdoorWorkout?.workout ?? w) : w,
                                          ftp: model.todayRideLocation == .outdoor ? (model.outdoorFTP ?? ftp) : ftp)
                    } label: { SessionRow(session: s, isToday: true) }
                } else {
                    NavigationLink { PlannedRideRouteView(day: s.day) } label: {
                        SessionRow(session: s, isToday: s.day == model.today)
                    }
                }
            }
            if sessions.isEmpty { Text("Nothing planned this week.").foregroundStyle(.secondary) }
            BlockInfo {
                Text("\(Format.minutes(TimeInterval(minutes * 60))) · about \(load) TSS")
                    .font(.subheadline.weight(.medium))
            } information: {
                Text("Only today is a fixed workout; the rest adapts to recovery.")
            }
        } header: {
            HStack(spacing: 8) {
                Button { weekOffset -= 1 } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Previous week")
                VStack(spacing: 4) {
                    Text("Week of \(Format.day(start, style: .dateTime.day().month(.abbreviated)))")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let n = plan.weekNumber(of: start), let phase = plan.phase(for: start) {
                        Text("Week \(n) of \(plan.weekCount) · \(Text(phase.focus.title))").font(.caption).textCase(nil)
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                Button { weekOffset += 1 } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Next week")
            }
            .buttonStyle(.borderless)
            .textCase(nil)
        }
    }

    // MARK: Month

    @ViewBuilder private func monthSections(_ plan: TrainingPlan) -> some View {
        let start = model.today.startOfWeek()
        ForEach(0..<5, id: \.self) { w in
            let weekStart = start.adding(days: w * 7)
            let sessions = plan.sessions(inWeekOf: weekStart)
            if !sessions.isEmpty {
                Section {
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { d in
                            let day = weekStart.adding(days: d)
                            let s = sessions.first { $0.day == day }
                            VStack(spacing: 4) {
                                Text(day.date().formatted(.dateTime.weekday(.narrow))).font(.caption2).foregroundStyle(.secondary)
                                Circle()
                                    .fill(s?.kind.tint ?? Color(.systemFill))
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        if let s { Image(systemName: s.kind.symbol).font(.caption2).foregroundStyle(.white) }
                                    }
                                    .overlay { if day == model.today { Circle().stroke(Color.primary, lineWidth: 2) } }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 4)
                    if let phase = plan.phase(for: weekStart) {
                        Text("\(Text(phase.focus.title)) · about \(sessions.compactMap(\.targetLoad).reduce(0, +)) TSS")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(w == 0 ? "This week" : "\(Format.day(weekStart, style: .dateTime.day().month(.abbreviated)))")
                }
            }
        }
    }

    // MARK: Plan

    @ViewBuilder private func planSections(_ plan: TrainingPlan) -> some View {
        Section {
            LabeledContent("Goal") {
                if let objective = plan.consultation?.objective { Text(verbatim: objective) }
                else { Text(plan.goal.title) }
            }
            if let g = plan.secondaryGoal { LabeledContent("Also") { Text(g.title) } }
            LabeledContent("From", value: Format.day(plan.startDay, style: .dateTime.day().month(.abbreviated).year()))
            LabeledContent("To", value: Format.day(plan.endDay, style: .dateTime.day().month(.abbreviated).year()))
            if let e = plan.event {
                NavigationLink { EventPrepView(event: e) } label: { LabeledContent("Event", value: e.name) }
            }
            LabeledContent("Availability", value: "\(plan.availability.availableWeekdays.count) days · \(String(format: "%.0f", plan.availability.hoursPerWeek)) h")
        }
        if let activities = plan.consultation?.otherTraining, !activities.isEmpty {
            Section("Other training") {
                ForEach(activities) { OtherTrainingRow(activity: $0) }
            }
        }
        InfoSection {
            ForEach(plan.phases) { phase in
                let current = plan.phase(for: model.today)?.id == phase.id
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(phase.focus.title).fontWeight(current ? .semibold : .regular)
                        Spacer()
                        Text(phase.startWeek == phase.endWeek ? "Week \(phase.startWeek)" : "Weeks \(phase.startWeek)–\(phase.endWeek)").foregroundStyle(.secondary).font(.footnote)
                    }
                    Text(phase.summary).font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(current ? Color.accentColor.opacity(0.08) : nil)
            }
        } header: {
            Text("Phases")
        } information: {
            Text("Phases are the long-range intent. Each week's sessions are provisional until the morning they happen.")
        }
    }
}

#Preview {
    PlanView().environment(PreviewData.model())
}
