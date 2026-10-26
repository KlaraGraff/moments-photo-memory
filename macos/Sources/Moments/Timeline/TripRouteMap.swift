import SwiftUI

/// A small drawn map of a trip: the cities as stamps where they lie
/// relative to each other, joined in visiting order by a dashed, slightly
/// curved line, like a route pencilled into a travel journal. Not a real
/// map: no coastlines or borders, only the shape of the journey.
struct TripRouteMap: View {
    let stops: [TripRouteStop]

    var body: some View {
        Canvas { context, size in
            let points = Self.layout(stops, in: CGRect(origin: .zero, size: size).insetBy(dx: 26, dy: 24))
            drawPaper(&context, size: size)
            drawRoute(&context, points: points)
            drawStamps(&context, points: points, size: size)
        }
        .background(Paper.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(Text(stops.map(\.name).joined(separator: " → ")))
    }

    /// Places each stop by longitude and latitude, shrinking east–west by
    /// the latitude so distances look right, then fits them to the box
    /// keeping their proportions. One stop, or stops on one spot, sit in the middle.
    static func layout(_ stops: [TripRouteStop], in rect: CGRect) -> [CGPoint] {
        guard !stops.isEmpty else { return [] }
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
                guard stops.count > 1 else { return CGPoint(x: rect.midX, y: rect.midY) }
                let t = Double(index) / Double(stops.count - 1)
                return CGPoint(x: rect.minX + rect.width * (0.2 + 0.6 * t), y: rect.midY + sin(t * .pi) * -rect.height * 0.2)
            }
        }
        let scale = min(rect.width / max(width, span * 0.25), rect.height / max(height, span * 0.25))
        let offsetX = rect.midX - (minX + width / 2) * scale
        let offsetY = rect.midY - (minY + height / 2) * scale
        return raw.map { CGPoint(x: $0.x * scale + offsetX, y: $0.y * scale + offsetY) }
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
        let labelled: Set<Int> = points.count <= 5 ? Set(points.indices) : [0, points.count - 1]
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
            guard labelled.contains(index), index < stops.count else { continue }
            let label = context.resolve(
                Text(stops[index].name)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(Paper.ink)
            )
            let measured = label.measure(in: CGSize(width: size.width - 8, height: 20))
            let above = point.y > size.height * 0.5 || isEnd
            var x = point.x
            x = min(max(x, measured.width / 2 + 4), size.width - measured.width / 2 - 4)
            let y = above ? point.y - (isEnd ? 22 : 11) : point.y + 11
            context.draw(label, at: CGPoint(x: x, y: y), anchor: above ? .bottom : .top)
        }
    }
}
