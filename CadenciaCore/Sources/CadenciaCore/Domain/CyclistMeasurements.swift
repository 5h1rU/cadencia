import Foundation

/// App-owned profile extension. A new sync never overwrites an explicitly confirmed measurement
/// with an older sample. Unknown measurements remain nil, including relative power.
public struct CyclistMeasurements: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case athlete, appleHealth, intervals }
    public struct Measurement: Codable, Equatable, Sendable {
        public var value: Double
        public var measuredAt: Date
        public var source: Source
        public init(value: Double, measuredAt: Date, source: Source) {
            self.value = value; self.measuredAt = measuredAt; self.source = source
        }
    }
    public var weight: Measurement?
    public var height: Measurement?
    public init(weight: Measurement? = nil, height: Measurement? = nil) { self.weight = weight; self.height = height }

    public mutating func merge(_ other: Self) {
        if let v = other.weight, v.value.isFinite, (20...350).contains(v.value), weight.map({ v.measuredAt > $0.measuredAt }) ?? true { weight = v }
        if let v = other.height, v.value.isFinite, (80...250).contains(v.value), height.map({ v.measuredAt > $0.measuredAt }) ?? true { height = v }
    }

    public static func wattsPerKg(ftp: Int?, weightKg: Double?) -> Double? {
        guard let ftp, ftp > 0, let weightKg, weightKg.isFinite, weightKg > 0 else { return nil }
        return Double(ftp) / weightKg
    }
}
