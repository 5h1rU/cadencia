import SwiftUI
import Charts
import CadenciaCore

enum GradientBand: CaseIterable {
    case descent, easy, steady, hard, steep, verySteep, unknown
    static func band(_ gradient: Double?) -> Self {
        guard let gradient else { return .unknown }
        let rounded = (gradient * 10).rounded() / 10
        switch rounded {
        case ..<0: return .descent
        case ..<3: return .easy
        case ..<6: return .steady
        case ..<9: return .hard
        case ..<12: return .steep
        default: return .verySteep
        }
    }
    var color: Color {
        switch self {
        case .descent: return .cyan
        case .easy: return .green
        case .steady: return .yellow
        case .hard: return .orange
        case .steep: return .red
        case .verySteep: return .purple
        case .unknown: return .gray
        }
    }
    var label: String {
        switch self {
        case .descent: return "<0%"
        case .easy: return "0–3%"
        case .steady: return "3–6%"
        case .hard: return "6–9%"
        case .steep: return "9–12%"
        case .verySteep: return "12%+"
        case .unknown: return String(localized: "Unknown")
        }
    }
}

extension ClimbCategory {
    var title: String {
        switch self {
        case .hc: return "HC"
        case .uncategorized: return String(localized: "Uncategorized")
        default: return String(localized: "Cat \(rawValue)")
        }
    }
    var tint: Color {
        switch self {
        case .hc: return .purple
        case .one: return .red
        case .two: return .orange
        case .three: return .yellow
        case .four: return .green
        case .uncategorized: return .secondary
        }
    }
}

struct ClimbCategoryBadge: View {
    let category: ClimbCategory
    var body: some View {
        Text(category.title)
            .font(.caption.weight(.bold)).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(.primary)
            .background(category.tint.opacity(0.22), in: Capsule())
            .accessibilityLabel(Text("Estimated category: \(category.title)"))
    }
}

/// Custom terrain rendering inside Swift Charts' coordinate/selection/accessibility system.
struct TerrainProfileView: View {
    let segments: [[ClimbProfilePoint]]
    var originKm = 0.0
    var climbs: [RouteClimb] = []
    @Binding var selectedKm: Double?
    var highlightedRange: ClosedRange<Double>?
    var interactive = true
    var totalDistanceKm: Double?
    var height: CGFloat?
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .body) private var plotHeight = 180.0

    private struct Sample: Identifiable {
        let id: Int
        let segment: Int
        let point: ClimbProfilePoint
    }
    private var samples: [Sample] {
        var result: [Sample] = []
        for (index, segment) in segments.enumerated() {
            for point in segment { result.append(Sample(id: result.count, segment: index, point: point)) }
        }
        return result
    }
    private var length: Double { max(0.001, totalDistanceKm ?? ((segments.last?.last?.distanceKm ?? originKm) - originKm)) }
    private var selection: Binding<Double?> {
        Binding(get: { selectedKm ?? 0 }, set: { value in
            if interactive, let value { selectedKm = min(length, max(0, value)) }
        })
    }
    private var altitudeRange: ClosedRange<Double> {
        let values = segments.flatMap { $0.map(\.altitudeM) }
        let low = values.min() ?? 0, high = values.max() ?? 1, padding = max(10, ((values.max() ?? 1) - (values.min() ?? 0)) * 0.12)
        return (low - padding)...(high + padding)
    }
    private var selectedPoint: ClimbProfilePoint? {
        guard let selectedKm else { return nil }
        let distance = selectedKm + originKm
        return segments.lazy.compactMap { ProfileSampler($0).point(at: distance) }.first
    }
    private var annotatedClimbs: [RouteClimb] {
        guard !textSize.isAccessibilitySize else { return [] }
        let candidates = climbs.sorted { $0.gainM > $1.gainM }.prefix(6).sorted { $0.startKm < $1.startKm }
        return candidates.reduce(into: []) { result, climb in
            if result.last.map({ climb.startKm - $0.startKm > length * 0.09 }) ?? true { result.append(climb) }
        }
    }

    var body: some View {
        let range = altitudeRange
        Chart {
            ForEach(samples) { sample in
                LineMark(x: .value("Distance", sample.point.distanceKm - originKm), y: .value("Altitude", sample.point.altitudeM),
                         series: .value("Segment", sample.segment))
                    .foregroundStyle(.clear)
            }
            ForEach(annotatedClimbs) { climb in
                RuleMark(x: .value("Climb start", climb.startKm - originKm))
                    .foregroundStyle(.secondary.opacity(0.35)).lineStyle(StrokeStyle(dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(climb.category.title).font(.caption2.weight(.semibold)).padding(3)
                            .background(climb.category.tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                    }
            }
            if let highlightedRange {
                RectangleMark(xStart: .value("Section start", highlightedRange.lowerBound - originKm),
                              xEnd: .value("Section end", highlightedRange.upperBound - originKm),
                              yStart: .value("Bottom", range.lowerBound), yEnd: .value("Top", range.upperBound))
                    .foregroundStyle(Color.primary.opacity(0.12))
            }
            if let point = selectedPoint {
                RuleMark(x: .value("Selected distance", point.distanceKm - originKm))
                    .foregroundStyle(Color.primary.opacity(0.8))
                PointMark(x: .value("Distance", point.distanceKm - originKm), y: .value("Altitude", point.altitudeM))
                    .symbolSize(55).foregroundStyle(Color.primary)
            }
        }
        .chartXScale(domain: 0...length)
        .chartYScale(domain: range)
        .chartLegend(.hidden)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
        .chartXAxisLabel("Distance (km)")
        .chartYAxisLabel("Altitude (m)", position: .leading)
        .chartPlotStyle { plot in
            plot.background {
                TerrainProfileDrawing(segments: segments, originKm: originKm, lengthKm: length, altitudeRange: range)
            }
        }
        .chartXSelection(value: selection)
        .chartGesture { proxy in
            DragGesture(minimumDistance: 0)
                .onChanged { value in if interactive { proxy.selectXValue(at: value.location.x) } }
                .onEnded { value in if interactive { proxy.selectXValue(at: value.location.x) } }
        }
        .frame(height: height ?? plotHeight)
        .padding(.top, annotatedClimbs.isEmpty ? 0 : 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Elevation and gradient profile")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            let current = selectedKm ?? 0, step = max(0.025, length / 50)
            switch direction {
            case .increment: selectedKm = min(length, current + step)
            case .decrement: selectedKm = max(0, current - step)
            @unknown default: break
            }
        }
        .onAppear { if selectedKm == nil { selectedKm = 0 } }
        .onChange(of: length) { _, value in selectedKm = min(value, selectedKm ?? 0) }
    }

    private var accessibilityValue: Text {
        if let point = selectedPoint {
            return Text("\((point.distanceKm - originKm).formatted(.number.precision(.fractionLength(2)))) km, \(Int(point.altitudeM.rounded())) metres, gradient \(ClimbFormat.gradient(point.gradientPercent))")
        }
        return Text("\(length.formatted(.number.precision(.fractionLength(1)))) km. Adjust to inspect distance, altitude and gradient.")
    }
}

/// Filled trapezoids are grouped by gradient band: smooth terrain geometry, discrete local grade colors.
struct TerrainProfileDrawing: View {
    let segments: [[ClimbProfilePoint]]
    let originKm: Double
    let lengthKm: Double
    let altitudeRange: ClosedRange<Double>
    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            var fills: [GradientBand: Path] = [:]
            var outline = Path()
            func position(_ point: ClimbProfilePoint) -> CGPoint {
                CGPoint(x: (point.distanceKm - originKm) / max(0.001, lengthKm) * size.width,
                        y: (altitudeRange.upperBound - point.altitudeM) / max(1, altitudeRange.upperBound - altitudeRange.lowerBound) * size.height)
            }
            for segment in segments {
                guard let first = segment.first else { continue }
                outline.move(to: position(first))
                for (a, b) in zip(segment, segment.dropFirst()) {
                    let start = position(a), end = position(b)
                    let grade = a.gradientPercent.flatMap { ga in b.gradientPercent.map { (ga + $0) / 2 } }
                    let band = GradientBand.band(grade)
                    var path = Path()
                    path.move(to: CGPoint(x: start.x, y: size.height)); path.addLine(to: start)
                    path.addLine(to: end); path.addLine(to: CGPoint(x: end.x, y: size.height)); path.closeSubpath()
                    fills[band, default: Path()].addPath(path)
                    outline.addLine(to: end)
                }
            }
            for band in GradientBand.allCases {
                if let path = fills[band] { context.fill(path, with: .color(band.color.opacity(0.85))) }
            }
            context.stroke(outline, with: .color(.primary.opacity(0.65)), lineWidth: 1)
        }
        .clipped().accessibilityHidden(true)
    }
}

struct GradientLegend: View {
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: textSize.isAccessibilitySize ? 150 : 82), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(GradientBand.allCases, id: \.self) { band in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(band.color).frame(width: 12, height: 12)
                    Text(band.label).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore).accessibilityLabel(Text(band.label))
            }
        }
    }
}

enum ClimbFormat {
    static func km(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) + " km" }
    static func meters(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) + " m" }
    static func gradient(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(1))) + "%" } ?? String(localized: "Unknown")
    }
}
