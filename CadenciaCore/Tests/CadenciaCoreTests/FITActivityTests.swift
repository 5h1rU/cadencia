import XCTest
@testable import CadenciaCore

final class FITActivityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func ride() -> RideRecording {
        RideRecording(id: UUID(uuidString: "C03765C0-2295-4DD3-B899-42466FF0905B")!, athleteID: "i1",
                      workout: Workout(name: "Endurance", kind: .endurance, steps: []),
                      startedAt: start, endedAt: start.addingTimeInterval(3), samples: [
            RideSample(time: start.addingTimeInterval(1), watts: 150, heartRate: 120, cadence: 88, targetWatts: 155,
                       speedKmh: 36, distanceMeters: 10),
            RideSample(time: start.addingTimeInterval(2), watts: 160, heartRate: 121, cadence: 90, targetWatts: 165,
                       speedKmh: 37.8, distanceMeters: 20.5),
            RideSample(time: start.addingTimeInterval(3))
        ], ftpUsed: 250)
    }

    func testHeaderChecksumsAndRequiredActivityMessages() throws {
        let fit = FITActivityEncoder.encode(ride())
        XCTAssertEqual(fit[0], 14)
        XCTAssertEqual(fit[1], 0x20)
        XCTAssertEqual(String(data: fit[8..<12], encoding: .ascii), ".FIT")
        XCTAssertEqual(readUInt(fit[4..<8]), UInt64(fit.count - 16))
        XCTAssertEqual(checksum(fit.prefix(14)), 0, "header CRC")
        XCTAssertEqual(checksum(fit), 0, "file CRC")
        var corrupted = fit
        corrupted[fit.count / 2] ^= 1
        XCTAssertNotEqual(checksum(corrupted), 0)
        XCTAssertEqual(checksum(Data("123456789".utf8)), 0xBB3D)

        let messages = try decode(fit)
        XCTAssertEqual(messages.first?.number, 0)
        XCTAssertEqual(messages.first?.value(0), 4, "activity file, not a workout file")
        XCTAssertEqual(messages.filter { $0.number == 20 }.count, 3)
        XCTAssertEqual(messages.filter { $0.number == 19 }.count, 1)
        XCTAssertEqual(messages.filter { $0.number == 18 }.count, 1)
        XCTAssertEqual(messages.last?.number, 34)
        XCTAssertEqual(FITActivityEncoder.encode(ride()), fit, "retrying a saved ride produces identical bytes")
    }

    func testSensorStreamsUnitsDeveloperTargetsAndSummaries() throws {
        let messages = try decode(FITActivityEncoder.encode(ride()))
        let records = messages.filter { $0.number == 20 }
        XCTAssertEqual(records[0].value(253), 1_068_934_401, "seconds since the FIT epoch")
        XCTAssertEqual(records[0].value(7), 150)
        XCTAssertEqual(records[1].value(7), 160)
        XCTAssertEqual(records[1].value(3), 121)
        XCTAssertEqual(records[1].value(4), 90)
        XCTAssertEqual(records[1].value(6), 10500, "37.8 km/h = 10.5 m/s, FIT scale 1000")
        XCTAssertEqual(records[1].value(5), 2050, "distance scale 100")
        XCTAssertEqual(readUInt(try XCTUnwrap(records[1].developer[0])), 165)
        let description = try XCTUnwrap(messages.first { $0.number == 206 })
        XCTAssertEqual(String(data: try XCTUnwrap(description.fields[3]).dropLast(), encoding: .utf8), "target_power")
        XCTAssertEqual(String(data: try XCTUnwrap(description.fields[8]).dropLast(), encoding: .utf8), "watts")

        let session = try XCTUnwrap(messages.first { $0.number == 18 })
        XCTAssertEqual(session.value(5), 2, "cycling")
        XCTAssertEqual(session.value(6), 6, "indoor cycling")
        XCTAssertEqual(session.value(7), 3000)
        XCTAssertEqual(session.value(8), 3000)
        XCTAssertEqual(session.value(9), 2050)
        XCTAssertEqual(session.value(20), 155)
        XCTAssertEqual(session.value(21), 160)
        XCTAssertEqual(session.value(45), 250)
        XCTAssertEqual(session.value(48), 310, "work is joules; do not manufacture a calorie estimate")
        XCTAssertNil(session.fields[11], "no measured calories")
    }

    func testMissingAndOutOfRangeValuesUseInvalidSentinelsWhileZeroIsRetained() throws {
        var recording = ride()
        recording.samples = [
            RideSample(time: start, watts: 0, heartRate: 0, cadence: 0, targetWatts: 0, speedKmh: 0, distanceMeters: 0),
            RideSample(time: start.addingTimeInterval(1), watts: -1, heartRate: 500, cadence: -1, targetWatts: 70000,
                       speedKmh: .nan, distanceMeters: .infinity),
            RideSample(time: start.addingTimeInterval(2))
        ]
        let records = try decode(FITActivityEncoder.encode(recording)).filter { $0.number == 20 }
        for field: UInt8 in [7, 4, 6, 5] { XCTAssertEqual(records[0].value(field), 0) }
        for record in records.dropFirst() {
            XCTAssertEqual(record.value(7), 0xFFFF)
            XCTAssertEqual(record.value(3), 0xFF)
            XCTAssertEqual(record.value(4), 0xFF)
            XCTAssertEqual(record.value(6), 0xFFFF)
            XCTAssertEqual(record.value(5), 0xFFFFFFFF)
            XCTAssertEqual(readUInt(try XCTUnwrap(record.developer[0])), 0xFFFF)
        }
    }

    func testPauseEventsSeparateTimerTimeFromElapsedTimeAndFollowFinalSample() throws {
        var recording = ride()
        recording.endedAt = start.addingTimeInterval(103)
        recording.samples[2].time = start.addingTimeInterval(103)
        recording.timerEvents = [
            .init(time: start, kind: .start), .init(time: start.addingTimeInterval(2), kind: .stop),
            .init(time: start.addingTimeInterval(102), kind: .start), .init(time: start.addingTimeInterval(103), kind: .stop)
        ]
        let messages = try decode(FITActivityEncoder.encode(recording))
        let session = try XCTUnwrap(messages.first { $0.number == 18 })
        XCTAssertEqual(session.value(7), 103000)
        XCTAssertEqual(session.value(8), 3000)
        let events = messages.filter { $0.number == 21 }
        XCTAssertEqual(events.map { $0.value(1) }, [0, 4, 0, 4])
        let finalRecord = try XCTUnwrap(messages.lastIndex { $0.number == 20 })
        let finalStop = try XCTUnwrap(messages.lastIndex { $0.number == 21 })
        XCTAssertGreaterThan(finalStop, finalRecord)
        XCTAssertEqual(messages.last?.value(0), 3000)
    }

    func testOlderSavedJSONStillDecodesAndExportsWithoutInventingExtraSensorData() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ride())) as? [String: Any])
        json.removeValue(forKey: "timerEvents")
        json.removeValue(forKey: "ftpUsed")
        var samples = try XCTUnwrap(json["samples"] as? [[String: Any]])
        for i in samples.indices {
            samples[i].removeValue(forKey: "speedKmh")
            samples[i].removeValue(forKey: "distanceMeters")
        }
        json["samples"] = samples
        let restored = try JSONDecoder().decode(RideRecording.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.timerEvents)
        XCTAssertNil(restored.samples[0].speedKmh)
        XCTAssertEqual(restored.externalID, ride().externalID)
        let messages = try decode(FITActivityEncoder.encode(restored))
        let session = try XCTUnwrap(messages.first { $0.number == 18 })
        XCTAssertEqual(session.value(8), 3000, "legacy recordings have no pause history to reconstruct")
        XCTAssertEqual(session.value(45), 0xFFFF)
        XCTAssertEqual(session.value(9), 0xFFFFFFFF)
    }

    func testEmptyRideIsStructurallyCompleteWithUnknownMeasurements() throws {
        var recording = ride()
        recording.samples = []
        recording.endedAt = start
        let messages = try decode(FITActivityEncoder.encode(recording))
        let record = try XCTUnwrap(messages.first { $0.number == 20 })
        XCTAssertEqual(record.value(7), 0xFFFF)
        XCTAssertEqual(messages.last?.value(0), 0)
    }

    // A small generic reader checks the public binary contract rather than encoder internals.
    private struct Message {
        var number: UInt16
        var fields: [UInt8: Data]
        var developer: [UInt8: Data]
        func value(_ field: UInt8) -> UInt64? { fields[field].map(readUInt) }
    }

    private func decode(_ data: Data) throws -> [Message] {
        struct Definition { var number: UInt16; var fields: [(UInt8, Int)]; var developer: [(UInt8, Int)] }
        var definitions: [UInt8: Definition] = [:]
        var messages: [Message] = []
        var offset = Int(data[0])
        let end = offset + Int(readUInt(data[4..<8]))
        while offset < end {
            let header = data[offset]; offset += 1
            let local = header & 0x0F
            if header & 0x40 != 0 {
                XCTAssertEqual(data[offset + 1], 0, "little endian definition")
                let number = UInt16(readUInt(data[(offset + 2)..<(offset + 4)]))
                let count = Int(data[offset + 4]); offset += 5
                var fields: [(UInt8, Int)] = []
                for _ in 0..<count {
                    fields.append((data[offset], Int(data[offset + 1]))); offset += 3
                }
                var developer: [(UInt8, Int)] = []
                if header & 0x20 != 0 {
                    let count = Int(data[offset]); offset += 1
                    for _ in 0..<count {
                        developer.append((data[offset], Int(data[offset + 1]))); offset += 3
                    }
                }
                definitions[local] = Definition(number: number, fields: fields, developer: developer)
            } else {
                let definition = try XCTUnwrap(definitions[local])
                var message = Message(number: definition.number, fields: [:], developer: [:])
                for (number, size) in definition.fields {
                    message.fields[number] = Data(data[offset..<(offset + size)]); offset += size
                }
                for (number, size) in definition.developer {
                    message.developer[number] = Data(data[offset..<(offset + size)]); offset += size
                }
                messages.append(message)
            }
        }
        XCTAssertEqual(offset, end)
        return messages
    }

    // Nibble-table CRC, independently checked against the standard CRC-16/ARC test vector.
    private func checksum(_ bytes: Data) -> UInt16 {
        let table: [UInt16] = [0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
                               0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400]
        return bytes.reduce(UInt16(0)) { crc, byte in
            let low = (crc >> 4) ^ table[Int(crc & 15)] ^ table[Int(byte & 15)]
            return (low >> 4) ^ table[Int(low & 15)] ^ table[Int(byte >> 4)]
        }
    }
}

private func readUInt(_ bytes: Data) -> UInt64 {
    bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
}
