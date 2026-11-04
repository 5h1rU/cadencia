import Foundation

/// Writes FIT activity files without Apple frameworks or a runtime SDK dependency.
/// Message numbers, field types and scales follow Garmin's FIT profile 21.218:
/// https://developer.garmin.com/fit/articles/cookbook/encoding_activity_files.html
public enum FITActivityEncoder {
    public static func encode(_ ride: RideRecording) -> Data {
        let end = ride.endedAt ?? ride.samples.last?.time ?? ride.startedAt
        let events = ride.timerEvents?.isEmpty == false ? ride.timerEvents! : [
            RideTimerEvent(time: ride.startedAt, kind: .start), RideTimerEvent(time: end, kind: .stop)
        ]
        let elapsed = max(0, end.timeIntervalSince(ride.startedAt))
        let timer = timerDuration(events: events, end: end)
        var writer = FITWriter()
        let uuid = ride.id.uuid
        let serial = UInt32(uuid.0) | UInt32(uuid.1) << 8 | UInt32(uuid.2) << 16 | UInt32(uuid.3) << 24
        writer.write(local: 0, global: 0, fields: [
            .enumValue(0, 4), // file.type = activity
            .uint16(1, 255), // manufacturer = development; never claim a Garmin device
            .uint16(2, 0), .uint32(3, max(serial, 1), base: 0x8C),
            .timestamp(4, ride.startedAt), .string(8, "Cadencia")
        ])
        writer.write(local: 1, global: 23, fields: [
            .timestamp(253, ride.startedAt), .uint8(0, 0), // device_index = creator
            .uint16(2, 255), .uint16(4, 0), .string(27, "Cadencia")
        ])

        // FIT has no native record field for an ERG power target. Describe a developer field so
        // readers can retain each recorded target, including ramps and manual intensity changes.
        // This application id is stable across rides; it is not an athlete or ride identifier.
        writer.write(local: 2, global: 207, fields: [
            FITField(number: 1, base: 0x0D, bytes: Data([
                0xCA, 0xDE, 0x6C, 0x1A, 0x47, 0x5F, 0x4E, 0x65,
                0x92, 0x91, 0x83, 0x6F, 0x31, 0xA2, 0x08, 0x70
            ])), .uint8(3, 0)
        ])
        writer.write(local: 3, global: 206, fields: [
            .uint8(0, 0), .uint8(1, 0), .uint8(2, 0x84), // developer index, field number, uint16
            .string(3, "target_power"), .uint8(6, 1), .string(8, "watts")
        ])

        var nextEvent = 0
        let samples = ride.samples.isEmpty ? [RideSample(time: ride.startedAt)] : ride.samples
        for sample in samples {
            // A start precedes a same-time sample; a stop follows it.
            while nextEvent < events.count, events[nextEvent].time < sample.time ||
                    (events[nextEvent].time == sample.time && events[nextEvent].kind == .start) {
                write(events[nextEvent], to: &writer)
                nextEvent += 1
            }
            writer.write(local: 5, global: 20, fields: [
                .timestamp(253, sample.time), .uint16(7, sample.watts),
                .uint8(3, sample.heartRate), .uint8(4, sample.cadence),
                .uint16(6, scaled(sample.speedKmh.map { $0 / 3.6 }, by: 1000)),
                .uint32(5, scaled(sample.distanceMeters, by: 100))
            ], targetWatts: sample.targetWatts, hasTargetField: true)
        }
        while nextEvent < events.count {
            write(events[nextEvent], to: &writer)
            nextEvent += 1
        }

        // A single lap represents the complete recording. Intervals can calculate its own workout
        // intervals from the actual streams and the paired calendar event.
        let power = ride.samples.compactMap(\.watts).filter { (0..<65535).contains($0) }
        let heartRate = ride.samples.compactMap(\.heartRate).filter { (1..<255).contains($0) }
        let cadence = ride.samples.compactMap(\.cadence).filter { (0..<255).contains($0) }
        let distance = ride.samples.compactMap(\.distanceMeters).filter { $0.isFinite && $0 >= 0 }.max()
        let work = power.isEmpty ? nil : power.reduce(0, +) // one-second power samples, joules
        writer.write(local: 6, global: 19, fields: [
            .uint16(254, 0), .timestamp(253, end), .enumValue(0, 9), .enumValue(1, 1),
            .timestamp(2, ride.startedAt), .enumValue(25, 2), .enumValue(39, 6),
            .uint32(7, scaled(elapsed, by: 1000)), .uint32(8, scaled(timer, by: 1000)),
            .uint32(9, scaled(distance, by: 100)),
            .uint16(19, average(power)), .uint16(20, power.max()),
            .uint8(15, average(heartRate)), .uint8(16, heartRate.max()),
            .uint8(17, average(cadence)), .uint8(18, cadence.max()),
            .uint32(41, work), .enumValue(24, 7) // lap_trigger = session_end
        ])
        writer.write(local: 7, global: 18, fields: [
            .uint16(254, 0), .timestamp(253, end), .enumValue(0, 8), .enumValue(1, 1),
            .timestamp(2, ride.startedAt), .enumValue(5, 2), .enumValue(6, 6), // cycling, indoor_cycling
            .uint32(7, scaled(elapsed, by: 1000)), .uint32(8, scaled(timer, by: 1000)),
            .uint32(9, scaled(distance, by: 100)),
            .uint16(20, average(power)), .uint16(21, power.max()),
            .uint8(16, average(heartRate)), .uint8(17, heartRate.max()),
            .uint8(18, average(cadence)), .uint8(19, cadence.max()),
            .uint16(25, 0), .uint16(26, 1), .uint16(45, ride.ftpUsed), .uint32(48, work)
        ])
        writer.write(local: 8, global: 34, fields: [
            .timestamp(253, end), .uint32(0, scaled(timer, by: 1000)), .uint16(1, 1),
            .enumValue(2, 0), .enumValue(3, 26), .enumValue(4, 1)
        ])
        return writer.finish()
    }

    private static func write(_ event: RideTimerEvent, to writer: inout FITWriter) {
        writer.write(local: 4, global: 21, fields: [
            .timestamp(253, event.time), .enumValue(0, 0), // timer
            .enumValue(1, event.kind == .start ? 0 : 4), .uint8(4, 0) // start / stop_all
        ])
    }

    private static func timerDuration(events: [RideTimerEvent], end: Date) -> TimeInterval {
        var start: Date?
        var seconds: TimeInterval = 0
        for event in events {
            if event.kind == .start { start = start ?? event.time }
            else if let runningSince = start {
                seconds += max(0, event.time.timeIntervalSince(runningSince))
                start = nil
            }
        }
        if let start { seconds += max(0, end.timeIntervalSince(start)) }
        return seconds
    }

    private static func average(_ values: [Int]) -> Int? {
        values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    private static func scaled(_ value: Double?, by scale: Double) -> Int? {
        guard let value, value.isFinite, value >= 0, value * scale < Double(UInt32.max) else { return nil }
        return Int((value * scale).rounded())
    }
}

private struct FITField {
    var number: UInt8
    var base: UInt8
    var bytes: Data

    static func enumValue(_ number: UInt8, _ value: Int) -> Self { uint8(number, value, base: 0) }

    static func uint8(_ number: UInt8, _ value: Int?, base: UInt8 = 0x02) -> Self {
        let encoded = value.flatMap(UInt8.init(exactly:)).flatMap { $0 < .max ? $0 : nil } ?? .max
        return Self(number: number, base: base, bytes: Data([encoded]))
    }

    static func uint16(_ number: UInt8, _ value: Int?) -> Self {
        let encoded = value.flatMap(UInt16.init(exactly:)).flatMap { $0 < .max ? $0 : nil } ?? .max
        return Self(number: number, base: 0x84, bytes: littleEndian(encoded))
    }

    static func uint32(_ number: UInt8, _ value: Int?) -> Self {
        uint32(number, value.flatMap(UInt32.init(exactly:)))
    }

    static func uint32(_ number: UInt8, _ value: UInt32?, base: UInt8 = 0x86) -> Self {
        Self(number: number, base: base, bytes: littleEndian(value ?? .max))
    }

    static func timestamp(_ number: UInt8, _ date: Date) -> Self {
        let seconds = date.timeIntervalSince1970 - 631_065_600 // FIT epoch: 1989-12-31 UTC
        let value = seconds.isFinite && seconds >= 0 && seconds < Double(UInt32.max) ? UInt32(seconds) : nil
        return uint32(number, value)
    }

    static func string(_ number: UInt8, _ value: String) -> Self {
        var bytes = Data(value.utf8.prefix(254))
        while String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        bytes.append(0)
        return Self(number: number, base: 0x07, bytes: bytes)
    }
}

private struct FITWriter {
    private var data = Data()
    private var definitions: [UInt8: Data] = [:]

    mutating func write(local: UInt8, global: UInt16, fields: [FITField], targetWatts: Int? = nil, hasTargetField: Bool = false) {
        var definition = Data([0x40 | (hasTargetField ? 0x20 : 0) | local, 0, 0]) // definition, reserved, little endian
        definition.append(littleEndian(global))
        definition.append(UInt8(fields.count))
        for field in fields { definition.append(contentsOf: [field.number, UInt8(field.bytes.count), field.base]) }
        if hasTargetField { definition.append(contentsOf: [1, 0, 2, 0]) } // count, field number, size, developer index
        if definitions[local] != definition {
            data.append(definition)
            definitions[local] = definition
        }
        data.append(local)
        for field in fields { data.append(field.bytes) }
        if hasTargetField { data.append(FITField.uint16(0, targetWatts).bytes) }
    }

    func finish() -> Data {
        var file = Data([14, 0x20]) // header size, protocol 2.0
        file.append(littleEndian(UInt16(21218))) // FIT profile 21.218
        file.append(littleEndian(UInt32(data.count)))
        file.append(contentsOf: [0x2E, 0x46, 0x49, 0x54]) // .FIT
        file.append(littleEndian(crc(file)))
        file.append(data)
        file.append(littleEndian(crc(file)))
        return file
    }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    var encoded = value.littleEndian
    return withUnsafeBytes(of: &encoded) { Data($0) }
}

private func crc(_ data: Data) -> UInt16 {
    var result: UInt16 = 0
    for byte in data {
        result ^= UInt16(byte)
        for _ in 0..<8 { result = result & 1 == 0 ? result >> 1 : (result >> 1) ^ 0xA001 }
    }
    return result
}
