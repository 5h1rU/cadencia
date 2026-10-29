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
        let readiness = ReadinessEngine().evaluate(today: wellness.last!, history: wellness)
        let planned = plan.sessions.first { $0.day == today }
        let workout = DailyPrescriber().prescribe(.init(day: today, planned: planned, readiness: readiness, ftp: 240, upcomingPriorityEvent: plan.event))
        s.today = .init(day: today, workout: workout, readiness: readiness)
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

    @MainActor
    static func model(signedIn: Bool = true) -> AppModel {
        let m = AppModel(state: state, credential: signedIn ? .apiKey("preview") : nil, store: .temporary(), keychain: KeychainStore(service: "preview"), transport: URLSession.shared)
        return m
    }
}
