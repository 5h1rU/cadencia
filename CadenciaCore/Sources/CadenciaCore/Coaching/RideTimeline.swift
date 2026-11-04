import Foundation

/// Aligns observations to active workout time. A sensor observation is not a second: UI scheduling
/// can drift, timers can pause, and sensor data can be missing. Never substitute array indices for time.
public struct RideTimeline: Sendable {
    public struct Observation: Sendable {
        public var sample: RideSample
        public var start: TimeInterval
        public var end: TimeInterval
    }
    public var duration: TimeInterval
    public var observations: [Observation]
    /// The same freshness horizon used when recording live sensor values. Longer gaps remain unknown.
    public static let maximumSampleHold: TimeInterval = 5

    public init(samples: [RideSample], startedAt: Date? = nil, timerEvents: [RideTimerEvent]? = nil, endedAt: Date? = nil) {
        let origin = startedAt ?? samples.first?.time ?? Date(timeIntervalSince1970: 0)
        let end = endedAt ?? samples.last?.time.addingTimeInterval(1) ?? origin
        struct Segment { var start: Date; var end: Date; var offset: TimeInterval; var endElapsed: TimeInterval }
        var segments: [Segment] = []
        var runningSince: RideTimerEvent?
        var total: TimeInterval = 0
        for event in (timerEvents ?? []).sorted(by: { $0.time < $1.time }) {
            if event.kind == .start { runningSince = runningSince ?? event }
            else if let start = runningSince {
                let stop = min(event.time, end)
                if stop >= start.time {
                    let offset = start.workoutElapsed ?? total
                    let activeEnd = event.workoutElapsed ?? (offset + stop.timeIntervalSince(start.time))
                    segments.append(Segment(start: start.time, end: stop, offset: offset, endElapsed: max(offset, activeEnd)))
                    total = max(total, activeEnd)
                }
                runningSince = nil
            }
        }
        if let start = runningSince, end >= start.time {
            let offset = start.workoutElapsed ?? total
            let activeEnd = max(offset + end.timeIntervalSince(start.time), samples.last?.workoutElapsed ?? 0)
            segments.append(Segment(start: start.time, end: end, offset: offset, endElapsed: activeEnd))
            total = max(total, activeEnd)
        }
        struct Point { var sample: RideSample; var elapsed: TimeInterval; var segmentEnd: TimeInterval }
        let points = samples.compactMap { sample -> Point? in
            let segment: Segment?
            if let clock = sample.workoutElapsed {
                segment = segments.first { clock >= $0.offset && clock < $0.endElapsed }
            } else { segment = segments.first { sample.time >= $0.start && sample.time <= $0.end } }
            let clock: TimeInterval
            if let recorded = sample.workoutElapsed, recorded.isFinite, recorded >= 0 { clock = recorded }
            else if let segment { clock = segment.offset + sample.time.timeIntervalSince(segment.start) }
            else if segments.isEmpty { clock = sample.time.timeIntervalSince(origin) }
            else { return nil } // a measurement recorded while paused cannot belong to a work block
            guard clock.isFinite, clock >= 0 else { return nil }
            let segmentEnd = segment?.endElapsed ?? .infinity
            return Point(sample: sample, elapsed: clock, segmentEnd: segmentEnd)
        }.sorted { $0.elapsed < $1.elapsed }
        let inferredEnd = points.last.map { $0.elapsed + (endedAt == nil ? 1 : 0) } ?? 0
        let activeDuration = max(segments.isEmpty ? max(0, end.timeIntervalSince(origin)) : total, inferredEnd)
        duration = activeDuration
        observations = points.indices.compactMap { index in
            let point = points[index]
            let next = points.indices.contains(index + 1) ? points[index + 1].elapsed : activeDuration
            let stop = min(next, point.elapsed + Self.maximumSampleHold, point.segmentEnd, activeDuration)
            guard stop > point.elapsed else { return nil }
            return Observation(sample: point.sample, start: point.elapsed, end: stop)
        }
    }
}
