import Foundation

/// One second of ride data from the trainer and heart-rate strap.
public struct RideSample: Codable, Equatable, Sendable {
    public var time: Date
    public var watts: Int?
    public var heartRate: Int?
    public var cadence: Int?
    public var targetWatts: Int?

    public init(time: Date, watts: Int? = nil, heartRate: Int? = nil, cadence: Int? = nil, targetWatts: Int? = nil) {
        self.time = time
        self.watts = watts
        self.heartRate = heartRate
        self.cadence = cadence
        self.targetWatts = targetWatts
    }
}

/// A completed (or in-progress) indoor ride. Committed locally before anything is uploaded.
public struct RideRecording: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// The account the ride belongs to. Never uploaded to a different athlete.
    public var athleteID: String
    public var workout: Workout
    public var plannedSessionID: UUID?
    public var intervalsEventID: Int?
    public var startedAt: Date
    public var endedAt: Date?
    public var samples: [RideSample]
    public var feedback: SubjectiveFeedback?
    /// What Intervals computed once the upload was processed. Nil until fetched.
    public var analysis: ActivityDetail?
    /// The coach's reading of the session, written from `analysis` and the recording. Nil until asked.
    public var debrief: RideDebrief.Report?

    public init(id: UUID = UUID(), athleteID: String, workout: Workout, plannedSessionID: UUID? = nil, intervalsEventID: Int? = nil,
                startedAt: Date, endedAt: Date? = nil, samples: [RideSample] = [], feedback: SubjectiveFeedback? = nil,
                analysis: ActivityDetail? = nil, debrief: RideDebrief.Report? = nil) {
        self.analysis = analysis
        self.debrief = debrief
        self.id = id
        self.athleteID = athleteID
        self.workout = workout
        self.plannedSessionID = plannedSessionID
        self.intervalsEventID = intervalsEventID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.samples = samples
        self.feedback = feedback
    }

    /// Stable id sent to Intervals as `external_id`, so a lost response can be reconciled instead of re-uploaded.
    public var externalID: String { "cadencia-\(id.uuidString.lowercased())" }

    public var duration: TimeInterval { (endedAt ?? samples.last?.time ?? startedAt).timeIntervalSince(startedAt) }

    public var averageWatts: Int? { average(samples.compactMap(\.watts)) }
    public var averageHeartRate: Int? { average(samples.compactMap(\.heartRate)) }
    public var averageCadence: Int? { average(samples.compactMap(\.cadence)) }
    public var kilojoules: Double { Double(samples.compactMap(\.watts).reduce(0, +)) / 1000 }

    /// Normalized power: 30 s rolling mean, fourth power, mean, fourth root (Coggan).
    public var normalizedWatts: Int? {
        let watts = samples.map { Double($0.watts ?? 0) }
        guard watts.count >= 30 else { return averageWatts }
        var rolling: [Double] = []
        var sum = watts[0..<30].reduce(0, +)
        rolling.append(sum / 30)
        for i in 30..<watts.count {
            sum += watts[i] - watts[i - 30]
            rolling.append(sum / 30)
        }
        let mean4 = rolling.reduce(0) { $0 + pow($1, 4) } / Double(rolling.count)
        return Int(pow(mean4, 0.25).rounded())
    }

    public func trainingLoad(ftp: Int) -> Int? {
        guard let np = normalizedWatts, ftp > 0 else { return nil }
        let intensity = Double(np) / Double(ftp)
        return Int((duration / 3600 * intensity * intensity * 100).rounded())
    }

    private func average(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }
}

/// Encodes a ride as Garmin TCX, which Intervals.icu accepts on `POST /athlete/{id}/activities`.
/// Power goes in the Garmin `TPX` extension that every importer understands.
public enum TCXEncoder {
    public static func encode(_ ride: RideRecording, name: String? = nil) -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(identifier: "UTC")

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2">
          <Activities>
            <Activity Sport="Biking">
              <Id>\(iso.string(from: ride.startedAt))</Id>
              <Lap StartTime="\(iso.string(from: ride.startedAt))">
                <TotalTimeSeconds>\(Int(ride.duration.rounded()))</TotalTimeSeconds>
                <DistanceMeters>0</DistanceMeters>
                <Calories>\(Int((ride.kilojoules).rounded()))</Calories>
        """
        if let hr = ride.averageHeartRate {
            xml += "\n        <AverageHeartRateBpm><Value>\(hr)</Value></AverageHeartRateBpm>"
        }
        xml += """

                <Intensity>Active</Intensity>
                <TriggerMethod>Manual</TriggerMethod>
                <Track>
        """
        for s in ride.samples {
            xml += "\n          <Trackpoint><Time>\(iso.string(from: s.time))</Time>"
            if let hr = s.heartRate { xml += "<HeartRateBpm><Value>\(hr)</Value></HeartRateBpm>" }
            if let cad = s.cadence { xml += "<Cadence>\(cad)</Cadence>" }
            if let w = s.watts { xml += "<Extensions><ns3:TPX><ns3:Watts>\(w)</ns3:Watts></ns3:TPX></Extensions>" }
            xml += "</Trackpoint>"
        }
        xml += """

                </Track>
              </Lap>
              <Notes>\(escape(name ?? ride.workout.name))</Notes>
              <Creator xsi:type="Device_t" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><Name>Cadencia</Name><UnitId>0</UnitId><ProductID>0</ProductID></Creator>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>

        """
        return Data(xml.utf8)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
