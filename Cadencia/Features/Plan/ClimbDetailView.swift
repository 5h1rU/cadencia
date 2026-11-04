import SwiftUI
import MapKit
import CadenciaCore

@MainActor enum TerrainRouteCache {
    private static var routes: [UUID: GPXRoute] = [:]
    static func prepared(_ route: GPXRoute) async -> GPXRoute {
        if route.climbAnalysisVersion == ClimbAnalyzer.version, route.profileSegments != nil { return route }
        if let cached = routes[route.id] { return cached }
        let result = (try? await Task.detached(priority: .userInitiated) { try route.upgradingClimbAnalysis() }.value) ?? route
        if routes.count >= 4, let oldest = routes.keys.first { routes.removeValue(forKey: oldest) }
        routes[route.id] = result
        return result
    }
}

struct EventClimbsSection: View {
    let route: GPXRoute
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var prepared: GPXRoute?
    @State private var showingAll = false
    private var displayed: GPXRoute { route.profileSegments != nil ? route : (prepared?.id == route.id ? prepared! : route) }

    var body: some View {
        Section {
            if displayed.profileSegments == nil {
                ProgressView("Preparing climb profiles…")
            } else if displayed.climbs.isEmpty {
                Text("No sustained climbs detected in the available elevation data.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(displayed.climbs.prefix(showingAll ? displayed.climbs.count : 8).enumerated()), id: \.element.id) { index, climb in
                    NavigationLink {
                        ClimbDetailView(route: displayed, climb: climb, number: index + 1)
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                            layout {
                                Text("Climb \(index + 1)").font(.headline)
                                if !textSize.isAccessibilitySize { Spacer(minLength: 8) }
                                ClimbCategoryBadge(category: climb.category)
                            }
                            Text("Starts at \(climb.startKm.formatted(.number.precision(.fractionLength(1)))) km")
                                .font(.caption).foregroundStyle(.secondary)
                            if let profile = climb.detail?.profile, let first = profile.first, let last = profile.last {
                                let low = profile.map(\.altitudeM).min() ?? first.altitudeM
                                let high = profile.map(\.altitudeM).max() ?? last.altitudeM
                                TerrainProfileDrawing(segments: [profile], originKm: first.distanceKm,
                                                      lengthKm: climb.distanceKm, altitudeRange: (low - 5)...(max(low + 1, high) + 5))
                                    .frame(height: 44)
                            }
                            Text("\(ClimbFormat.km(climb.distanceKm)) · \(ClimbFormat.meters(climb.gainM)) · \(ClimbFormat.gradient(climb.averageGradient)) average")
                                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(.vertical, 6)
                    }
                }
                if displayed.climbs.count > 8, !showingAll { Button("Show all climbs") { showingAll = true } }
            }
        } header: {
            Text("Estimated major climbs (\(displayed.climbs.count))")
        } footer: {
            Text("Tap a climb for its gradient profile, hardest sections and kilometre splits. Categories are estimates, not official race classifications.")
        }
        .task(id: route.id) { let value = await TerrainRouteCache.prepared(route); if !Task.isCancelled { prepared = value } }
    }
}

struct ClimbDetailView: View {
    let route: GPXRoute
    let climb: RouteClimb
    let number: Int
    @State private var selectedKm: Double?
    @State private var highlightedRange: ClosedRange<Double>?
    @State private var scrollRequest = UUID()
    @Environment(\.dynamicTypeSize) private var textSize
    private var profile: [ClimbProfilePoint] { climb.detail?.profile ?? [] }
    private var inspected: ClimbProfilePoint? {
        ProfileSampler(profile).point(at: climb.startKm + (selectedKm ?? 0))
    }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            Section {
                let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                layout {
                    Text("Climb \(number)").font(.title2.bold())
                    if !textSize.isAccessibilitySize { Spacer(minLength: 8) }
                    ClimbCategoryBadge(category: climb.category)
                }
                LabeledContent("Starts at", value: ClimbFormat.km(climb.startKm))
                LabeledContent("Climb length", value: ClimbFormat.km(climb.distanceKm))
                LabeledContent("Ascent", value: ClimbFormat.meters(climb.gainM))
                LabeledContent("Average gradient", value: ClimbFormat.gradient(climb.averageGradient))
                if let altitude = profile.map(\.altitudeM).max() { LabeledContent("Summit altitude", value: ClimbFormat.meters(altitude)) }
            } footer: { Text("Category estimated from the climb’s geometry; official race categories may differ. Preparation also depends on altitude and conditions.") }

            if !profile.isEmpty {
                Section {
                    TerrainProfileView(segments: [profile], originKm: climb.startKm, selectedKm: $selectedKm, highlightedRange: highlightedRange)
                        .id("climb-profile")
                    Text("Drag across the profile to inspect each section.").font(.footnote).foregroundStyle(.secondary)
                    if let point = inspected {
                        LabeledContent("Distance into climb", value: ClimbFormat.km(point.distanceKm - climb.startKm))
                        LabeledContent("Altitude", value: ClimbFormat.meters(point.altitudeM))
                        LabeledContent("Gradient over 100 m", value: ClimbFormat.gradient(point.gradientPercent))
                    }
                    GradientLegend()
                } header: { Text("Climb profile") }

                Section("Climb map") {
                    Map(initialPosition: .region(mapRegion)) {
                        ForEach(Array(route.segments.enumerated()), id: \.offset) { _, segment in
                            MapPolyline(coordinates: segment.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                                .stroke(.gray.opacity(0.4), lineWidth: 2)
                        }
                        MapPolyline(coordinates: profile.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                            .stroke(.blue, lineWidth: 5)
                        if let point = inspected {
                            Marker("Selected point", coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
                                .annotationTitles(.hidden)
                        }
                    }
                    .frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Map of the selected climb")
                }
            }

            if let detail = climb.detail {
                if detail.steepest250m != nil || detail.steepest1km != nil {
                    Section {
                        if let section = detail.steepest250m { sectionButton("Steepest 250 m", section) }
                        if let section = detail.steepest1km { sectionButton("Steepest 1 km", section) }
                    } header: { Text("Hardest sustained sections") } footer: {
                        Text("Gradients are averaged over a stretch of road, rather than a single GPS point. Tap to highlight a section.")
                    }
                }
                Section("Kilometre splits") {
                    ForEach(Array(detail.kilometreSplits.enumerated()), id: \.offset) { _, split in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            RoundedRectangle(cornerRadius: 3).fill(GradientBand.band(split.averageGradient).color)
                                .frame(width: 6, height: 24).accessibilityHidden(true)
                            Text(sectionRange(split)).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Text(ClimbFormat.gradient(split.averageGradient)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        }
                    }
                }
                if !detail.hasDetailedGradients {
                    Section {
                        Label("This GPX is too sparse in some sections for reliable short-section gradients. Unknown gradients are shown in gray.", systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if route.profileRebuiltFromCache == true {
                Section { Text("This profile was rebuilt from the saved route preview. Reimport the original GPX for the most detailed gradients.").font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                DisclosureGroup("How climb categories work") {
                    Text("Categories are estimated from climb length in metres multiplied by average gradient in percent. Classified climbs are at least 500 m long with an average gradient of at least 3%.")
                        .font(.footnote)
                    ForEach([(ClimbCategory.four, 8_000), (.three, 16_000), (.two, 32_000), (.one, 64_000), (.hc, 80_000)], id: \.0) { category, score in
                        LabeledContent(category.title, value: String(localized: "Above \(score.formatted()) points"))
                    }
                    Text("This geometric estimate can differ from an organizer’s official race category.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Climb details").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                RouteExplorerButton(route: route, climb: climb, title: String(localized: "Climb \(number)"),
                                    selectedKm: $selectedKm, highlightedRange: highlightedRange)
                    .labelStyle(.iconOnly)
            }
        }
        .onChange(of: scrollRequest) { _, _ in withAnimation { proxy.scrollTo("climb-profile", anchor: .top) } }
        }
    }

    private func sectionButton(_ title: LocalizedStringKey, _ section: ClimbSection) -> some View {
        Button {
            highlightedRange = section.startKm...section.endKm
            selectedKm = (section.startKm + section.endKm) / 2 - climb.startKm
            scrollRequest = UUID()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                LabeledContent { Text(ClimbFormat.gradient(section.averageGradient)).fontWeight(.semibold) } label: { Text(title) }
                Text(sectionRange(section)).font(.footnote).foregroundStyle(.secondary)
            }.foregroundStyle(.primary)
        }
        .accessibilityHint("Highlights this section on the profile.")
    }
    private func sectionRange(_ section: ClimbSection) -> String {
        let lo = (section.startKm - climb.startKm).formatted(.number.precision(.fractionLength(2)))
        let hi = (section.endKm - climb.startKm).formatted(.number.precision(.fractionLength(2)))
        return "\(lo)–\(hi) km"
    }
    private var mapRegion: MKCoordinateRegion {
        let latitudes = profile.map(\.latitude), longitudes = profile.map(\.longitude)
        let lowLat = latitudes.min() ?? 0, highLat = latitudes.max() ?? 0
        let lowLon = longitudes.min() ?? 0, highLon = longitudes.max() ?? 0
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (lowLat + highLat) / 2, longitude: (lowLon + highLon) / 2),
                                  span: MKCoordinateSpan(latitudeDelta: max(0.01, (highLat - lowLat) * 1.3), longitudeDelta: max(0.01, (highLon - lowLon) * 1.3)))
    }
}
