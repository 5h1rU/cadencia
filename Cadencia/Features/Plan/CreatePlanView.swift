import SwiftUI
import CadenciaCore

/// Choose a goal, then say when, how much time you have and (for an event) what it is.
struct CreatePlanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var goal: GoalKind?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(GoalKind.allCases, id: \.self) { g in
                        NavigationLink(value: g) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(g.title)
                                    Text(g.subtitle).font(.footnote).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: g.symbol) }
                        }
                    }
                } header: {
                    Text("What do you want to get out of the next weeks?")
                } footer: {
                    Text("A plan is a direction, not a contract. The coach reshapes each week from your recovery and what you tell it.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("New plan")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: GoalKind.self) { g in ConfigureGoalView(goal: g) { dismiss() } }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct ConfigureGoalView: View {
    @Environment(AppModel.self) private var model
    let goal: GoalKind
    let finished: () -> Void

    @State private var weeks = 8
    @State private var eventName = ""
    @State private var eventDate = Calendar.current.date(byAdding: .weekOfYear, value: 12, to: Date())!
    @State private var distanceKm = ""
    @State private var priority: TrainingEvent.Priority = .a
    @State private var isRace = false
    @State private var objective = ""
    @State private var secondaryGoal: GoalKind?
    @State private var days: Set<Int> = Set(Availability.typical.availableWeekdays)
    @State private var longRideDay = Availability.typical.longRideWeekday
    @State private var weekdayMinutes = 60
    @State private var weekendMinutes = 150
    @State private var saving = false

    private var isEvent: Bool { goal == .event }
    private var canCreate: Bool { !days.isEmpty && (!isEvent || !eventName.trimmingCharacters(in: .whitespaces).isEmpty) }

    var body: some View {
        Form {
            if isEvent {
                Section("Event") {
                    TextField("Name", text: $eventName)
                    DatePicker("Date", selection: $eventDate, in: Date()..., displayedComponents: .date)
                    TextField("Distance (km)", text: $distanceKm).keyboardType(.decimalPad)
                    Picker("Priority", selection: $priority) {
                        Text("A · the one that matters").tag(TrainingEvent.Priority.a)
                        Text("B · important").tag(TrainingEvent.Priority.b)
                        Text("C · training ride").tag(TrainingEvent.Priority.c)
                    }
                    Toggle("It's a race", isOn: $isRace)
                    TextField("Objective (finish fresh, podium…)", text: $objective)
                }
            } else {
                Section {
                    Stepper("\(weeks) weeks", value: $weeks, in: 4...24)
                } header: {
                    Text("Duration")
                } footer: {
                    Text("Blocks alternate three loading weeks with one easier week.")
                }
                Section("Also keep an eye on") {
                    Picker("Secondary goal", selection: $secondaryGoal) {
                        Text("None").tag(GoalKind?.none)
                        ForEach(GoalKind.allCases.filter { $0 != goal && $0 != .event }, id: \.self) { Text($0.title).tag(GoalKind?.some($0)) }
                    }
                }
            }

            Section {
                HStack(spacing: 6) {
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { wd in
                        let on = days.contains(wd)
                        Button {
                            if on { days.remove(wd) } else { days.insert(wd) }
                        } label: {
                            Text(weekdaySymbol(wd))
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: Circle())
                                .foregroundStyle(on ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                Picker("Long ride", selection: $longRideDay) {
                    ForEach(Array(days).sorted(), id: \.self) { Text(weekdayName($0)).tag($0) }
                }
                Stepper("Weekdays: \(Format.minutes(TimeInterval(weekdayMinutes * 60)))", value: $weekdayMinutes, in: 30...180, step: 15)
                Stepper("Weekend: \(Format.minutes(TimeInterval(weekendMinutes * 60)))", value: $weekendMinutes, in: 60...360, step: 30)
            } header: {
                Text("Availability")
            } footer: {
                Text("Hard days land on the days you train that do not precede the long ride.")
            }

            Section {
                Button {
                    saving = true
                    Task { await create(); finished() }
                } label: {
                    HStack { if saving { ProgressView() }; Text("Create plan").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate || saving)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle(goal.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: days) { _, d in
            if !d.contains(longRideDay), let fallback = d.contains(1) ? 1 : d.max() { longRideDay = fallback }
        }
    }

    private func create() async {
        var minutes: [Int: Int] = [:]
        for d in days { minutes[d] = (d == 1 || d == 7) ? weekendMinutes : weekdayMinutes }
        let hours = Double(minutes.values.reduce(0, +)) / 60
        let availability = Availability(hoursPerWeek: hours, minutesByWeekday: minutes, longRideWeekday: longRideDay)
        let start = model.today
        let event: TrainingEvent? = isEvent ? TrainingEvent(name: eventName.trimmingCharacters(in: .whitespaces), day: Day(eventDate),
                                                            distanceKm: Double(distanceKm.replacingOccurrences(of: ",", with: ".")),
                                                            priority: priority, objective: objective, isRace: isRace) : nil
        let end = isEvent ? Day(eventDate) : start.adding(days: weeks * 7 - 1)
        let request = PlanBuilder.Request(goal: goal, secondaryGoal: isEvent ? nil : secondaryGoal, startDay: start, endDay: end,
                                          event: event, availability: availability, currentCTL: model.latestWellness?.ctl)
        await model.createPlan(request)
    }

    private func weekdaySymbol(_ wd: Int) -> String {
        Calendar.current.veryShortStandaloneWeekdaySymbols[wd - 1]
    }

    private func weekdayName(_ wd: Int) -> String {
        Calendar.current.standaloneWeekdaySymbols[wd - 1].capitalized
    }
}

#Preview {
    CreatePlanView().environment(PreviewData.model())
}
