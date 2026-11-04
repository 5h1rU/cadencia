import Foundation

/// Exports one selected course, retaining recording gaps and all source coordinates.
public enum GPXExporter {
    public static func selectedRoute(from source: Data, index: Int) throws -> Data {
        let routes = try GPXImporter().parse(source, retainRawGeometry: true)
        guard routes.indices.contains(index) else { throw GPXImporter.ImportError.noRoute }
        return encode(routes[index])
    }

    public static func encode(_ route: GPXRoute) -> Data {
        let name = route.name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"Cadencia\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>\(name)</name>"
        for segment in route.segments {
            xml += "<trkseg>"
            for point in segment {
                xml += "<trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\">"
                if let elevation = point.elevationM { xml += "<ele>\(elevation)</ele>" }
                xml += "</trkpt>"
            }
            xml += "</trkseg>"
        }
        xml += "</trk></gpx>"
        return Data(xml.utf8)
    }
}
