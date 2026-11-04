import Foundation

/// Route inspection independent of elevation coverage. Recording gaps stay disconnected.
public struct RouteGeometry: Sendable {
    public let segments: [[RoutePoint]]
    public init(_ segments: [[RoutePoint]]) { self.segments = segments }

    public func point(at distanceKm: Double) -> RoutePoint? {
        guard distanceKm.isFinite else { return nil }
        for segment in segments {
            guard let first = segment.first, let last = segment.last,
                  distanceKm >= first.distanceKm - 0.000_001, distanceKm <= last.distanceKm + 0.000_001 else { continue }
            let distanceKm = min(last.distanceKm, max(first.distanceKm, distanceKm))
            var lo = 0, hi = segment.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if segment[mid].distanceKm < distanceKm { lo = mid + 1 } else { hi = mid }
            }
            if lo == 0 { return first }
            let a = segment[lo - 1], b = segment[lo]
            let span = b.distanceKm - a.distanceKm
            return interpolate(a, b, fraction: span > 0 ? (distanceKm - a.distanceKm) / span : 0)
        }
        return nil
    }

    /// Projects a map tap onto the nearest recorded segment, including between GPX points.
    public func nearestPoint(latitude: Double, longitude: Double) -> RoutePoint? {
        guard latitude.isFinite, longitude.isFinite else { return nil }
        let scale = max(0.001, abs(cos(latitude * .pi / 180)))
        var best: RoutePoint?, bestDistance = Double.infinity
        func consider(_ a: RoutePoint, _ b: RoutePoint) {
            let ax = longitudeDelta(a.longitude - longitude) * scale, ay = a.latitude - latitude
            let dx = longitudeDelta(b.longitude - a.longitude) * scale, dy = b.latitude - a.latitude
            let length = dx * dx + dy * dy
            let f = length > 0 ? min(1, max(0, -(ax * dx + ay * dy) / length)) : 0
            let distance = pow(ax + f * dx, 2) + pow(ay + f * dy, 2)
            if distance < bestDistance { bestDistance = distance; best = interpolate(a, b, fraction: f) }
        }
        for segment in segments {
            if segment.count == 1, let point = segment.first { consider(point, point) }
            for (a, b) in zip(segment, segment.dropFirst()) { consider(a, b) }
        }
        return best
    }

    private func interpolate(_ a: RoutePoint, _ b: RoutePoint, fraction: Double) -> RoutePoint {
        let f = min(1, max(0, fraction))
        let elevation = f == 0 ? a.elevationM : f == 1 ? b.elevationM : a.elevationM.flatMap { start in b.elevationM.map { start + ($0 - start) * f } }
        return RoutePoint(latitude: a.latitude + (b.latitude - a.latitude) * f,
                          longitude: longitudeDelta(a.longitude + longitudeDelta(b.longitude - a.longitude) * f),
                          elevationM: elevation, distanceKm: a.distanceKm + (b.distanceKm - a.distanceKm) * f)
    }

    private func longitudeDelta(_ degrees: Double) -> Double {
        let wrapped = (degrees + 180).truncatingRemainder(dividingBy: 360)
        return (wrapped < 0 ? wrapped + 360 : wrapped) - 180
    }
}
