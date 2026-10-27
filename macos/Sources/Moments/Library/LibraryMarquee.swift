import AppKit
import QuartzCore
import SwiftUI

/// Rubber-band selection in a Library-style grid, the way Photos does it.
///
/// A drag that starts between photos draws a rectangle, and every photo it
/// touches is selected while the rectangle grows. Command toggles the photos
/// it touches against what was selected before, Shift adds them. Held near
/// the top or bottom edge, or past it, the grid keeps scrolling (faster the
/// further out the pointer is) and the rectangle keeps growing with it.
///
/// Photos report their frames in the grid content's coordinates
/// (`LibraryMarquee.space`). The scrolling and the pointer are read from the
/// grid's NSScrollView once per display frame, so a pointer that stands still
/// at the edge still scrolls. The rectangle is a plain AppKit layer over the
/// scroll view, so drawing it never touches SwiftUI; only the selection
/// marks of photos the rectangle reaches or leaves redraw.
@MainActor
final class LibraryMarquee {
    static let space = "library.marquee"

    enum Mode: Equatable {
        /// A plain drag selects only what it touches.
        case replace
        /// Shift adds what it touches.
        case add
        /// Command flips what it touches.
        case toggle
    }

    /// The rectangle being dragged, in content coordinates.
    private var rect: CGRect?
    private var band: BandView?

    private struct Frame {
        var rect: CGRect
        var layout: Int
    }

    private struct Press {
        var start: CGPoint
        var mode: Mode
        var base: Set<String>
        /// Content coordinates minus the scroll document's: measured at the
        /// press, so the pointer can be read from AppKit while scrolling.
        var offset: CGVector?
        var isDragging = false
        var hits: Set<String> = []
    }

    /// Each photo's last frame, kept after it scrolls out of the lazy grid
    /// so a drag that scrolled past it still knows where it is.
    ///
    /// A photo reports its frame only when the frame changes. One the grid
    /// built before and shows again where it was reports nothing, so a
    /// frame stays good until the grid's layout changes (regrouped,
    /// filtered, zoomed, resized), not just for one drag.
    private var frames: [String: Frame] = [:]
    /// Photos the grid shows right now, counted per view (a rebuilt cell can
    /// appear before the old one goes); their frames stay current.
    private var live: [String: Int] = [:]
    /// Counts layout changes; only frames from the current layout count.
    private var layout = 0
    /// A frame came in or counted again since the last hit test.
    private var framesChanged = false
    private var press: Press?
    weak var anchorView: NSView?
    private weak var scrollView: NSScrollView?
    private var displayLink: CADisplayLink?
    private var linkTarget: LinkTarget?
    private var lastTick: CFTimeInterval = 0
    private weak var selection: SelectionModel?
    private var order: () -> [String] = { [] }

    init() {}

    /// A rubber band is being dragged (not just pressed).
    var isDragging: Bool { press?.isDragging == true }

    // MARK: Photo frames

    func report(_ id: String, frame: CGRect) {
        frames[id] = Frame(rect: frame, layout: layout)
        framesChanged = true
    }

    /// A photo shown again after a layout change that landed where it was
    /// reports no frame, so its last one counts again; if it moved, `report`
    /// follows with the new one.
    func appeared(_ id: String) {
        live[id, default: 0] += 1
        if frames[id]?.layout != layout {
            frames[id]?.layout = layout
            framesChanged = true
        }
    }

    func disappeared(_ id: String) {
        let count = (live[id] ?? 0) - 1
        live[id] = count > 0 ? count : nil
    }

    /// The grid was regrouped, filtered, zoomed or resized: photos it does
    /// not show may now be somewhere else, so their frames stop counting
    /// until they report again. Shown ones report if they moved.
    func layoutChanged() {
        layout += 1
        for id in live.keys {
            frames[id]?.layout = layout
        }
        framesChanged = true
    }

    // MARK: Drag

    /// Called for every change of the background's drag gesture, from the
    /// mouse-down on.
    func dragChanged(_ value: DragGesture.Value, selection: SelectionModel, order: @escaping () -> [String]) {
        if press == nil || press?.start != value.startLocation {
            begin(at: value.startLocation, location: value.location, selection: selection, order: order)
        }
        guard var current = press else { return }
        if !current.isDragging {
            guard hypot(value.translation.width, value.translation.height) >= 3 else { return }
            current.isDragging = true
            press = current
            startDragging()
        }
        if let point = pointerInContent() {
            update(to: point)
        } else {
            update(to: value.location)
        }
    }

    /// Mouse up. A press that never moved is a click on the background:
    /// it clears the selection, unless Command or Shift is held.
    func dragEnded(selection: SelectionModel) {
        guard let current = press else { return }
        if current.isDragging {
            finish()
        } else {
            press = nil
            if current.mode == .replace { selection.clear() }
        }
    }

    /// `location` is where the pointer is now, in content coordinates; it is
    /// paired with the same pointer in the scroll document to map one onto
    /// the other.
    private func begin(at start: CGPoint, location: CGPoint, selection: SelectionModel, order: @escaping () -> [String]) {
        stopTicking()
        removeBand()
        rect = nil
        self.selection = selection
        self.order = order
        let flags = NSEvent.modifierFlags
        let mode: Mode = flags.contains(.command) ? .toggle : flags.contains(.shift) ? .add : .replace
        // A press between photos ends note editing, as a click on a photo does.
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        let event = NSApp.currentEvent
        let isMouse = event?.type == .leftMouseDown || event?.type == .leftMouseDragged
        let windowPoint = isMouse ? event?.locationInWindow : anchorView?.window?.mouseLocationOutsideOfEventStream
        scrollView = windowPoint.flatMap { findScrollView(at: $0) }
        var offset: CGVector?
        if let windowPoint, let document = scrollView?.documentView {
            let point = document.convert(windowPoint, from: nil)
            offset = CGVector(dx: location.x - point.x, dy: location.y - point.y)
        }
        press = Press(start: start, mode: mode, base: selection.selectedItemIDs, offset: offset)
    }

    private func startDragging() {
        #if DEBUG
        MarqueeProbe.dragStarted()
        #endif
        guard let scrollView else { return }
        let target = LinkTarget(marquee: self)
        let link = scrollView.displayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        linkTarget = target
        displayLink = link
        lastTick = 0
    }

    private func finish() {
        guard let current = press else { return }
        #if DEBUG
        // Photos inside the rectangle whose frames the drag did not count.
        let uncounted = rect.map { rect in
            frames.filter { $0.value.layout != layout && Self.touches(rect, $0.value.rect) }.keys.sorted()
        } ?? []
        #endif
        stopTicking()
        removeBand()
        press = nil
        rect = nil
        #if DEBUG
        MarqueeProbe.dragEnded(
            selected: selection?.selectedItemIDs.count ?? 0,
            scrolledTo: scrollView?.contentView.bounds.origin.y ?? 0,
            uncounted: uncounted.map { "\($0)\(live[$0] != nil ? " (on screen)" : "")" }
        )
        #endif
        guard let selection else { return }
        // The first photo the rectangle touched anchors a later Shift-click
        // and is where the arrow keys go on from.
        if let first = order().first(where: { current.hits.contains($0) && selection.selectedItemIDs.contains($0) }) {
            selection.anchorItemID = first
            selection.focusedItemID = first
        }
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
        linkTarget = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        // A mouse-up the gesture never reported (the window lost the drag).
        guard NSEvent.pressedMouseButtons & 1 == 1 else {
            finish()
            return
        }
        guard let scrollView, let document = scrollView.documentView else { return }
        let now = link.timestamp
        // Real elapsed time keeps the speed steady when a frame is late.
        let elapsed = lastTick == 0 ? link.duration : min(max(now - lastTick, 0), 0.1)
        lastTick = now
        #if DEBUG
        MarqueeProbe.frame(at: now, scrolledTo: scrollView.contentView.bounds.origin.y)
        #endif
        if let pointer = pointerInDocument() {
            let clip = scrollView.contentView
            let insets = scrollView.contentInsets
            let velocity = Self.autoscrollVelocity(
                pointerY: pointer.y,
                top: clip.bounds.minY + insets.top,
                bottom: clip.bounds.maxY - insets.bottom
            )
            if velocity != 0 {
                let minY = -insets.top
                let maxY = max(minY, document.frame.height - clip.bounds.height + insets.bottom)
                let y = min(max(clip.bounds.origin.y + velocity * elapsed, minY), maxY)
                if y != clip.bounds.origin.y {
                    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                    scrollView.reflectScrolledClipView(clip)
                    #if DEBUG
                    MarqueeProbe.autoscrolled(to: clip.bounds.origin.y)
                    #endif
                }
            }
        }
        if let point = pointerInContent() { update(to: point) }
        // The rectangle sits still in the content while the view scrolls.
        placeBand()
    }

    private func update(to point: CGPoint) {
        guard var current = press, current.isDragging else { return }
        let next = CGRect(
            x: min(current.start.x, point.x),
            y: min(current.start.y, point.y),
            width: abs(point.x - current.start.x),
            height: abs(point.y - current.start.y)
        )
        // A photo that reports while the pointer rests is tested too.
        guard next != rect || framesChanged else { return }
        framesChanged = false
        if next != rect {
            rect = next
            placeBand()
        }
        var hits: Set<String> = []
        for (id, frame) in frames where frame.layout == layout && Self.touches(next, frame.rect) {
            hits.insert(id)
        }
        guard hits != current.hits else { return }
        current.hits = hits
        press = current
        guard let selection else { return }
        let selected = Self.selection(base: current.base, hits: hits, mode: current.mode)
        if selected != selection.selectedItemIDs {
            selection.selectedItemIDs = selected
            #if DEBUG
            MarqueeProbe.selectionChanged()
            #endif
        }
    }

    // MARK: Rectangle

    /// Draws `rect` over the scroll view, clipped to what is visible.
    private func placeBand() {
        guard let rect, let offset = press?.offset, let scrollView, let document = scrollView.documentView else { return }
        let inDocument = rect.offsetBy(dx: -offset.dx, dy: -offset.dy)
        let visible = scrollView.convert(inDocument, from: document).intersection(scrollView.contentView.frame)
        if band == nil {
            let view = BandView()
            scrollView.addSubview(view, positioned: .above, relativeTo: scrollView.contentView)
            band = view
        }
        band?.isHidden = visible.isNull || visible.isEmpty
        if !visible.isNull, band?.frame != visible { band?.frame = visible }
    }

    private func removeBand() {
        band?.removeFromSuperview()
        band = nil
    }

    /// The rubber band: a translucent fill with a thin edge, like Photos.
    private final class BandView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor(LibraryPalette.ink).withAlphaComponent(0.08).cgColor
            layer?.borderColor = NSColor(LibraryPalette.ink).withAlphaComponent(0.32).cgColor
            layer?.borderWidth = 1
            // Frame changes follow the pointer, never animate.
            layer?.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isFlipped: Bool { true }
    }

    // MARK: Pointer

    private func pointerInDocument() -> CGPoint? {
        guard let scrollView, let document = scrollView.documentView, let window = scrollView.window else { return nil }
        var point = document.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        // The rectangle stops at the content's edges, as in Photos.
        point.x = min(max(point.x, document.bounds.minX), document.bounds.maxX)
        point.y = min(max(point.y, document.bounds.minY), document.bounds.maxY)
        return point
    }

    private func pointerInContent() -> CGPoint? {
        guard let offset = press?.offset, let point = pointerInDocument() else { return nil }
        return CGPoint(x: point.x + offset.dx, y: point.y + offset.dy)
    }

    /// The grid's scroll view: the one around the anchor, or else the
    /// tallest one under the pointer.
    private func findScrollView(at windowPoint: NSPoint) -> NSScrollView? {
        if let enclosing = anchorView?.enclosingScrollView { return enclosing }
        guard let content = anchorView?.window?.contentView ?? NSApp.keyWindow?.contentView else { return nil }
        var found: [NSScrollView] = []
        func collect(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.convert(scroll.bounds, to: nil).contains(windowPoint) {
                found.append(scroll)
            }
            view.subviews.forEach(collect)
        }
        collect(content)
        return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    // MARK: Rules

    /// Photos whose frames the rectangle touches.
    nonisolated static func hits(in rect: CGRect, frames: [String: CGRect]) -> Set<String> {
        Set(frames.filter { touches(rect, $0.value) }.keys)
    }

    /// Edges count: a rectangle only as wide as a line still selects.
    nonisolated static func touches(_ rect: CGRect, _ frame: CGRect) -> Bool {
        frame.minX <= rect.maxX && frame.maxX >= rect.minX && frame.minY <= rect.maxY && frame.maxY >= rect.minY
    }

    nonisolated static func selection(base: Set<String>, hits: Set<String>, mode: Mode) -> Set<String> {
        switch mode {
        case .replace: return hits
        case .add: return base.union(hits)
        case .toggle: return base.symmetricDifference(hits)
        }
    }

    /// Points per second to scroll, negative for up: nothing away from the
    /// edges, then faster the closer the pointer is to an edge, and faster
    /// still past it, so holding still keeps the grid moving.
    nonisolated static func autoscrollVelocity(pointerY y: CGFloat, top: CGFloat, bottom: CGFloat, zone: CGFloat = 44) -> CGFloat {
        let zone = max(1, min(zone, (bottom - top) / 4))
        if y > bottom - zone { return speed(depth: (y - (bottom - zone)) / zone) }
        if y < top + zone { return -speed(depth: (top + zone - y) / zone) }
        return 0
    }

    /// `depth` is 0 where the edge zone begins, 1 at the edge, more past it.
    private nonisolated static func speed(depth: CGFloat) -> CGFloat {
        if depth <= 1 { return 120 + 780 * depth * depth }
        return min(3200, 900 + 1100 * (depth - 1))
    }

    private final class LinkTarget: NSObject {
        weak var marquee: LibraryMarquee?

        init(marquee: LibraryMarquee) {
            self.marquee = marquee
        }

        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { marquee?.tick(link) }
        }
    }
}

extension View {
    /// Rubber-band selection on a Library-style grid's scroll content, and a
    /// click between photos that deselects everything. Photos in the grid
    /// report their frames with `libraryMarqueeTarget`.
    func libraryMarqueeSelection(state: LibraryViewState, selection: SelectionModel) -> some View {
        modifier(LibraryMarqueeSelection(marquee: state.marquee, state: state, selection: selection))
    }

    /// A photo the rubber band can select.
    func libraryMarqueeTarget(_ id: String, marquee: LibraryMarquee) -> some View {
        modifier(LibraryMarqueeTarget(id: id, marquee: marquee))
    }
}

private struct LibraryMarqueeSelection: ViewModifier {
    let marquee: LibraryMarquee
    let state: LibraryViewState
    let selection: SelectionModel
    @AppStorage(LibraryThumbnailSize.storageKey) private var zoom = LibraryThumbnailSize.defaultColumns

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(LibraryMarquee.space))
            // What moves photos the grid does not show right now.
            .onChange(of: state.orderedItemIDs) { marquee.layoutChanged() }
            .onChange(of: zoom) { marquee.layoutChanged() }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _ in marquee.layoutChanged() }
            .background(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    // From the mouse-down on, so a click without a drag
                    // still clears the selection.
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(LibraryMarquee.space))
                            .onChanged { value in
                                marquee.dragChanged(value, selection: selection) { [state] in state.orderedItemIDs }
                            }
                            .onEnded { _ in marquee.dragEnded(selection: selection) }
                    )
                    .overlay(alignment: .topLeading) {
                        LibraryMarqueeAnchor(marquee: marquee)
                            .frame(width: 1, height: 1)
                    }
                    .accessibilityHidden(true)
            }
    }
}

private struct LibraryMarqueeTarget: ViewModifier {
    let id: String
    let marquee: LibraryMarquee

    func body(content: Content) -> some View {
        content
            // Content coordinates do not change while the grid scrolls, so
            // this runs when the grid is laid out, not on every frame.
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(LibraryMarquee.space)) }) { frame in
                marquee.report(id, frame: frame)
            }
            .onAppear { marquee.appeared(id) }
            .onDisappear { marquee.disappeared(id) }
    }
}

/// A point-sized AppKit view inside the scroll content, so the marquee can
/// find the NSScrollView it scrolls. It never takes clicks.
private struct LibraryMarqueeAnchor: NSViewRepresentable {
    let marquee: LibraryMarquee

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        marquee.anchorView = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        marquee.anchorView = view
    }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

#if DEBUG
/// UI-test-only, enabled by `-MomentsUITestMarqueeProbe <folder>`: records
/// every display frame of a rubber-band drag (late frames mean the main
/// thread was busy) and writes `marquee-report.txt` when the drag ends.
@MainActor
enum MarqueeProbe {
    private static var folder: URL? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-MomentsUITestMarqueeProbe"), index + 1 < arguments.count else { return nil }
        let url = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private static var lastFrame: CFTimeInterval = 0
    private static var intervals: [CFTimeInterval] = []
    private static var selectionChanges = 0
    private static var reports = 0
    /// Where the last autoscroll step left the view, and how often the view
    /// was somewhere else by the next frame (something scrolled it back).
    private static var autoscrolledTo: CGFloat?
    private static var snapBacks = 0
    private static var worstSnapBack: CGFloat = 0

    static func dragStarted() {
        guard folder != nil else { return }
        lastFrame = 0
        intervals = []
        selectionChanges = 0
        autoscrolledTo = nil
        snapBacks = 0
        worstSnapBack = 0
        MainThreadSampler.start()
    }

    static func frame(at time: CFTimeInterval, scrolledTo offset: CGFloat) {
        guard folder != nil else { return }
        if let expected = autoscrolledTo, offset < expected - 1 {
            snapBacks += 1
            worstSnapBack = max(worstSnapBack, expected - offset)
        }
        autoscrolledTo = nil
        if lastFrame > 0 { intervals.append(time - lastFrame) }
        lastFrame = time
    }

    static func autoscrolled(to offset: CGFloat) {
        guard folder != nil else { return }
        autoscrolledTo = offset
    }

    static func selectionChanged() {
        guard folder != nil else { return }
        selectionChanges += 1
    }

    static func dragEnded(selected: Int, scrolledTo offset: CGFloat, uncounted: [String]) {
        guard let folder else { return }
        reports += 1
        let frame = 1.0 / 60.0
        let sorted = intervals.sorted()
        let total = intervals.reduce(0, +)
        let late = intervals.filter { $0 > frame * 1.5 }
        let hitch = late.reduce(0) { $0 + ($1 - frame) }
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000
        }
        var text = String(
            format: "marquee report %d: %d frames over %.2fs, late %d, hitch %.0f ms/s, p50 %.1fms p95 %.1fms worst %.1fms, stalls>100ms %d\n",
            reports, intervals.count, total, late.count, total > 0 ? hitch * 1000 / total : 0,
            percentile(0.5), percentile(0.95), (sorted.last ?? 0) * 1000, intervals.filter { $0 > 0.1 }.count
        )
        text += String(format: "  selected %d photos, %d selection changes, scrolled to %.0f pt\n", selected, selectionChanges, offset)
        text += String(format: "  scrolled back by something else: %d times, worst %.0f pt\n", snapBacks, worstSnapBack)
        text += "  inside the rectangle but not counted: \(uncounted.count)\(uncounted.isEmpty ? "" : " " + uncounted.joined(separator: ", "))\n"
        text += MainThreadSampler.stopAndReport()
        try? text.write(to: folder.appending(path: "marquee-report-\(reports).txt"), atomically: true, encoding: .utf8)
    }
}
#endif
