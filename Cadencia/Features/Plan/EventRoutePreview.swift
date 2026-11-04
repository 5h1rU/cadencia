import SwiftUI
import MapKit
import CadenciaCore

struct EventRoutePreview: View {
    let route: GPXRoute
    enum Context { case event, plannedRide, recordedRide }
    var context: Context = .event
    @State private var prepared: GPXRoute?
    @State private var selectedKm: Double?
    @Environment(\.dynamicTypeSize) private var textSize
    private var displayed: GPXRoute { route.profileSegments != nil ? route : (prepared?.id == route.id ? prepared! : route) }
    private var inspected: ClimbProfilePoint? {
        guard let selectedKm else { return nil }
        return (displayed.profileSegments ?? []).lazy.compactMap { ProfileSampler($0).point(at: selectedKm) }.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())
            layout {
                Text("Route overview").font(.headline)
                if !textSize.isAccessibilitySize { Spacer() }
                RouteExplorerButton(route: displayed, selectedKm: $selectedKm)
                    .font(.subheadline)
            }
            Map {
                ForEach(Array(route.segments.enumerated()), id: \.offset) { _, segment in
                    MapPolyline(coordinates: segment.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                        .stroke(.blue, lineWidth: 4)
                }
                if let start = route.start {
                    Marker("Start", coordinate: CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude))
                        .annotationTitles(.hidden)
                }
                if let point = inspected {
                    Marker("Selected point", coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
                        .annotationTitles(.hidden)
                }
            }
            .mapControls { MapCompass() }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Event route map")
            if let segments = displayed.profileSegments, !segments.isEmpty {
                TerrainProfileView(segments: segments, climbs: displayed.climbs, selectedKm: $selectedKm, totalDistanceKm: displayed.distanceKm)
                if let point = inspected {
                    Text("At \(ClimbFormat.km(point.distanceKm)) · \(ClimbFormat.meters(point.altitudeM)) · \(ClimbFormat.gradient(point.gradientPercent))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                GradientLegend()
            } else if displayed.profileSegments == nil {
                ProgressView("Preparing climb profiles…")
            }
            Group {
                if context == .event { Text("GPX distances and climbing are estimates. Confirm them against the organizer’s figures.") }
                else if context == .recordedRide { Text("GPS distance and climbing are estimates. Recording gaps and missing elevation can affect the profile.") }
                else { Text("Distance and climbing are estimated from the GPX course.") }
            }.font(.footnote).foregroundStyle(.secondary)
            if !route.hasCompleteElevation {
                Group {
                    if context == .event { Label("Elevation data is incomplete. Enter the organizer’s climbing figures; unknown elevation is not zero.", systemImage: "exclamationmark.triangle") }
                    else { Label("Elevation data is incomplete. Unknown elevation is not zero.", systemImage: "exclamationmark.triangle") }
                }.font(.footnote).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .task(id: route.id) { let value = await TerrainRouteCache.prepared(route); if !Task.isCancelled { prepared = value } }
    }
}

/// Shared by the final confirmation and the saved event detail screen.
struct EventCourseSummary: View {
    let event: TrainingEvent
    var body: some View {
        if let km = event.distanceKm { LabeledContent("Distance", value: km.formatted(.number.precision(.fractionLength(1))) + " km") }
        if let course = event.course {
            if let value = course.elevationGainM { LabeledContent("Elevation gain", value: meters(value)) }
            if let value = course.elevationLossM { LabeledContent("Elevation loss", value: meters(value)) }
            if let value = course.startAltitudeM { LabeledContent("Start altitude", value: meters(value)) }
            if let value = course.minAltitudeM { LabeledContent("Lowest altitude", value: meters(value)) }
            if let value = course.maxAltitudeM { LabeledContent("Highest altitude", value: meters(value)) }
            if let surface = course.surface { LabeledContent("Surface", value: surface.title) }
            if let difficulty = course.technicalDifficulty { LabeledContent("Technical difficulty", value: difficulty.title) }
            if let file = course.sourceFileName { LabeledContent("Route file", value: file) }
        }
    }
    private func meters(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) + " m" }
}

struct EventPreparationSummary: View {
    let event: TrainingEvent
    var body: some View {
        if !event.objective.isEmpty { LabeledContent("Objective", value: event.objective) }
        if let details = event.details {
            if let minutes = details.expectedDurationMinutes { LabeledContent("Expected duration", value: Format.minutes(TimeInterval(minutes * 60))) }
            if let minutes = details.cutoffMinutes { LabeledContent("Cutoff time", value: Format.minutes(TimeInterval(minutes * 60))) }
            if let value = details.usualAltitudeM { LabeledContent("Usual training altitude", value: value.formatted(.number.precision(.fractionLength(0))) + " m") }
            if let arrival = details.arrivalDay { LabeledContent("Arrival date", value: Format.day(arrival)) }
            if let value = details.expectedTemperatureC { LabeledContent("Expected temperature", value: value.formatted(.number.precision(.fractionLength(1))) + " °C") }
            if let value = details.expectedHumidityPercent { LabeledContent("Expected humidity", value: value.formatted(.number.precision(.fractionLength(0))) + "%") }
            if let text = details.conditionsNote { LabeledContent("Expected conditions", value: text) }
            if let text = details.terrainExperience { LabeledContent("Terrain and altitude experience", value: text) }
            if let text = details.supportNotes { LabeledContent("Fueling and support", value: text) }
            if let text = details.trainingConstraints { LabeledContent("Training constraints", value: text) }
            if details.expectedDurationMinutes == nil { Text("Duration not provided").foregroundStyle(.secondary) }
        }
    }
}
