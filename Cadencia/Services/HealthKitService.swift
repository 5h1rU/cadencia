import Foundation
import HealthKit
import CadenciaCore

/// Reads the recovery signals Cadencia needs from Apple Health and writes finished trainer rides back.
/// Apple Health is a source of wellness data, never the system of record: Intervals.icu stays that.
final class HealthKitService {
    private let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        [
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRate),
            HKCategoryType(.sleepAnalysis),
            HKObjectType.workoutType(),
        ]
    }

    private var writeTypes: Set<HKSampleType> {
        [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.cyclingPower),
            HKQuantityType(.activeEnergyBurned),
        ]
    }

    func requestAuthorization() async throws {
        guard Self.isAvailable else { return }
        try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
    }

    /// Daily HRV (SDNN, ms), resting HR and sleep for the last `days` days, one `WellnessDay` per day with data.
    func readWellness(days: Int, calendar: Calendar = .current, now: Date = Date()) async throws -> [WellnessDay] {
        guard Self.isAvailable else { return [] }
        let end = now
        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
        let window = HKQuery.predicateForSamples(withStart: start, end: end, options: [])

        async let hrv = quantitySamples(.heartRateVariabilitySDNN, predicate: window)
        async let rhr = quantitySamples(.restingHeartRate, predicate: window)
        async let sleep = categorySamples(.sleepAnalysis, predicate: window)

        var byDay: [Day: WellnessDay] = [:]
        func entry(_ day: Day) -> WellnessDay { byDay[day] ?? WellnessDay(day: day) }

        // HRV: mean of the day's samples (the Watch takes a handful per day, mostly during sleep).
        var hrvSums: [Day: (Double, Int)] = [:]
        for s in try await hrv {
            let day = Day(s.startDate, calendar: calendar)
            let v = s.quantity.doubleValue(for: .secondUnit(with: .milli))
            let cur = hrvSums[day] ?? (0, 0)
            hrvSums[day] = (cur.0 + v, cur.1 + 1)
        }
        for (day, sum) in hrvSums {
            var e = entry(day)
            e.hrvMs = (sum.0 / Double(sum.1) * 10).rounded() / 10
            byDay[day] = e
        }

        for s in try await rhr {
            let day = Day(s.startDate, calendar: calendar)
            var e = entry(day)
            e.restingHR = Int(s.quantity.doubleValue(for: .count().unitDivided(by: .minute())).rounded())
            byDay[day] = e
        }

        // Sleep: asleep stages only, attributed to the day the night ends on. If Apple Watch wrote
        // samples, ignore other sources to avoid double counting.
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        let allSleep = try await sleep.filter { asleepValues.contains($0.value) }
        let appleSleep = allSleep.filter { $0.sourceRevision.source.bundleIdentifier.hasPrefix("com.apple.health") }
        var sleepSums: [Day: TimeInterval] = [:]
        for s in appleSleep.isEmpty ? allSleep : appleSleep {
            let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: s.endDate)!
            let day = Day(s.endDate < noon ? s.endDate : calendar.date(byAdding: .day, value: 1, to: s.endDate)!, calendar: calendar)
            sleepSums[day, default: 0] += s.endDate.timeIntervalSince(s.startDate)
        }
        for (day, secs) in sleepSums {
            var e = entry(day)
            e.sleepSeconds = Int(secs)
            byDay[day] = e
        }

        let stamp = now
        return byDay.values.map { var d = $0; d.updatedAt = stamp; return d }.sorted { $0.day < $1.day }
    }

    /// Saves a finished trainer ride as an indoor cycling workout with HR and power series.
    func saveWorkout(_ ride: RideRecording, ftp: Int) async throws {
        guard Self.isAvailable, let end = ride.endedAt, end > ride.startedAt else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        try await builder.beginCollection(at: ride.startedAt)

        var samples: [HKSample] = []
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        // Every 5th second is plenty for Health; 1 Hz stays in the TCX sent to Intervals.
        let stride = ride.samples.enumerated().filter { $0.offset % 5 == 0 }.map(\.element)
        for (i, s) in stride.enumerated() {
            let next = i + 1 < stride.count ? stride[i + 1].time : end
            let sampleEnd = max(s.time, min(next, end))
            if let hr = s.heartRate {
                samples.append(HKQuantitySample(type: HKQuantityType(.heartRate), quantity: HKQuantity(unit: bpmUnit, doubleValue: Double(hr)), start: s.time, end: s.time))
            }
            if let w = s.watts {
                samples.append(HKQuantitySample(type: HKQuantityType(.cyclingPower), quantity: HKQuantity(unit: .watt(), doubleValue: Double(w)), start: s.time, end: sampleEnd))
            }
        }
        // Mechanical kJ ≈ kcal burned for cycling at typical efficiency; the usual trainer convention.
        if ride.kilojoules > 0 {
            samples.append(HKQuantitySample(type: HKQuantityType(.activeEnergyBurned), quantity: HKQuantity(unit: .kilocalorie(), doubleValue: ride.kilojoules), start: ride.startedAt, end: end))
        }
        if !samples.isEmpty { try await builder.addSamples(samples) }
        var metadata: [String: Any] = [HKMetadataKeyIndoorWorkout: true, HKMetadataKeyWorkoutBrandName: "Cadencia", HKMetadataKeyExternalUUID: ride.externalID]
        if let avg = ride.averageWatts { metadata["CadenciaAverageWatts"] = avg }
        metadata["CadenciaFTP"] = ftp
        try await builder.addMetadata(metadata)
        try await builder.endCollection(at: end)
        _ = try await builder.finishWorkout()
    }

    // MARK: Queries

    private func quantitySamples(_ id: HKQuantityTypeIdentifier, predicate: NSPredicate) async throws -> [HKQuantitySample] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(id), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        return try await descriptor.result(for: store)
    }

    private func categorySamples(_ id: HKCategoryTypeIdentifier, predicate: NSPredicate) async throws -> [HKCategorySample] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(id), predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        return try await descriptor.result(for: store)
    }
}
