import SwiftUI

/// A small drawn map of a trip: a simplified base map of the countries
/// around it, the cities as stamps where they lie, joined in visiting order
/// by a dashed, slightly curved line, like a route pencilled into a travel
/// journal. Stylized, not a street map: soft land on a paper sea, faint borders.
struct TripRouteMap: View {
    let stops: [TripRouteStop]
    var outline: WorldOutline = .shared

    /// The smallest stretch of map shown, in degrees, so a short trip still
    /// shows its coast or border.
    static let minimumSpan = 3.0

    var body: some View {
        Canvas { context, size in
            let box = CGRect(origin: .zero, size: size).insetBy(dx: 26, dy: 24)
            let projection = Self.projection(stops, in: box)
            let points = Self.layout(stops, in: box)
            if let projection { drawLand(&context, projection: projection, size: size) }
            drawPaper(&context, size: size)
            drawRoute(&context, points: points)
            drawStamps(&context, points: points, size: size)
        }
        .background(Paper.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(Text(stops.map(\.name).joined(separator: " → ")))
    }

    /// From longitude and latitude to the map: east–west shrunk by the
    /// latitude so distances look right, north up.
    struct Projection {
        let squeeze: Double
        let scale: Double
        let offsetX: Double
        let offsetY: Double

        func point(longitude: Double, latitude: Double) -> CGPoint {
            CGPoint(x: longitude * squeeze * scale + offsetX, y: -latitude * scale + offsetY)
        }

        /// The longitudes and latitudes the rectangle shows.
        func bounds(of rect: CGRect) -> (longitudes: ClosedRange<Double>, latitudes: ClosedRange<Double>) {
            let west = (rect.minX - offsetX) / scale / squeeze, east = (rect.maxX - offsetX) / scale / squeeze
            let north = -(rect.minY - offsetY) / scale, south = -(rect.maxY - offsetY) / scale
            return (min(west, east)...max(west, east), min(south, north)...max(south, north))
        }
    }

    /// Fits the stops to the box keeping their proportions, showing at least
    /// `minimumSpan` degrees. `nil` when several stops sit so close that a
    /// base map would only be one flat colour; they are spread out instead.
    static func projection(_ stops: [TripRouteStop], in rect: CGRect) -> Projection? {
        guard !stops.isEmpty else { return nil }
        let meanLatitude = stops.map(\.latitude).reduce(0, +) / Double(stops.count)
        let squeeze = max(cos(meanLatitude * .pi / 180), 0.2)
        let xs = stops.map { $0.longitude * squeeze }, ys = stops.map { -$0.latitude }
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let width = maxX - minX, height = maxY - minY
        if stops.count > 1, max(width, height) < 0.6 { return nil }
        let span = max(width, height, minimumSpan)
        let scale = min(rect.width / max(width, span * 0.6), rect.height / max(height, span * 0.6))
        return Projection(
            squeeze: squeeze,
            scale: scale,
            offsetX: rect.midX - (minX + width / 2) * scale,
            offsetY: rect.midY - (minY + height / 2) * scale
        )
    }

    /// Where each stop goes. Stops too close for a base map fan out over the box.
    static func layout(_ stops: [TripRouteStop], in rect: CGRect) -> [CGPoint] {
        guard !stops.isEmpty else { return [] }
        if let projection = projection(stops, in: rect) {
            return stops.map { projection.point(longitude: $0.longitude, latitude: $0.latitude) }
        }
        let meanLatitude = stops.map(\.latitude).reduce(0, +) / Double(stops.count)
        let squeeze = max(cos(meanLatitude * .pi / 180), 0.2)
        let raw = stops.map { CGPoint(x: $0.longitude * squeeze, y: -$0.latitude) }
        let minX = raw.map(\.x).min()!, maxX = raw.map(\.x).max()!
        let minY = raw.map(\.y).min()!, maxY = raw.map(\.y).max()!
        let width = maxX - minX, height = maxY - minY
        let span = max(width, height)
        guard span > 0.0005 else {
            // Everything in one spot: fan the stops out on a small arc.
            return stops.indices.map { index in
                let t = Double(index) / Double(max(stops.count - 1, 1))
                return CGPoint(x: rect.minX + rect.width * (0.2 + 0.6 * t), y: rect.midY + sin(t * .pi) * -rect.height * 0.2)
            }
        }
        let scale = min(rect.width / max(width, span * 0.25), rect.height / max(height, span * 0.25))
        let offsetX = rect.midX - (minX + width / 2) * scale
        let offsetY = rect.midY - (minY + height / 2) * scale
        return raw.map { CGPoint(x: $0.x * scale + offsetX, y: $0.y * scale + offsetY) }
    }

    /// Land a shade lighter than the paper sea, country borders as faint lines.
    private func drawLand(_ context: inout GraphicsContext, projection: Projection, size: CGSize) {
        let view = CGRect(origin: .zero, size: size).insetBy(dx: -4, dy: -4)
        let bounds = projection.bounds(of: view)
        var land = Path()
        for ring in outline.rings(longitudes: bounds.longitudes, latitudes: bounds.latitudes) {
            guard let first = ring.points.first else { continue }
            land.move(to: projection.point(longitude: first.x, latitude: first.y))
            for point in ring.points.dropFirst() {
                land.addLine(to: projection.point(longitude: point.x, latitude: point.y))
            }
            land.closeSubpath()
        }
        context.fill(land, with: .color(Paper.raised.opacity(0.92)))
        context.stroke(land, with: .color(Paper.rule.opacity(0.9)), style: StrokeStyle(lineWidth: 0.8, lineJoin: .round))
    }

    private func drawPaper(_ context: inout GraphicsContext, size: CGSize) {
        // A faint dot grid, like journal paper.
        var dots = Path()
        stride(from: 10.0, to: size.width, by: 14).forEach { x in
            stride(from: 10.0, to: size.height, by: 14).forEach { y in
                dots.addEllipse(in: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2))
            }
        }
        context.fill(dots, with: .color(Paper.rule.opacity(0.7)))
        // A little north arrow in the corner.
        let north = CGPoint(x: size.width - 14, y: 15)
        var arrow = Path()
        arrow.move(to: CGPoint(x: north.x, y: north.y - 6))
        arrow.addLine(to: CGPoint(x: north.x + 3.5, y: north.y + 4))
        arrow.addLine(to: CGPoint(x: north.x, y: north.y + 2))
        arrow.addLine(to: CGPoint(x: north.x - 3.5, y: north.y + 4))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(Paper.muted.opacity(0.55)))
    }

    private func drawRoute(_ context: inout GraphicsContext, points: [CGPoint]) {
        guard points.count > 1 else { return }
        var path = Path()
        path.move(to: points[0])
        for index in 1..<points.count {
            let from = points[index - 1], to = points[index]
            let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            let dx = to.x - from.x, dy = to.y - from.y
            // Bow each leg to alternating sides, like a hand-drawn line.
            let bend: CGFloat = index.isMultiple(of: 2) ? 0.18 : -0.18
            path.addQuadCurve(to: to, control: CGPoint(x: mid.x - dy * bend, y: mid.y + dx * bend))
        }
        context.stroke(path, with: .color(Paper.accent.opacity(0.85)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [4, 4.5]))
    }

    private func drawStamps(_ context: inout GraphicsContext, points: [CGPoint], size: CGSize) {
        let labelled: Set<Int> = points.count <= 6 ? Set(points.indices) : [0, points.count - 1]
        // Stamps count as taken, so a label never covers another city's mark.
        var placed: [CGRect] = points.map { CGRect(x: $0.x - 5, y: $0.y - 6, width: 10, height: 12) }
        for (index, point) in points.enumerated() {
            let isEnd = index == points.count - 1 && points.count > 1
            if index == 0 {
                // The start: a filled stamp.
                context.fill(Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)), with: .color(Paper.accent))
                context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)), with: .color(Paper.raised))
            } else if isEnd {
                // The end: a pin.
                var pin = context.resolve(Image(systemName: "mappin"))
                pin.shading = .color(Paper.accent)
                context.draw(pin, at: CGPoint(x: point.x, y: point.y - 7))
            } else {
                let ring = Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                context.fill(ring, with: .color(Paper.raised))
                context.stroke(ring, with: .color(Paper.accent), lineWidth: 1.4)
            }
        }
        // Labels after the stamps, ends first, so they keep theirs when space runs out.
        let order = points.count > 1 ? [0, points.count - 1] + Array(1..<(points.count - 1)) : [0]
        for index in order {
            let point = points[index]
            let isEnd = index == points.count - 1 && points.count > 1
            guard labelled.contains(index), index < stops.count else { continue }
            let label = context.resolve(
                Text(stops[index].name)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(Paper.ink)
            )
            let measured = label.measure(in: CGSize(width: size.width - 8, height: 20))
            // Try below, above, right and left of the stamp; skip a label
            // that would cover one already written.
            let lift: CGFloat = isEnd ? 22 : 10
            let candidates = [
                CGRect(x: point.x - measured.width / 2, y: point.y + 9, width: measured.width, height: measured.height),
                CGRect(x: point.x - measured.width / 2, y: point.y - lift - measured.height, width: measured.width, height: measured.height),
                CGRect(x: point.x + 9, y: point.y - measured.height / 2, width: measured.width, height: measured.height),
                CGRect(x: point.x - 9 - measured.width, y: point.y - measured.height / 2, width: measured.width, height: measured.height),
            ].map { rect in
                rect.offsetBy(
                    dx: min(max(0, 4 - rect.minX), size.width - 4 - rect.maxX),
                    dy: min(max(0, 4 - rect.minY), size.height - 4 - rect.maxY)
                )
            }
            let others = placed.enumerated().filter { $0.offset != index }.map(\.element)
            guard let spot = candidates.first(where: { rect in !others.contains { $0.intersects(rect.insetBy(dx: -2, dy: -1)) } }) else { continue }
            placed.append(spot)
            context.draw(label, in: spot)
        }
    }
}
