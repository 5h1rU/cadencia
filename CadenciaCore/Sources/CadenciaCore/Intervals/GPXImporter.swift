import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Local GPX 1.0/1.1 parsing. No files, network calls, platform frameworks, or external entities.
public struct GPXImporter: Sendable {
    public enum ImportError: Error, Equatable, Sendable {
        case tooLarge, invalidXML, invalidCoordinate, noRoute, tooManyPoints
    }
    public static let maximumBytes = 20 * 1_024 * 1_024
    public init() {}

    public struct ProgressUpdate: Equatable, Sendable {
        public enum Stage: Sendable { case parsing, analyzing }
        public let stage: Stage
        public let completedUnits: Int
        public let totalUnits: Int
        public var fractionCompleted: Double { Double(completedUnits) / Double(max(1, totalUnits)) }
    }

    public func parse(_ data: Data, retainRawGeometry: Bool = false, combineTracks: Bool = false, onProgress: (@Sendable (ProgressUpdate) -> Void)? = nil) throws -> [GPXRoute] {
        try Task.checkCancellation()
        guard data.count <= Self.maximumBytes else { throw ImportError.tooLarge }
        // External declarations have no place in an event route. Reject entity expansion as well.
        let text = String(decoding: data, as: UTF8.self)
        guard !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw ImportError.invalidXML
        }
        let delegate = GPXDelegate()
        onProgress?(ProgressUpdate(stage: .parsing, completedUnits: 0, totalUnits: data.count))
        let stream = GPXProgressStream(data: data) { bytes in
            onProgress?(ProgressUpdate(stage: .parsing, completedUnits: bytes, totalUnits: data.count))
        }
        let parser = XMLParser(stream: stream)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        try Task.checkCancellation()
        if let error = delegate.error { throw error }
        guard parsed, delegate.isGPX else { throw ImportError.invalidXML }
        onProgress?(ProgressUpdate(stage: .parsing, completedUnits: data.count, totalUnits: data.count))
        let definitions = combineTracks ? [GPXDelegate.RawRoute(name: delegate.routes.first?.name ?? "", segments: delegate.routes.flatMap(\.segments))] : delegate.routes
        let totalPoints = definitions.reduce(0) { $0 + $1.segments.reduce(0) { $0 + $1.count } }
        onProgress?(ProgressUpdate(stage: .analyzing, completedUnits: 0, totalUnits: totalPoints))
        var completedPoints = 0
        var routes: [GPXRoute] = []
        for route in definitions {
            let offset = completedPoints
            if let built = try build(name: route.name, segments: route.segments, retainRawGeometry: retainRawGeometry, onProgress: { points in
                onProgress?(ProgressUpdate(stage: .analyzing, completedUnits: offset + points, totalUnits: totalPoints))
            }) { routes.append(built) }
            completedPoints += route.segments.reduce(0) { $0 + $1.count }
            onProgress?(ProgressUpdate(stage: .analyzing, completedUnits: completedPoints, totalUnits: totalPoints))
        }
        guard !routes.isEmpty else { throw ImportError.noRoute }
        return routes
    }

    private func build(name: String, segments raw: [[RoutePoint]], retainRawGeometry: Bool, onProgress: (Int) -> Void) throws -> GPXRoute? {
        var distance = 0.0, gain = 0.0, loss = 0.0, coveredDistance = 0.0
        var elevations: [Double] = []
        var output: [[RoutePoint]] = []
        var analysisSegments: [[RoutePoint]] = []
        var processedPoints = 0
        for rawSegment in raw {
            try Task.checkCancellation()
            guard rawSegment.count >= 2 else { processedPoints += rawSegment.count; continue }
            var segment: [RoutePoint] = []
            var anchor = rawSegment.first?.elevationM
            for (index, rawPoint) in rawSegment.enumerated() {
                if processedPoints % 256 == 0 { try Task.checkCancellation(); onProgress(processedPoints) }
                processedPoints += 1
                var point = rawPoint
                if index > 0 {
                    let previous = rawSegment[index - 1]
                    let km = Self.distance(previous, point)
                    distance += km
                    if previous.elevationM != nil && point.elevationM != nil { coveredDistance += km }
                }
                point.distanceKm = distance
                if let altitude = point.elevationM {
                    elevations.append(altitude)
                    if let prior = anchor {
                        let change = altitude - prior
                        // A 3 m hysteresis avoids counting every small GPS elevation wobble as climbing.
                        if abs(change) >= 3 {
                            if change > 0 {
                                gain += change
                            } else {
                                loss -= change
                            }
                            anchor = altitude
                        }
                    } else { anchor = altitude }
                } else {
                    anchor = nil
                }
                segment.append(point)
            }
            analysisSegments.append(segment)
            // Persist bounded samples for maps/profiles, after calculating metrics from every point.
            let strideSize = max(1, Int(ceil(Double(segment.count) / 1_000)))
            var sampled = stride(from: 0, to: segment.count, by: strideSize).map { segment[$0] }
            if sampled.last != segment.last, let last = segment.last { sampled.append(last) }
            output.append(retainRawGeometry ? segment : sampled)
        }
        guard distance > 0 else { return nil }
        let terrain = try ClimbAnalyzer().analyze(analysisSegments)
        let complete = raw.filter { $0.count >= 2 }.allSatisfy { $0.allSatisfy { $0.elevationM != nil } }
        return GPXRoute(id: UUID(), name: name, segments: output, distanceKm: distance,
                        elevationGainM: complete ? gain : nil, elevationLossM: complete ? loss : nil,
                        minAltitudeM: complete ? elevations.min() : nil, maxAltitudeM: complete ? elevations.max() : nil,
                        elevationCoverage: complete ? 1 : min(0.999, coveredDistance / distance), climbs: terrain.climbs,
                        profileSegments: terrain.profileSegments, climbAnalysisVersion: ClimbAnalyzer.version)
    }

    private static func distance(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        let rad = Double.pi / 180
        let lat = (b.latitude - a.latitude) * rad, lon = (b.longitude - a.longitude) * rad
        let h = pow(sin(lat / 2), 2) + cos(a.latitude * rad) * cos(b.latitude * rad) * pow(sin(lon / 2), 2)
        return 6_371.0088 * 2 * asin(sqrt(min(1, max(0, h))))
    }
}

/// XMLParser pulls bytes synchronously. Counting those reads reports real input consumption and
/// lets a cancelled task stop parsing without blocking the UI or fabricating timer-based progress.
private final class GPXProgressStream: InputStream {
    private let source: InputStream
    private let report: (Int) -> Void
    private var bytesRead = 0
    private var cancelled = false

    init(data: Data, report: @escaping (Int) -> Void) {
        source = InputStream(data: data); self.report = report
        super.init(data: Data())
    }
    override func open() { source.open() }
    override func close() { source.close() }
    override var hasBytesAvailable: Bool { !cancelled && source.hasBytesAvailable }
    override var streamStatus: Stream.Status { cancelled ? .error : source.streamStatus }
    override var streamError: Error? { cancelled ? CancellationError() : source.streamError }
    override func getBuffer(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>) -> Bool { false }
    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        if Task.isCancelled { cancelled = true; return -1 }
        let count = source.read(buffer, maxLength: len)
        if count > 0 { bytesRead += count; report(bytesRead) }
        return count
    }
}

private final class GPXDelegate: NSObject, XMLParserDelegate {
    struct RawRoute { var name = ""; var segments: [[RoutePoint]] = [] }
    var routes: [RawRoute] = []
    var error: GPXImporter.ImportError?
    var isGPX = false
    private var stack: [String] = []
    private var route: RawRoute?
    private var segment: [RoutePoint] = []
    private var point: RoutePoint?
    private var content = ""
    private var pointCount = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let parent = stack.last
        stack.append(elementName); content = ""
        if stack.count == 1 { isGPX = elementName == "gpx" }
        if (elementName == "trk" || elementName == "rte"), parent == "gpx" {
            route = RawRoute(); segment = []
        }
        if elementName == "trkseg", parent == "trk" { segment = [] }
        if (elementName == "trkpt" && parent == "trkseg") || (elementName == "rtept" && parent == "rte") {
            pointCount += 1
            guard pointCount <= 200_000 else { error = .tooManyPoints; parser.abortParsing(); return }
            guard let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init),
                  lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else {
                error = .invalidCoordinate; parser.abortParsing(); return
            }
            point = RoutePoint(latitude: lat, longitude: lon)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { content += string }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        error = .invalidXML; parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        error = .invalidXML; parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let parent = stack.dropLast().last
        if elementName == "name", parent == "trk" || parent == "rte" {
            route?.name = String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        }
        if elementName == "ele", parent == "trkpt" || parent == "rtept", let value = Double(content.trimmingCharacters(in: .whitespacesAndNewlines)),
           value.isFinite, (-500...10_000).contains(value) { point?.elevationM = value }
        if elementName == "trkpt" || elementName == "rtept" {
            if let point { segment.append(point) }
            point = nil
        }
        if elementName == "trkseg" { route?.segments.append(segment); segment = [] }
        if elementName == "rte", parent == "gpx" { route?.segments.append(segment); segment = [] }
        if (elementName == "trk" || elementName == "rte"), parent == "gpx", let current = route {
            routes.append(current); route = nil
        }
        _ = stack.popLast(); content = ""
    }
}
