import Foundation

/// Distance-based terrain analysis. Gaps in the recording/elevation never join separate climbs.
public struct ClimbAnalyzer: Sendable {
    public static let version = 1
    public struct Terrain: Sendable {
        public var profileSegments: [[ClimbProfilePoint]]
        public var climbs: [RouteClimb]
    }
    public init() {}

    public func analyze(_ segments: [[RoutePoint]]) throws -> Terrain {
        var profiles: [[ClimbProfilePoint]] = [], climbs: [RouteClimb] = []
        let totalKm = segments.reduce(0.0) { $0 + max(0, ($1.last?.distanceKm ?? 0) - ($1.first?.distanceKm ?? 0)) }
        let spacing = max(0.025, totalKm / 12_000)
        for segment in segments {
            var run: [RoutePoint] = []
            func finishRun() throws {
                guard run.count >= 2 else { run = []; return }
                let profile = try makeProfile(run, spacingKm: spacing)
                if profile.count >= 2 {
                    profiles.append(graded(profile))
                    climbs.append(contentsOf: try detectClimbs(profile))
                }
                run = []
            }
            for (index, point) in segment.enumerated() {
                if index % 256 == 0 { try Task.checkCancellation() }
                guard point.elevationM != nil else { try finishRun(); continue }
                if let previous = run.last, point.distanceKm <= previous.distanceKm { continue }
                run.append(point)
            }
            try finishRun()
        }
        return Terrain(profileSegments: profiles, climbs: climbs.sorted { $0.startKm < $1.startKm })
    }

    private func makeProfile(_ points: [RoutePoint], spacingKm: Double) throws -> [ClimbProfilePoint] {
        func sample(_ p: RoutePoint, span: Double) -> ClimbProfilePoint {
            ClimbProfilePoint(distanceKm: p.distanceKm, altitudeM: p.elevationM!, latitude: p.latitude,
                              longitude: p.longitude, gradientPercent: nil, sourceSpanM: span)
        }
        var output = [sample(points[0], span: (points[1].distanceKm - points[0].distanceKm) * 1_000)]
        var next = points[0].distanceKm + spacingKm
        for index in 1..<points.count {
            if index % 256 == 0 { try Task.checkCancellation() }
            let a = points[index - 1], b = points[index]
            let span = (b.distanceKm - a.distanceKm) * 1_000
            if span > 100 {
                // Preserve sparse GPX corners without fabricating a high-resolution gradient profile.
                output.append(sample(b, span: span))
                next = b.distanceKm + spacingKm
                continue
            }
            while next < b.distanceKm {
                let f = (next - a.distanceKm) / (b.distanceKm - a.distanceKm)
                output.append(ClimbProfilePoint(distanceKm: next, altitudeM: a.elevationM! + (b.elevationM! - a.elevationM!) * f,
                                                latitude: a.latitude + (b.latitude - a.latitude) * f,
                                                longitude: a.longitude + (b.longitude - a.longitude) * f,
                                                gradientPercent: nil, sourceSpanM: max(span, spacingKm * 1_000)))
                next += spacingKm
            }
        }
        if output.last?.distanceKm != points.last?.distanceKm {
            let last = points.last!, previous = points[points.count - 2]
            output.append(sample(last, span: max((last.distanceKm - previous.distanceKm) * 1_000, spacingKm * 1_000)))
        }
        let original = output
        if output.count > 2 {
            for index in 1..<(output.count - 1) where original[index - 1...index + 1].allSatisfy({ $0.sourceSpanM <= 100 }) {
                output[index].altitudeM = original[index - 1].altitudeM * 0.25 + original[index].altitudeM * 0.5 + original[index + 1].altitudeM * 0.25
            }
        }
        return output
    }

    private func detectClimbs(_ profile: [ClimbProfilePoint]) throws -> [RouteClimb] {
        var result: [RouteClimb] = [], valley = 0, peak = 0
        func finish() throws {
            let length = profile[peak].distanceKm - profile[valley].distanceKm
            let rise = profile[peak].altitudeM - profile[valley].altitudeM
            guard length >= 0.5, rise >= 50 else { return }
            let points = graded(Array(profile[valley...peak]))
            let gain = zip(points, points.dropFirst()).reduce(0.0) { $0 + max(0, $1.1.altitudeM - $1.0.altitudeM) }
            let detail = try details(points)
            result.append(RouteClimb(startKm: points[0].distanceKm, distanceKm: length, gainM: gain,
                                     averageGradient: rise / (length * 10), detail: detail))
        }
        for index in 1..<profile.count {
            if index % 256 == 0 { try Task.checkCancellation() }
            let altitude = profile[index].altitudeM
            if altitude > profile[peak].altitudeM + 0.1 { peak = index }
            let rise = profile[peak].altitudeM - profile[valley].altitudeM
            let loss = profile[peak].altitudeM - altitude
            let reliefKm = profile[index].distanceKm - profile[peak].distanceKm
            let descentLimit = max(15, min(40, rise * 0.15))
            if (loss >= descentLimit && (reliefKm >= 0.1 || altitude < profile[valley].altitudeM)) || reliefKm >= 0.6 {
                try finish()
                valley = index; peak = index
            } else if altitude < profile[valley].altitudeM || (rise < 3 && altitude <= profile[valley].altitudeM + 0.1) {
                valley = index; peak = index
            }
        }
        try finish()
        return result
    }

    private func graded(_ input: [ClimbProfilePoint]) -> [ClimbProfilePoint] {
        guard input.count >= 2 else { return input }
        let sampler = ProfileSampler(input)
        let start = input[0].distanceKm, end = input.last!.distanceKm
        return input.map { point in
            var point = point
            let lo = max(start, min(point.distanceKm - 0.05, end - 0.1))
            let hi = min(end, max(point.distanceKm + 0.05, start + 0.1))
            if hi - lo >= 0.05, sampler.reliable(from: lo, to: hi), let a = sampler.point(at: lo), let b = sampler.point(at: hi) {
                point.gradientPercent = (b.altitudeM - a.altitudeM) / ((hi - lo) * 10)
            }
            return point
        }
    }

    private func details(_ points: [ClimbProfilePoint]) throws -> ClimbDetail {
        let sampler = ProfileSampler(points)
        let start = points[0].distanceKm, end = points.last!.distanceKm
        func section(from lo: Double, to hi: Double) -> ClimbSection {
            let a = sampler.point(at: lo)!, b = sampler.point(at: hi)!
            let gradient = sampler.reliable(from: lo, to: hi) ? (b.altitudeM - a.altitudeM) / ((hi - lo) * 10) : nil
            return ClimbSection(startKm: lo, endKm: hi, gainM: max(0, b.altitudeM - a.altitudeM), averageGradient: gradient)
        }
        func steepest(_ km: Double) throws -> ClimbSection? {
            guard end - start >= km else { return nil }
            var best: ClimbSection?
            for (index, point) in points.enumerated() {
                if index % 256 == 0 { try Task.checkCancellation() }
                guard point.distanceKm + km <= end + 0.000_001 else { continue }
                let candidate = section(from: point.distanceKm, to: min(end, point.distanceKm + km))
                if let grade = candidate.averageGradient, grade > 0, grade > (best?.averageGradient ?? -.infinity) { best = candidate }
            }
            return best
        }
        var splits: [ClimbSection] = [], cursor = start
        while cursor < end - 0.000_001 {
            let next = min(end, cursor + 1)
            splits.append(section(from: cursor, to: next)); cursor = next
        }
        return ClimbDetail(profile: points, kilometreSplits: splits,
                           steepest250m: try steepest(0.25), steepest1km: try steepest(1))
    }
}

/// Binary-search interpolation for chart inspection and sustained-gradient windows.
public struct ProfileSampler: Sendable {
    public let points: [ClimbProfilePoint]
    private let unreliablePrefix: [Int]
    public init(_ points: [ClimbProfilePoint]) {
        self.points = points
        var prefix = [0]
        for point in points { prefix.append(prefix.last! + (point.sourceSpanM > 100 ? 1 : 0)) }
        unreliablePrefix = prefix
    }
    private func index(at distance: Double) -> Int {
        var lo = 0, hi = points.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].distanceKm < distance { lo = mid + 1 } else { hi = mid }
        }
        return min(lo, points.count - 1)
    }
    public func reliable(from start: Double, to end: Double) -> Bool {
        guard !points.isEmpty else { return false }
        let lo = max(0, index(at: start) - 1), hi = index(at: end)
        return unreliablePrefix[hi + 1] - unreliablePrefix[lo] == 0
    }
    public func point(at distance: Double) -> ClimbProfilePoint? {
        guard let first = points.first, let last = points.last, distance >= first.distanceKm - 0.000_001, distance <= last.distanceKm + 0.000_001 else { return nil }
        let hi = index(at: distance)
        if hi == 0 { return first }
        let a = points[hi - 1], b = points[hi]
        let f = min(1, max(0, (distance - a.distanceKm) / (b.distanceKm - a.distanceKm)))
        var p = a
        p.distanceKm = distance; p.altitudeM += (b.altitudeM - a.altitudeM) * f
        p.latitude += (b.latitude - a.latitude) * f; p.longitude += (b.longitude - a.longitude) * f
        p.gradientPercent = a.gradientPercent.flatMap { ga in b.gradientPercent.map { ga + ($0 - ga) * f } }
        p.sourceSpanM = max(a.sourceSpanM, b.sourceSpanM)
        return p
    }
}
