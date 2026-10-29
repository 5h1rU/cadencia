import Foundation
import CadenciaCore

/// Sample data for Xcode previews, mirroring the values in the design file (FTP 240, HRV 48, ATL 78, CTL 62).
enum PreviewData {
    static let today = Day(Date())

    static var athlete: AthleteProfile {
        AthleteProfile(id: "i12345", name: "Felipe", ftp: 240, indoorFTP: 240, weightKg: 72, maxHR: 188, lthr: 168, powerZones: [55, 75, 90, 105, 120, 150, 999])
    }

    static var wellness: [WellnessDay] {
        (0..<60).reversed().map { offset in
            let day = today.adding(days: -offset)
            let noise = Double((offset * 37) % 11) - 5
            return WellnessDay(day: day,
                               hrvMs: 48 + noise + (offset == 0 ? -6 : 0),
                               restingHR: 48 + Int(noise / 3),
                               sleepSeconds: Int(7.2 * 3600 + noise * 600),
                               ctl: 62 - Double(offset) * 0.2,
                               atl: 78 - Double(offset) * 0.5)
        }
    }

    static var activities: [ActivitySummary] {
        (1...20).map { i in
            ActivitySummary(id: "a\(i)", name: i % 3 == 0 ? "Threshold 3×12" : "Endurance", type: "VirtualRide",
                            startDateLocal: today.adding(days: -i * 2).date(), movingTime: 3600 + Double(i % 4) * 900,
                            trainingLoad: 60 + i * 2, intensity: i % 3 == 0 ? 92 : 70, averageWatts: 180, normalizedWatts: 200, averageHR: 140,
                            ftpAtTime: 240, estimatedFTP: i % 3 == 0 ? 248 : nil, isTrainer: true)
        }
    }

    static var curve: [PowerCurvePoint] {
        [(5, 820), (60, 420), (300, 300), (720, 262), (1200, 255), (3600, 236)].map { PowerCurvePoint(seconds: $0.0, watts: $0.1) }
    }

    static var plan: TrainingPlan {
        let event = TrainingEvent(name: "Gran Fondo Andes", day: today.adding(days: 47), distanceKm: 140, priority: .a, objective: "finish strong", isRace: false)
        var plan = PlanBuilder().build(.init(goal: .event, startDay: today.startOfWeek(), endDay: event.day, event: event, availability: .typical, currentCTL: 62))
        plan.isActive = true
        return plan
    }

    static var state: AppState {
        var s = AppState()
        s.athlete = athlete
        s.wellness = wellness
        s.activities = activities
        s.powerCurve = curve
        s.plan = plan
        s.ftpEstimate = FTPEstimator().estimate(curve: curve, sustainedEfforts: 4)
        var readiness = ReadinessEngine().evaluate(today: wellness.last!, history: wellness)
        readiness.level = .normal
        readiness.summary = "Día normal. HRV 62 ms dentro de tu rango (55–68), 7,4 h de sueño, TSB −8: carga asimilada, sin señales de fatiga acumulada."
        let workout = Workout(name: "Sweet spot 3×12", kind: .tempo, steps: [
            WorkoutStep(name: "Calentamiento", duration: 600, startIntensity: 0.45, endIntensity: 0.7),
            WorkoutStep(name: "Sweet spot", duration: 720, intensity: 0.9, cadenceRPM: 90),
            WorkoutStep(name: "Recuperación", duration: 240, intensity: 0.55),
            WorkoutStep(name: "Sweet spot", duration: 720, intensity: 0.9, cadenceRPM: 90),
            WorkoutStep(name: "Recuperación", duration: 240, intensity: 0.55),
            WorkoutStep(name: "Sweet spot", duration: 720, intensity: 0.9, cadenceRPM: 90),
            WorkoutStep(name: "Vuelta a la calma", duration: 360, startIntensity: 0.6, endIntensity: 0.4),
        ], intensityCeiling: 0.95, rationale: "Tres bloques de 12 min al 90 % (216 W) para seguir construyendo umbral sin comprometer la salida larga del sábado.")
        let week: [DailyPrescription.DayOutlook] = [
            .init(day: today, kind: .tempo, minutes: 60, title: "Sweet spot 3×12"),
            .init(day: today.adding(days: 1), kind: .recovery, minutes: 45, title: "Rodaje suave"),
            .init(day: today.adding(days: 2), kind: .endurance, minutes: 90, title: "Z2"),
            .init(day: today.adding(days: 3), kind: .rest, minutes: 0, title: "Descanso"),
            .init(day: today.adding(days: 4), kind: .openerActivation, minutes: 45, title: "Activación"),
            .init(day: today.adding(days: 5), kind: .longRide, minutes: 240, title: "Salida larga 120 km"),
            .init(day: today.adding(days: 6), kind: .recovery, minutes: 40, title: "Rodaje suave"),
        ]
        let ai = DailyPrescription(readiness: readiness, workout: workout, week: week,
                                   note: CoachNote(headline: "Buen día para apretar un poco",
                                                   body: "Dormiste 7,2 horas y tu recuperación está en su rango habitual; la carga de la semana pasada ya está absorbida.",
                                                   session: "Una hora de sweet spot en tres bloques de 12 minutos a unos 210 W: suficiente para construir sin dejarte vacío para el sábado.",
                                                   watch: "Si las piernas van pesadas en el segundo bloque, corta el tercero."),
                                   flags: [], model: "gpt-6-astra")
        s.today = .init(day: today, workout: workout, readiness: readiness, ai: ai, aiFingerprint: "preview")
        s.coachMessages = [
            .init(role: .athlete, text: "El sábado tengo una salida larga de 120 km, y el jueves solo tengo 45 minutos."),
            .init(role: .coach, text: "Entendido: salida larga el sábado y jueves corto.",
                  intent: CoachIntent(event: TrainingEvent(name: "Salida larga", day: today.adding(days: 5), distanceKm: 120, priority: .b),
                                      constraints: [.init(day: today.adding(days: 3), maxMinutes: 45)], reply: "Entendido")),
        ]
        s.lastSyncAt = Date().addingTimeInterval(-600)
        return s
    }

    static var ride: RideRecording {
        let workout = state.today!.workout
        let start = Date().addingTimeInterval(-3600)
        var ride = RideRecording(athleteID: "i12345", workout: workout, startedAt: start)
        ride.samples = (0..<3600).map { i in
            let t = start.addingTimeInterval(Double(i))
            let target = workout.targetWatts(ftp: 240, at: Double(i)) ?? 150
            return RideSample(time: t, watts: target + (i % 7) - 3, heartRate: 120 + target / 6, cadence: 88 + (i % 5), targetWatts: target)
        }
        ride.endedAt = start.addingTimeInterval(3600)
        return ride
    }

    /// The same ride once Intervals has processed it and the coach has written its debrief.
    static var debriefedRide: RideRecording {
        var r = ride
        r.analysis = ActivityDetail(id: "i4521", name: r.workout.name, analyzed: true, movingTime: 3600, trainingLoad: 58, intensity: 76,
                                    averageWatts: 176, normalizedWatts: 183, averageHR: 141, maxHR: 162, averageCadence: 89, ftp: 240, estimatedFTP: 244,
                                    kilojoules: 634, kilojoulesAboveFTP: 0,
                                    powerZoneTimes: [.init(zone: "Z1", seconds: 420), .init(zone: "Z2", seconds: 2520), .init(zone: "Z3", seconds: 600), .init(zone: "Z4", seconds: 60)],
                                    hrZoneTimes: [600, 2400, 540, 60], hrRecovery: .init(startBPM: 160, endBPM: 128, drop: 32),
                                    decoupling: 2.8, efficiencyFactor: 1.30, variabilityIndex: 1.04, compliance: 94, ctl: 52, atl: 61)
        r.debrief = RideDebrief.Report(
            headline: "Clean endurance hour: 42 minutes in Z2 at a steady heart rate.",
            grade: .excellent,
            benefit: "This was an aerobic-base session, and it delivered: 42 of 60 minutes sat in Z2 at 176 W average, the stimulus that builds mitochondrial density and fat oxidation. Load 58 is exactly the dose planned for a mid-week endurance day.",
            execution: "Warm-up ramped cleanly from 110 to 165 W. The main block held 178–184 W against a 180 W target with 93 % of the time in zone; cadence stayed at 89 rpm throughout. Cool-down was ridden as prescribed.",
            physiology: "Heart rate averaged 141 bpm for 183 W normalized, an efficiency factor of 1.30 — your best in three weeks. Decoupling of 2.8 % means the aerobic system coped with the full hour without drifting, and the 32 bpm recovery in the first minute after the block points to good freshness.",
            next: "Fatigue is now 61 against a fitness of 52, so tomorrow's threshold session is on as planned; eat and sleep for it tonight.",
            blocks: [.init(index: 0, verdict: .hit, note: "Ramped as prescribed"), .init(index: 1, verdict: .hit, note: "93 % in zone, cadence 89"), .init(index: 2, verdict: .hit, note: "Spun down cleanly")],
            flags: ["eFTP 244 W: two more strong rides and the FTP review will fire"],
            model: "gpt-6-astra")
        return r
    }

    @MainActor
    /// `rides` are written to the model's store so `model.ride(id:)` finds them, and indexed as confirmed uploads.
    static func model(signedIn: Bool = true, rides: [RideRecording] = []) -> AppModel {
        let store = JSONStore.temporary()
        var s = state
        for ride in rides {
            try? store.save(ride, at: "rides/\(ride.id.uuidString).json")
            s.rideIndex.append(.init(id: ride.id, name: ride.workout.name, kind: ride.workout.kind, startedAt: ride.startedAt,
                                     duration: ride.duration, averageWatts: ride.averageWatts, load: ride.trainingLoad(ftp: 240)))
            s.ledger.enqueue(rideID: ride.id, athleteID: ride.athleteID)
            s.ledger.markConfirmed(ride.id, activityID: ride.analysis?.id ?? "i4521", at: ride.endedAt ?? ride.startedAt)
        }
        return AppModel(state: s, credential: signedIn ? .apiKey("preview") : nil, store: store, keychain: KeychainStore(service: "preview"), transport: URLSession.shared)
    }
}
