import Foundation

/// Bluetooth GATT UUIDs for the services Cadencia uses. Smart trainers (Wahoo KICKR, Zwift Hub,
/// Tacx, Elite…) expose FTMS; heart-rate straps (Garmin HRM) expose the Heart Rate service.
public enum GATT {
    public static let fitnessMachineService = "1826"
    public static let indoorBikeData = "2AD2"
    public static let fitnessMachineControlPoint = "2AD9"
    public static let fitnessMachineStatus = "2ADA"
    public static let fitnessMachineFeature = "2ACC"

    public static let heartRateService = "180D"
    public static let heartRateMeasurement = "2A37"

    public static let cyclingPowerService = "1818"
    public static let cyclingPowerMeasurement = "2A63"

    public static let batteryService = "180F"
    public static let batteryLevel = "2A19"
}

/// FTMS Indoor Bike Data (0x2AD2), Bluetooth FTMS spec §4.9.
public struct IndoorBikeData: Equatable, Sendable {
    public var speedKmh: Double?
    public var cadenceRPM: Double?
    public var instantaneousPower: Int?
    public var averagePower: Int?
    public var heartRate: Int?
    public var totalDistanceMeters: Int?
    public var resistanceLevel: Int?
    public var elapsedSeconds: Int?

    public init(speedKmh: Double? = nil, cadenceRPM: Double? = nil, instantaneousPower: Int? = nil, averagePower: Int? = nil,
                heartRate: Int? = nil, totalDistanceMeters: Int? = nil, resistanceLevel: Int? = nil, elapsedSeconds: Int? = nil) {
        self.speedKmh = speedKmh
        self.cadenceRPM = cadenceRPM
        self.instantaneousPower = instantaneousPower
        self.averagePower = averagePower
        self.heartRate = heartRate
        self.totalDistanceMeters = totalDistanceMeters
        self.resistanceLevel = resistanceLevel
        self.elapsedSeconds = elapsedSeconds
    }

    public static func parse(_ data: Data) -> IndoorBikeData? {
        var r = ByteReader(data)
        guard let flags = r.u16() else { return nil }
        var out = IndoorBikeData()
        // Bit 0 is "More Data": when CLEAR, instantaneous speed is present.
        if flags & 0x0001 == 0 { out.speedKmh = r.u16().map { Double($0) / 100 } }
        if flags & 0x0002 != 0 { _ = r.u16() }                                  // average speed
        if flags & 0x0004 != 0 { out.cadenceRPM = r.u16().map { Double($0) / 2 } }
        if flags & 0x0008 != 0 { _ = r.u16() }                                  // average cadence
        if flags & 0x0010 != 0 { out.totalDistanceMeters = r.u24() }
        if flags & 0x0020 != 0 { out.resistanceLevel = r.i16().map(Int.init) }
        if flags & 0x0040 != 0 { out.instantaneousPower = r.i16().map(Int.init) }
        if flags & 0x0080 != 0 { out.averagePower = r.i16().map(Int.init) }
        if flags & 0x0100 != 0 { _ = r.u16(); _ = r.u16(); _ = r.u8() }         // expended energy
        if flags & 0x0200 != 0 { out.heartRate = r.u8().map(Int.init) }
        if flags & 0x0400 != 0 { _ = r.u8() }                                   // metabolic equivalent
        if flags & 0x0800 != 0 { out.elapsedSeconds = r.u16().map(Int.init) }
        return out
    }
}

/// FTMS Fitness Machine Control Point (0x2AD9) requests and their indications.
public enum FTMSControl {
    public enum OpCode: UInt8, Sendable {
        case requestControl = 0x00
        case reset = 0x01
        case setTargetResistance = 0x04
        case setTargetPower = 0x05
        case startOrResume = 0x07
        case stopOrPause = 0x08
        case setIndoorBikeSimulation = 0x11
        case response = 0x80
    }

    public enum Result: UInt8, Sendable {
        case reserved = 0x00
        case success = 0x01
        case notSupported = 0x02
        case invalidParameter = 0x03
        case operationFailed = 0x04
        case controlNotPermitted = 0x05
    }

    public static func requestControl() -> Data { Data([OpCode.requestControl.rawValue]) }
    public static func reset() -> Data { Data([OpCode.reset.rawValue]) }
    public static func start() -> Data { Data([OpCode.startOrResume.rawValue]) }
    public static func stop() -> Data { Data([OpCode.stopOrPause.rawValue, 0x01]) }
    public static func pause() -> Data { Data([OpCode.stopOrPause.rawValue, 0x02]) }

    /// ERG mode: the trainer holds this power regardless of cadence.
    public static func setTargetPower(_ watts: Int) -> Data {
        let w = Int16(clamping: watts)
        return Data([OpCode.setTargetPower.rawValue, UInt8(truncatingIfNeeded: w), UInt8(truncatingIfNeeded: w >> 8)])
    }

    /// Simulation mode (free ride): grade in percent, wind in m/s.
    public static func setSimulation(gradePercent: Double, windSpeed: Double = 0, crr: Double = 0.004, cw: Double = 0.51) -> Data {
        let wind = Int16(clamping: Int((windSpeed * 1000).rounded()))
        let grade = Int16(clamping: Int((gradePercent * 100).rounded()))
        return Data([OpCode.setIndoorBikeSimulation.rawValue,
                     UInt8(truncatingIfNeeded: wind), UInt8(truncatingIfNeeded: wind >> 8),
                     UInt8(truncatingIfNeeded: grade), UInt8(truncatingIfNeeded: grade >> 8),
                     UInt8(clamping: Int((crr * 10000).rounded())), UInt8(clamping: Int((cw * 100).rounded()))])
    }

    public struct Response: Equatable, Sendable {
        public var request: OpCode?
        public var result: Result
    }

    public static func parseResponse(_ data: Data) -> Response? {
        guard data.count >= 3, data[data.startIndex] == OpCode.response.rawValue else { return nil }
        return Response(request: OpCode(rawValue: data[data.startIndex + 1]), result: Result(rawValue: data[data.startIndex + 2]) ?? .reserved)
    }
}

/// Heart Rate Measurement (0x2A37).
public struct HeartRateMeasurement: Equatable, Sendable {
    public var bpm: Int
    /// RR intervals in seconds, when the strap sends them (used for HRV during the ride, not for readiness).
    public var rrIntervals: [Double]
    public var sensorContact: Bool?

    public static func parse(_ data: Data) -> HeartRateMeasurement? {
        var r = ByteReader(data)
        guard let flags = r.u8() else { return nil }
        let bpm: Int?
        if flags & 0x01 != 0 { bpm = r.u16().map(Int.init) } else { bpm = r.u8().map(Int.init) }
        guard let bpm else { return nil }
        let contact: Bool? = flags & 0x04 != 0 ? (flags & 0x02 != 0) : nil
        if flags & 0x08 != 0 { _ = r.u16() } // energy expended
        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while let v = r.u16() { rr.append(Double(v) / 1024) }
        }
        return HeartRateMeasurement(bpm: bpm, rrIntervals: rr, sensorContact: contact)
    }
}

/// Cycling Power Measurement (0x2A63). Used when a trainer or power meter exposes CPS but not FTMS.
public struct CyclingPowerMeasurement: Equatable, Sendable {
    public var watts: Int
    public var cumulativeCrankRevolutions: Int?
    /// Last crank event time in 1/1024 s units, wraps at 65536.
    public var lastCrankEventTime: Int?

    public static func parse(_ data: Data) -> CyclingPowerMeasurement? {
        var r = ByteReader(data)
        guard let flags = r.u16(), let watts = r.i16() else { return nil }
        var out = CyclingPowerMeasurement(watts: Int(watts))
        if flags & 0x0001 != 0 { _ = r.u8() }               // pedal power balance
        if flags & 0x0004 != 0 { _ = r.u16() }              // accumulated torque
        if flags & 0x0010 != 0 { _ = r.u32(); _ = r.u16() } // wheel revolution data
        if flags & 0x0020 != 0 {
            out.cumulativeCrankRevolutions = r.u16().map(Int.init)
            out.lastCrankEventTime = r.u16().map(Int.init)
        }
        return out
    }

    /// Cadence from two successive crank samples; nil when nothing moved or time did not advance.
    public static func cadence(previous: CyclingPowerMeasurement, current: CyclingPowerMeasurement) -> Double? {
        guard let r0 = previous.cumulativeCrankRevolutions, let t0 = previous.lastCrankEventTime,
              let r1 = current.cumulativeCrankRevolutions, let t1 = current.lastCrankEventTime else { return nil }
        let revs = (r1 - r0 + 65536) % 65536
        let ticks = (t1 - t0 + 65536) % 65536
        guard revs > 0, ticks > 0 else { return nil }
        return Double(revs) / (Double(ticks) / 1024) * 60
    }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func u8() -> UInt8? {
        guard offset < data.endIndex else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u16() -> UInt16? {
        guard let lo = u8(), let hi = u8() else { return nil }
        return UInt16(lo) | UInt16(hi) << 8
    }

    mutating func i16() -> Int16? { u16().map { Int16(bitPattern: $0) } }

    mutating func u24() -> Int? {
        guard let lo = u8(), let mid = u8(), let hi = u8() else { return nil }
        return Int(lo) | Int(mid) << 8 | Int(hi) << 16
    }

    mutating func u32() -> UInt32? {
        guard let lo = u16(), let hi = u16() else { return nil }
        return UInt32(lo) | UInt32(hi) << 16
    }
}
