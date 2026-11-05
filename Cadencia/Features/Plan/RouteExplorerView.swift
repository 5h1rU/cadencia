import SwiftUI
import MapKit
import CadenciaCore

/// The same explorer is available wherever the course or one of its climbs is shown.
struct RouteExplorerButton: View {
    let route: GPXRoute
    var climb: RouteClimb?
    var title: String?
    @Binding var selectedKm: Double?
    var highlightedRange: ClosedRange<Double>?
    /// In a List row only the button opens the explorer, not the whole row: borderless, with a 44 pt target.
    /// Elsewhere (the climb screen's toolbar) it keeps the system button style.
    var inListRow = false
    @State private var isPresented = false

    var body: some View {
        Group {
            if inListRow {
                Button { isPresented = true } label: { label.frame(minWidth: 44, minHeight: 44).contentShape(.rect) }
                    .buttonStyle(.borderless)
            } else {
                Button { isPresented = true } label: { label }
            }
        }
        .accessibilityHint("Opens the route explorer in landscape.")
        .fullScreenCover(isPresented: $isPresented, onDismiss: RouteExplorerOrientation.leave) {
            RouteExplorerView(route: route, climb: climb, title: title ?? route.name,
                              selectedKm: $selectedKm, highlightedRange: highlightedRange)
        }
    }

    private var label: some View { Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right") }
}

private struct ExplorerCourse {
    let route: GPXRoute
    let climb: RouteClimb?
    let profile: [[ClimbProfilePoint]]
    let geometry: RouteGeometry
    let bounds: MKMapRect
    var origin: Double { climb?.startKm ?? 0 }
    var length: Double { max(0.001, climb?.distanceKm ?? route.distanceKm) }

    init(route: GPXRoute, climb: RouteClimb?) {
        self.route = route; self.climb = climb
        if let profile = climb?.detail?.profile, !profile.isEmpty {
            self.profile = [profile]
            geometry = RouteGeometry([profile.map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude, elevationM: $0.altitudeM, distanceKm: $0.distanceKm) }])
        } else {
            profile = route.profileSegments ?? []
            geometry = RouteGeometry(route.segments)
        }
        let points = geometry.segments.flatMap { $0 }.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
        let anchor = points.first?.x ?? 0, world = MKMapRect.world.width
        var rect = MKMapRect.null
        for point in points {
            var x = point.x
            if x - anchor > world / 2 { x -= world }
            if x - anchor < -world / 2 { x += world }
            rect = rect.union(MKMapRect(x: x, y: point.y, width: 0.1, height: 0.1))
        }
        bounds = rect.isNull ? .world : rect.insetBy(dx: -max(500, rect.width * 0.12), dy: -max(500, rect.height * 0.12))
    }

    func profilePoint(at distance: Double) -> ClimbProfilePoint? {
        profile.lazy.compactMap { ProfileSampler($0).point(at: distance) }.first
    }
}

private enum ExplorerMode: CaseIterable {
    case both, map, profile
    var title: LocalizedStringKey {
        switch self {
        case .both: return "Map + profile"
        case .map: return "Map"
        case .profile: return "Profile"
        }
    }
}

private struct RouteExplorerView: View {
    let course: ExplorerCourse
    let title: String
    @Binding var selectedKm: Double?
    let highlightedRange: ClosedRange<Double>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var mode: ExplorerMode
    @State private var camera: MapCameraPosition
    @State private var cameraDistance = 10_000.0
    @State private var followsSelection = false
    /// Scrubbing stays local, so the screen behind the cover isn't re-rendered on every tick.
    /// The presenter gets the inspected point back when the explorer closes.
    @State private var selection: Double?
    /// Stored once, so the route lines' input stays identical while scrubbing.
    private static let contextLine = Color.gray.opacity(0.4)

    init(route: GPXRoute, climb: RouteClimb?, title: String, selectedKm: Binding<Double?>,
         highlightedRange: ClosedRange<Double>?) {
        let course = ExplorerCourse(route: route, climb: climb)
        self.course = course; self.title = title; _selectedKm = selectedKm
        self.highlightedRange = highlightedRange
        _camera = State(initialValue: .rect(course.bounds))
        _mode = State(initialValue: course.profile.isEmpty ? .map : .both)
        _selection = State(initialValue: selectedKm.wrappedValue)
    }

    private var absoluteDistance: Double { course.origin + (selection ?? 0) }
    private var point: RoutePoint? { course.geometry.point(at: absoluteDistance) }
    private var terrainPoint: ClimbProfilePoint? { course.profilePoint(at: absoluteDistance) }
    private var distanceSelection: Binding<Double> {
        Binding(get: { selection ?? 0 }, set: { selection = $0 })
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            VStack(spacing: 0) {
                header(landscape: landscape)
                Divider()
                if mode == .both {
                    if landscape {
                        HStack(spacing: 0) {
                            map.frame(width: geometry.size.width * 0.46)
                            Divider()
                            profilePanel
                        }
                    } else {
                        VStack(spacing: 0) {
                            map.frame(height: geometry.size.height * 0.35)
                            Divider()
                            profilePanel
                        }
                    }
                } else if mode == .map {
                    map
                    if textSize.isAccessibilitySize {
                        ScrollView { mapInspectionControls }.frame(maxHeight: 140)
                    } else { mapInspectionControls }
                } else {
                    profilePanel
                }
            }
            .background(Color(uiColor: .systemBackground))
        }
        .background(RouteExplorerRotation().frame(width: 0, height: 0))
        .statusBarHidden()
        .onAppear { selection = min(course.length, max(0, selection ?? 0)) }
        .onChange(of: selection) { _, _ in if followsSelection { centerOnSelection() } }
        .onDisappear { selectedKm = selection }
    }

    @ViewBuilder private func header(landscape: Bool) -> some View {
        if landscape {
            HStack(spacing: 12) { closeButton; heading; modePicker.frame(maxWidth: 340) }
                .padding(.horizontal, 12).padding(.vertical, 8)
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 12) { closeButton; heading }
                modePicker
            }.padding(12)
        }
    }
    private var closeButton: some View {
        // Hand the point back before the cover slides away, so the screen it reveals already shows it.
        Button { selectedKm = selection; dismiss() } label: { Label("Close", systemImage: "xmark").labelStyle(.iconOnly) }
            .font(.body.weight(.semibold))
            .buttonStyle(.bordered).buttonBorderShape(.circle)
            .controlSize(.large)
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).lineLimit(1)
            if let climb = course.climb {
                Text("\(climb.category.title) · \(ClimbFormat.km(climb.distanceKm)) · \(ClimbFormat.gradient(climb.averageGradient)) average")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var modePicker: some View {
        if !course.profile.isEmpty {
            Picker("Explorer view", selection: $mode) {
                ForEach(ExplorerMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.segmented)
        }
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: .all) {
                RouteLines(segments: course.route.segments, color: course.climb == nil ? Color.blue : Self.contextLine,
                           lineWidth: course.climb == nil ? 4 : 2)
                if course.climb != nil {
                    RouteLines(segments: course.geometry.segments, lineWidth: 5)
                }
                if let start = course.geometry.segments.first?.first {
                    Marker("Route start", systemImage: "flag", coordinate: CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude))
                        .tint(.green).annotationTitles(.hidden)
                }
                if let point {
                    Annotation("Selected route point", coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)) {
                        ZStack {
                            Circle().fill(.white).frame(width: 22, height: 22)
                            Circle().fill(.blue).frame(width: 14, height: 14)
                        }.shadow(radius: 3).accessibilityLabel("Selected route point")
                    }.annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls { MapCompass(); MapScaleView() }
            .onTapGesture { location in
                guard let coordinate = proxy.convert(location, from: .local),
                      let point = course.geometry.nearestPoint(latitude: coordinate.latitude, longitude: coordinate.longitude) else { return }
                selection = min(course.length, max(0, point.distanceKm - course.origin))
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                cameraDistance = context.camera.distance
                if camera.positionedByUser { followsSelection = false }
            }
            .accessibilityLabel("Route explorer map")
            .accessibilityHint("Pan and zoom the map. Tap near the route to inspect that point.")
            .overlay(alignment: .bottomTrailing) { mapButtons.padding(12) }
        }
    }

    private var mapButtons: some View {
        HStack(spacing: 8) {
            Button {
                followsSelection.toggle()
                if followsSelection { withAnimation { centerOnSelection() } }
            } label: {
                Label("Follow selected point", systemImage: followsSelection ? "scope" : "location")
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).contentShape(.rect)
            }
            .disabled(point == nil).foregroundStyle(followsSelection ? Color.accentColor : Color.primary)
            .accessibilityAddTraits(followsSelection ? .isSelected : [])
            Button {
                followsSelection = false
                withAnimation { camera = .rect(course.bounds) }
            } label: {
                Label(course.climb == nil ? LocalizedStringKey("Fit route") : LocalizedStringKey("Fit climb"), systemImage: "arrow.up.left.and.arrow.down.right")
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).contentShape(.rect)
            }
        }
        .font(.title3.weight(.semibold))
        .buttonStyle(.plain).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var profilePanel: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    inspectionSummary
                    TerrainProfileView(segments: course.profile, originKm: course.origin,
                                       climbs: course.climb == nil ? course.route.climbs : [], selectedKm: $selection,
                                       highlightedRange: highlightedRange, totalDistanceKm: course.length,
                                       height: max(textSize.isAccessibilitySize ? 280 : 145, geometry.size.height - 160))
                    GradientLegend()
                    Text("Drag the profile or tap the route to inspect a point.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }
        }
    }

    private var mapInspectionControls: some View {
        VStack(spacing: 6) {
            inspectionSummary
            Slider(value: distanceSelection, in: 0...course.length) {
                Text("Selected distance")
            }.accessibilityValue(Text(ClimbFormat.km(selection ?? 0)))
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var inspectionSummary: some View {
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        let terrain = terrainPoint
        return layout {
            metric(course.climb == nil ? "Route distance" : "Distance into climb", value: ClimbFormat.km(selection ?? 0))
            metric("Altitude", value: (terrain?.altitudeM ?? point?.elevationM).map(ClimbFormat.meters) ?? String(localized: "Unknown"))
            metric("Gradient over 100 m", value: ClimbFormat.gradient(terrain?.gradientPercent))
        }
    }
    private func metric(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func centerOnSelection() {
        guard let point else { return }
        camera = .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                                   distance: max(500, min(100_000, cameraDistance))))
    }
}
