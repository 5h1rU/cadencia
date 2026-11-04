import Foundation
import CadenciaCore

/// Unsaved form state. Only AppModel.createPlan writes it to the athlete's state/calendar.
struct EventPlanDraft {
    var name = ""
    var date = Calendar.current.date(byAdding: .weekOfYear, value: 12, to: Date())!
    var knowsStartTime = false
    var startTime = Date()
    var timeZoneID = TimeZone.current.identifier
    var location = ""
    var latitude: Double?
    var longitude: Double?
    var discipline: EventDetails.Discipline = .road
    var priority: TrainingEvent.Priority = .a
    var isRace = false
    var goal: EventDetails.Goal = .finishStrong
    var objective = ""
    var durationHours = ""
    var cutoffHours = ""
    var distance = ""
    var gain = ""
    var loss = ""
    var startAltitude = ""
    var minAltitude = ""
    var maxAltitude = ""
    var surface: EventCourse.Surface?
    var technical: EventCourse.TechnicalDifficulty?
    var route: GPXRoute?
    var fileName: String?
    var manualCourse = false
    var usualAltitude = ""
    var knowsArrival = false
    var arrival = Date()
    var temperature = ""
    var humidity = ""
    var conditions = ""
    var experience = ""
    var support = ""
    var constraints = ""
    var minutesByWeekday = Availability.typical.minutesByWeekday
    var longRideDay = Availability.typical.longRideWeekday

    static func number(_ value: String) -> Double? {
        guard let v = Double(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), v.isFinite else { return nil }
        return v
    }
    static func text(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
    private func valid(_ value: String, range: ClosedRange<Double>) -> Bool {
        Self.text(value) == nil || Self.number(value).map(range.contains) == true
    }
    var validCourse: Bool {
        (route != nil || manualCourse) && Self.number(distance).map { $0 > 0 && $0 <= 10_000 } == true
            && valid(gain, range: 0...100_000) && valid(loss, range: 0...100_000)
            && [startAltitude, minAltitude, maxAltitude].allSatisfy { valid($0, range: -500...10_000) }
            && (Self.number(minAltitude) == nil || Self.number(maxAltitude) == nil || Self.number(minAltitude)! <= Self.number(maxAltitude)!)
    }
    var validEvent: Bool {
        Self.text(name) != nil && Self.text(location) != nil && TimeZone(identifier: timeZoneID) != nil
    }
    var validPreparation: Bool {
        valid(durationHours, range: 0.1...240) && valid(cutoffHours, range: 0.1...240)
            && (goal != .targetTime || Self.number(durationHours) != nil)
            && valid(usualAltitude, range: -500...10_000) && valid(temperature, range: -50...60)
            && valid(humidity, range: 0...100) && (!knowsArrival || Day(arrival) <= Day(date))
            && !minutesByWeekday.isEmpty && minutesByWeekday[longRideDay] != nil
    }
    var availability: Availability {
        Availability(hoursPerWeek: Double(minutesByWeekday.values.reduce(0, +)) / 60,
                     minutesByWeekday: minutesByWeekday, longRideWeekday: longRideDay)
    }
    mutating func apply(_ route: GPXRoute, fileName: String) {
        self.route = route; self.fileName = fileName; manualCourse = false
        distance = String(format: "%.1f", route.distanceKm)
        func meters(_ value: Double?) -> String { value.map { String(Int($0.rounded())) } ?? "" }
        gain = meters(route.elevationGainM); loss = meters(route.elevationLossM)
        startAltitude = meters(route.start?.elevationM)
        minAltitude = meters(route.minAltitudeM); maxAltitude = meters(route.maxAltitudeM)
        latitude = route.start?.latitude; longitude = route.start?.longitude
    }
    var event: TrainingEvent {
        var details = EventDetails()
        details.locationName = Self.text(location); details.latitude = latitude; details.longitude = longitude
        details.timeZoneIdentifier = timeZoneID
        if knowsStartTime {
            let c = Calendar.current.dateComponents([.hour, .minute], from: startTime)
            details.localStartTime = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        details.discipline = discipline; details.goal = goal
        details.expectedDurationMinutes = Self.number(durationHours).map { Int(($0 * 60).rounded()) }
        details.cutoffMinutes = Self.number(cutoffHours).map { Int(($0 * 60).rounded()) }
        details.usualAltitudeM = Self.number(usualAltitude); details.arrivalDay = knowsArrival ? Day(arrival) : nil
        details.expectedTemperatureC = Self.number(temperature); details.expectedHumidityPercent = Self.number(humidity)
        details.conditionsNote = Self.text(conditions); details.terrainExperience = Self.text(experience)
        details.supportNotes = Self.text(support); details.trainingConstraints = Self.text(constraints)
        let course = EventCourse(elevationGainM: Self.number(gain), elevationLossM: Self.number(loss),
                                 startAltitudeM: Self.number(startAltitude), minAltitudeM: Self.number(minAltitude), maxAltitudeM: Self.number(maxAltitude),
                                 surface: surface, technicalDifficulty: technical, route: route, sourceFileName: fileName)
        return TrainingEvent(name: name.trimmingCharacters(in: .whitespacesAndNewlines), day: Day(date),
                             distanceKm: Self.number(distance), priority: priority, objective: objective,
                             isRace: isRace, course: course, details: details)
    }
}

extension EventDetails.Discipline {
    var title: String {
        switch self {
        case .road: return String(localized: "Road")
        case .gravel: return String(localized: "Gravel")
        case .mountainBike: return String(localized: "Mountain bike")
        case .timeTrial: return String(localized: "Time trial")
        case .other: return String(localized: "Other")
        }
    }
}
extension EventDetails.Goal {
    var title: String {
        switch self {
        case .finishComfortably: return String(localized: "Finish comfortably")
        case .finishStrong: return String(localized: "Finish strong")
        case .targetTime: return String(localized: "Target a time")
        case .compete: return String(localized: "Compete")
        }
    }
}
extension EventCourse.Surface {
    var title: String {
        switch self {
        case .paved: return String(localized: "Paved")
        case .gravel: return String(localized: "Gravel")
        case .trail: return String(localized: "Trail")
        case .mixed: return String(localized: "Mixed")
        }
    }
}
extension EventCourse.TechnicalDifficulty {
    var title: String {
        switch self {
        case .low: return String(localized: "Low")
        case .moderate: return String(localized: "Moderate")
        case .high: return String(localized: "High")
        }
    }
}
