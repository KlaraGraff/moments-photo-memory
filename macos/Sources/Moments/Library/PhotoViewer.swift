import AppKit
import AVKit
import MomentsCore
import Photos
import SwiftData
import SwiftUI

/// The large view of one photo, opened by a double click, Space or Return:
/// a card over the dimmed window with the photo on the left and what is
/// known about it on the right. The arrow keys page through the photos the
/// screen showed; Esc, Space or a click outside the card closes it.
struct PhotoViewer: View {
    @Environment(SelectionModel.self) private var selection
    @Environment(PhotoStackModel.self) private var stacks
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: ViewerRequest
    let libraryState: LibraryViewState
    @State private var item: MediaItem?
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var scopedURL: URL?
    @State private var isHovering = false
    @State private var zoom = ViewerZoom()
    /// The zoom at the start of a pinch, and the offset at the start of a drag.
    @State private var gestureBase: ViewerZoom?
    @State private var hoverLocation: CGPoint?
    @State private var areaSize: CGSize = .zero
    @State private var eventMonitor: Any?
    /// The neighbouring photos, ready to slide in beside the open one.
    @State private var previousImage: NSImage?
    @State private var nextImage: NSImage?
    /// How far the strip of photos has slid sideways: follows two fingers on
    /// the trackpad, then animates a whole page or springs back.
    @State private var pageOffset: CGFloat = 0
    /// The page turn being animated, finished at once if another one starts.
    @State private var pendingPage: Int?
    @State private var pageToken = UUID()
    @State private var swipeAxis = SwipeAxis.undecided
    @State private var lastSwipeStep: CGFloat = 0
    @State private var lastWheelPage = Date.distantPast
    @State private var isEditingInfo = false
    /// The shots of the open photo's stack, oldest first.
    @State private var stackMembers: [MediaItem] = []
    @FocusState private var isFocused: Bool

    /// A text field in the column has the keyboard: Esc and the arrows are its own.
    private var isEditingText: Bool {
        isEditingInfo || libraryState.focusedNoteItemID != nil
    }

    /// A text field or text view in this window is being typed in.
    private var isTyping: Bool {
        isEditingText || NSApp.keyWindow?.firstResponder is NSText
    }

    /// The request as it is now. The event monitor keeps the copy of this view
    /// taken when it was installed, whose `request` never changes; the model
    /// is shared, so reading through it is always current.
    private var live: ViewerRequest { selection.viewerRequest ?? request }

    /// The pages and each stack's shots, folded once when the order or the
    /// stacks change, so hovering and swiping stay cheap.
    @State private var paging = StackPaging.empty

    /// The open photo's stack as the screen showed it: its shots, oldest first.
    private var stackShots: [String] { paging.shots(of: live.itemID) }

    /// The burst the open photo belongs to, when the screen showed more than
    /// one of its shots.
    private var stack: PhotoStack? {
        stackShots.count > 1 ? stacks.stack(containing: live.itemID) : nil
    }

    /// Where the open photo sits among the pages, whichever shot of a stack is open.
    private var index: Int? { paging.page(of: live.itemID) }

    private var hasPrevious: Bool { neighbourID(-1) != nil }
    private var hasNext: Bool { neighbourID(1) != nil }

    /// The photo an arrow or swipe leads to: inside a stack its next shot,
    /// as the strip shows them, then the next page.
    private func neighbourID(_ offset: Int) -> String? {
        paging.neighbour(of: live.itemID, offset: offset)
    }

    /// Screens hand over every photo they show, a stack's shots included;
    /// the viewer folds them the way the grid does.
    @discardableResult
    private func rebuildPaging() -> StackPaging {
        let next = StackPaging(order: live.itemIDs, stacks: stacks.index)
        if next != paging { paging = next }
        return next
    }

    /// The cell that stands for a photo in the grid: a stack's cover, or its
    /// first shot shown when the cover was filtered out.
    private func gridCell(_ id: String, in paging: StackPaging) -> String {
        paging.page(of: id).map { paging.pages[$0].id } ?? id
    }

    var body: some View {
        ZStack {
            // The window dims behind the card; a click there closes it.
            Paper.shadow.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                headerBar
                HStack(spacing: 0) {
                    imageArea
                    infoPanel
                        .frame(width: 340)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Paper.raised)
                }
            }
            .background(Paper.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Paper.shadow.opacity(0.08)))
            .shadow(color: Paper.shadow.opacity(0.22), radius: 24, y: 8)
            // Like a file preview in Claude: the card covers the window, sidebar
            // included, with a narrow margin.
            .padding(10)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("viewer")
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            installEventMonitor()
            rebuildPaging()
            // An Undo offer from earlier (the Library's Unstack) is not about this photo.
            stacks.dismissLastChange()
        }
        // When a field in the column lets go of the keyboard, the arrows page again.
        .onChange(of: isEditingText) { _, editing in
            if !editing { isFocused = true }
        }
        // Key presses reach these handlers even while a field in the column
        // has the keyboard; then the keys are the field's own.
        .onKeyPress(.leftArrow) { !isTyping && page(-1) ? .handled : .ignored }
        .onKeyPress(.rightArrow) { !isTyping && page(1) ? .handled : .ignored }
        .onKeyPress(.space) {
            guard !isTyping else { return .ignored }
            close()
            return .handled
        }
        .task(id: request.itemID) { await load(request.itemID) }
        // Taken apart, a shot taken out, or Undo: the strip and the photos
        // ready to slide in follow.
        .onChange(of: selection.viewerRequest?.itemIDs ?? []) { _, _ in rebuildPaging() }
        .onChange(of: stacks.generation) { _, _ in
            // The grid's cell for this photo may now be another shot.
            let cell = gridCell(live.itemID, in: rebuildPaging())
            selection.select(cell)
            selection.anchorItemID = cell
        }
        .onChange(of: stackShots) { _, _ in
            loadStackMembers()
            nextImage = nil
            previousImage = nil
            Task { await loadNeighbours() }
        }
        .onDisappear {
            stopVideo()
            removeEventMonitor()
            stacks.dismissLastChange()
        }
    }

    /// Across the top of the card: the date, where it sits in the set, and the actions.
    private var headerBar: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(LibraryPalette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let index {
                Text("\(index + 1) / \(paging.pages.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(LibraryPalette.muted)
                    .accessibilityIdentifier("viewer.counter")
                    .accessibilityValue("\(index + 1)")
            }
            headerButton("chevron.left", label: String(localized: "Previous photo"), identifier: "viewer.previous") { page(-1) }
                .disabled(!hasPrevious)
            headerButton("chevron.right", label: String(localized: "Next photo"), identifier: "viewer.next") { page(1) }
                .disabled(!hasNext)
            if let stack {
                stackActions(stack)
            }
            if let item {
                Button {
                    item.setFavorite(!item.isFavorite, context: modelContext)
                    try? modelContext.save()
                } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(item.isFavorite ? .yellow : LibraryPalette.muted)
                        .symbolEffect(.bounce, value: item.isFavorite)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Favorite"))
                .accessibilityLabel(String(localized: "Favorite"))
            }
            headerButton("xmark", label: String(localized: "Close"), identifier: "viewer.close") { close() }
                .help(String(localized: "Close (Esc)"))
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .frame(height: 46)
    }

    private func headerButton(_ symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(LibraryPalette.muted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    /// For a burst: make the open shot the cover, take it out, or show all
    /// shots one by one. Icons only, with their names on hover.
    @ViewBuilder
    private func stackActions(_ stack: PhotoStack) -> some View {
        let isCover = stack.coverID == live.itemID
        let coverLabel = isCover ? String(localized: "Cover photo") : String(localized: "Set as cover")
        Divider().frame(height: 18)
        headerButton(isCover ? "star.square.on.square.fill" : "star.square.on.square", label: coverLabel, identifier: "viewer.stack.setCover") {
            stacks.setCover(live.itemID, of: stack, context: modelContext, undoManager: undoManager)
        }
        .disabled(isCover)
        .help(coverLabel)
        headerButton("rectangle.badge.minus", label: String(localized: "Remove from stack"), identifier: "viewer.stack.remove") {
            stacks.remove(live.itemID, from: stack, context: modelContext, undoManager: undoManager)
        }
        .help(String(localized: "Remove from stack"))
        headerButton("rectangle.stack.badge.minus", label: String(localized: "Unstack"), identifier: "viewer.stack.unstack") {
            stacks.unstack(stack, context: modelContext, undoManager: undoManager)
        }
        .help(String(localized: "Unstack"))
        Divider().frame(height: 18)
    }

    /// The photo, fitted with room around it; zoom makes it scroll.
    private var imageArea: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                media
                pagingButtons
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Tracked on the whole area, not the photo, so it survives the
            // photo being replaced while paging.
            .onContinuousHover { phase in
                if case .active(let location) = phase { hoverLocation = location } else { hoverLocation = nil }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { areaSize = geometry.size }
                        .onChange(of: geometry.size) { _, size in
                            areaSize = size
                            zoom.clampOffset(fitted: fittedSize, area: size)
                        }
                }
            }
            VStack(spacing: 10) {
                StackChangeUndoBar()
                if player == nil, image != nil {
                    zoomBar
                }
            }
            .padding(.bottom, 16)
        }
        .background(Paper.well)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let stack, stackMembers.count > 1 {
                ViewerStackStrip(stack: stack, members: stackMembers, currentID: live.itemID) { id in
                    showShot(id)
                }
                .background(Paper.well)
            }
        }
    }

    /// A small floating bar under the photo, like Claude's file preview.
    private var zoomBar: some View {
        HStack(spacing: 2) {
            zoomButton("minus.magnifyingglass", label: String(localized: "Zoom out"), enabled: zoom.isZoomed) { zoomStep(1 / 1.5) }
                .keyboardShortcut("-", modifiers: .command)
            zoomButton("plus.magnifyingglass", label: String(localized: "Zoom in"), enabled: zoom.scale < ViewerZoom.maximum) { zoomStep(1.5) }
                .keyboardShortcut("=", modifiers: .command)
        }
        .padding(4)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Paper.shadow.opacity(0.08)))
        .shadow(color: Paper.shadow.opacity(0.12), radius: 8, y: 2)
    }

    private func zoomButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(LibraryPalette.ink)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

 
    private var fittedSize: CGSize {
        guard let image else { return .zero }
        return Self.fittedSize(image.size, in: CGSize(width: areaSize.width - 56, height: areaSize.height - 56))
    }

    private var areaCenter: CGPoint {
        CGPoint(x: areaSize.width / 2, y: areaSize.height / 2)
    }

    /// The zoom buttons and ⌘− / ⌘= zoom around the centre of what is shown.
    private func zoomStep(_ factor: CGFloat) {
        animateZoom { $0.zoom(to: $0.scale * factor, anchor: areaCenter, fitted: fittedSize, area: areaSize) }
    }

    private func animateZoom(_ change: (inout ViewerZoom) -> Void) {
        var next = zoom
        change(&next)
        if reduceMotion {
            zoom = next
        } else {
            withAnimation(Motion.snap) { zoom = next }
        }
    }

    /// Pinch on the trackpad zooms around the fingers.
    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = gestureBase ?? zoom
                if gestureBase == nil { gestureBase = zoom }
                var next = base
                next.zoom(to: base.scale * value.magnification, anchor: value.startLocation, fitted: fittedSize, area: areaSize)
                zoom = next
            }
            .onEnded { _ in gestureBase = nil }
    }

    /// Dragging a zoomed photo moves it.
    private var pan: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard zoom.isZoomed else { return }
                let base = gestureBase ?? zoom
                if gestureBase == nil { gestureBase = zoom }
                var next = base
                next.pan(by: value.translation, fitted: fittedSize, area: areaSize)
                zoom = next
            }
            .onEnded { _ in gestureBase = nil }
    }

    /// Esc closes the viewer wherever the keyboard is, unless a text field
    /// has it: then Esc is the field's own (cancel or end typing), and the
    /// next Esc closes. The mouse wheel or ⌘-scroll zooms around the pointer;
    /// two fingers on the trackpad move a zoomed photo, as in Preview.
    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { event in
            let consumed = MainActor.assumeIsolated { handle(event) }
            return consumed ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard selection.viewerRequest != nil else { return false }
        if event.type == .keyDown {
            // 53 is Esc. Popovers (the date editor) and menus handle their own.
            guard event.keyCode == 53, let window = event.window, window.styleMask.contains(.titled),
                  !(window.firstResponder is NSText) else { return false }
            close()
            return true
        }
        guard let location = hoverLocation else { return false }
        let wheel = !event.hasPreciseScrollingDeltas || (event.phase.isEmpty && event.momentumPhase.isEmpty)
        let canZoom = player == nil && image != nil
        if event.modifierFlags.contains(.command) {
            guard canZoom else { return false }
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
            guard delta != 0 else { return true }
            var next = zoom
            next.zoom(to: zoom.scale * exp(delta / 120), anchor: location, fitted: fittedSize, area: areaSize)
            zoom = next
            return true
        }
        if zoom.isZoomed, canZoom {
            // A zoomed photo moves under two fingers or the wheel.
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            var next = zoom
            next.pan(by: CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor), fitted: fittedSize, area: areaSize)
            zoom = next
            return true
        }
        return wheel ? wheelPage(event) : swipe(event)
    }

    /// Each turn of the mouse wheel over the photo shows the next photo (towards
    /// you) or the previous one (away from you).
    private func wheelPage(_ event: NSEvent) -> Bool {
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        guard abs(delta) > 0.1 else { return true }
        // One page per notch, even when a fast spin sends a burst of them.
        let now = Date.now
        guard now.timeIntervalSince(lastWheelPage) > 0.2 else { return true }
        lastWheelPage = now
        let towardsYou = event.isDirectionInvertedFromDevice ? delta > 0 : delta < 0
        page(towardsYou ? 1 : -1)
        return true
    }

    /// Two fingers sideways on the trackpad slide the photos along with them,
    /// as in Photos; letting go far or fast enough turns the page, otherwise
    /// the photo springs back. Vertical swipes are left to the window.
    private func swipe(_ event: NSEvent) -> Bool {
        // The glide after the fingers lift belongs to the swipe that made it.
        if !event.momentumPhase.isEmpty { return swipeAxis == .horizontal }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            finishPendingPage()
            swipeAxis = .undecided
            pageOffset = 0
            lastSwipeStep = 0
        }
        if swipeAxis == .undecided, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            swipeAxis = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? .horizontal : .vertical
        }
        guard swipeAxis == .horizontal else { return false }
        // Positive when the fingers move right, whatever the scrolling direction setting.
        let fingers = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        if event.phase.contains(.changed) {
            let next = pageOffset + fingers
            // Past the first or last photo the strip gives only a little.
            let pastEnd = (next < 0 && !hasNext) || (next > 0 && !hasPrevious)
            pageOffset += pastEnd ? fingers * 0.3 : fingers
            if fingers != 0 { lastSwipeStep = fingers }
        }
        if event.phase.contains(.cancelled) {
            swipeAxis = .undecided
            settleBack()
        } else if event.phase.contains(.ended) {
            let direction = ViewerSwipe.direction(
                offset: pageOffset, width: areaSize.width, lastStep: lastSwipeStep,
                hasPrevious: hasPrevious, hasNext: hasNext
            )
            if direction == 0 { settleBack() } else { page(direction) }
        }
        return true
    }

    /// Slides to the neighbouring photo; false at either end. A page turn
    /// still animating is finished first, so held arrow keys keep up.
    @discardableResult
    private func page(_ direction: Int) -> Bool {
        finishPendingPage()
        guard neighbourID(direction) != nil else {
            settleBack()
            return false
        }
        guard !reduceMotion, areaSize.width > 0 else {
            completePage(direction)
            return true
        }
        pendingPage = direction
        let token = UUID()
        pageToken = token
        withAnimation(.spring(response: 0.3, dampingFraction: 0.92)) {
            pageOffset = direction > 0 ? -pageDistance : pageDistance
        } completion: {
            guard pageToken == token else { return }
            finishPendingPage()
        }
        return true
    }

    private func finishPendingPage() {
        guard let direction = pendingPage else { return }
        pendingPage = nil
        completePage(direction)
    }

    /// The neighbour that slid in becomes the open photo, in place, with no
    /// further movement.
    private func completePage(_ direction: Int) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            stopVideo()
            if direction > 0 {
                previousImage = image
                image = nextImage
                nextImage = nil
            } else {
                nextImage = image
                image = previousImage
                previousImage = nil
            }
            pageOffset = 0
            zoom = ViewerZoom()
            _ = step(direction)
        }
    }

    private func settleBack() {
        guard pageOffset != 0 else { return }
        if reduceMotion {
            pageOffset = 0
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { pageOffset = 0 }
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    /// The right-hand column: when, where, who, and the words written for
    /// this photo, each editable in place.
    @ViewBuilder
    private var infoPanel: some View {
        if let item {
            PhotoInfoPanel(item: item, libraryState: libraryState, isEditing: $isEditingInfo)
                .id(item.id)
        } else {
            Color.clear
        }
    }

    /// The open photo with its neighbours either side, off screen until the
    /// strip slides.
    private var media: some View {
        ZStack {
            if pageOffset != 0 {
                neighbour(previousImage).offset(x: pageOffset - pageDistance)
                neighbour(nextImage).offset(x: pageOffset + pageDistance)
            }
            current.offset(x: pageOffset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private static let pageGap: CGFloat = 40

    private var pageDistance: CGFloat { areaSize.width + Self.pageGap }

    @ViewBuilder
    private func neighbour(_ image: NSImage?) -> some View {
        if let image {
            let size = Self.fittedSize(image.size, in: CGSize(width: areaSize.width - 56, height: areaSize.height - 56))
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
                .shadow(color: Paper.shadow.opacity(0.12), radius: 10, y: 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var current: some View {
        if let player {
            VideoPlayerView(player: player)
                .accessibilityIdentifier("viewer.video")
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(28)
        } else if let image {
            let fitted = fittedSize
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: fitted.width, height: fitted.height)
                .shadow(color: Paper.shadow.opacity(zoom.isZoomed ? 0 : 0.12), radius: 10, y: 4)
                .scaleEffect(zoom.scale)
                .offset(zoom.offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                // Double click zooms to twice the size at that point, and back to fit.
                .gesture(SpatialTapGesture(count: 2).onEnded { value in
                    animateZoom { zoom in
                        if zoom.isZoomed {
                            zoom.reset()
                        } else {
                            zoom.zoom(to: 2, anchor: value.location, fitted: fitted, area: areaSize)
                        }
                    }
                })
                .simultaneousGesture(magnify)
                .simultaneousGesture(pan)
                .clipped()
                .accessibilityLabel(title)
                .accessibilityIdentifier("viewer.image")
                .accessibilityValue(String(format: "%.0f%%", zoom.scale * 100))
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private static func fittedSize(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private var pagingButtons: some View {
        HStack {
            pagingButton("chevron.left", label: String(localized: "Previous photo"), identifier: "viewer.previous", enabled: hasPrevious) { page(-1) }
            Spacer()
            pagingButton("chevron.right", label: String(localized: "Next photo"), identifier: "viewer.next", enabled: hasNext) { page(1) }
        }
        .padding(.horizontal, 14)
        .opacity(isHovering ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
    }

    private func pagingButton(_ symbol: String, label: String, identifier: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(LibraryPalette.ink)
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var title: String {
        guard let date = item?.effectiveCaptureDate else { return item?.title ?? "" }
        return date.formatted(date: .long, time: .shortened)
    }

    /// Moves to the neighbouring photo (see `neighbourID`); false at either end.
    private func step(_ offset: Int) -> Bool {
        guard let id = neighbourID(offset) else { return false }
        show(id)
        return true
    }

    /// A shot picked in the strip: its picture at once from a cache when
    /// there is one, so the old shot doesn't linger while it loads.
    private func showShot(_ id: String) {
        guard id != live.itemID else { return }
        stopVideo()
        image = PhotoViewerImageCache.shared.image(for: id) ?? ThumbnailCache.shared.cachedImage(for: id, width: 560, height: 420)
        // The photos ready either side were the old shot's neighbours.
        nextImage = nil
        previousImage = nil
        zoom = ViewerZoom()
        show(id)
    }

    private func show(_ id: String) {
        // Screens show a stack as one cell: select that, so the grid marks
        // and reveals the stack after the viewer closes.
        let cell = gridCell(id, in: paging)
        selection.select(cell)
        selection.anchorItemID = cell
        selection.viewerRequest?.itemID = id
        isFocused = true
    }

    private func close() {
        selection.viewerRequest = nil
    }

    private func load(_ id: String) async {
        stopVideo()
        var descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let found = try? modelContext.fetch(descriptor).first else {
            item = nil
            image = nil
            return
        }
        item = found
        loadStackMembers()
        zoom = ViewerZoom()
        // Neighbours start loading now, alongside this photo, so a quick second
        // swipe already has something to slide in.
        async let neighbours: Void = loadNeighbours()
        if let cached = PhotoViewerImageCache.shared.image(for: id) {
            image = cached
        } else {
            // The grid's thumbnail first, so the photo appears at once; the
            // full-size image replaces it when it is ready. A page turned in
            // the meantime cancels this, and nothing is written after that.
            let thumbnail = await ThumbnailCache.shared.image(for: found, width: 560, height: 420)
            guard !Task.isCancelled else { return await neighbours }
            if image == nil { image = thumbnail }
            if let full = await PhotoViewerImageCache.shared.load(found), !Task.isCancelled {
                image = full
            }
        }
        if !Task.isCancelled, found.kind == .video { startVideo(found) }
        await neighbours
    }

    private func loadStackMembers() {
        let ids = stackShots
        guard ids.count > 1 else {
            stackMembers = []
            return
        }
        guard stackMembers.map(\.id) != ids else { return }
        let found = (try? modelContext.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        stackMembers = ids.compactMap { byID[$0] }
    }

    /// The photos either side, so a swipe can slide them in at once: a
    /// thumbnail first when the full image isn't ready.
    private func loadNeighbours() async {
        let nextID = neighbourID(1)
        let previousID = neighbourID(-1)
        async let next: Void = fillNeighbour(nextID, isNext: true)
        async let previous: Void = fillNeighbour(previousID, isNext: false)
        _ = await (next, previous)
    }

    private func fillNeighbour(_ id: String?, isNext: Bool) async {
        func set(_ value: NSImage?) {
            guard !Task.isCancelled else { return }
            if isNext { nextImage = value } else { previousImage = value }
        }
        guard let id else { return set(nil) }
        if let cached = PhotoViewerImageCache.shared.image(for: id) { return set(cached) }
        var descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let neighbour = try? modelContext.fetch(descriptor).first else { return set(nil) }
        if let thumbnail = await ThumbnailCache.shared.image(for: neighbour, width: 560, height: 420),
           (isNext ? nextImage : previousImage) == nil {
            set(thumbnail)
        }
        if let full = await PhotoViewerImageCache.shared.load(neighbour) { set(full) }
    }

    private func startVideo(_ item: MediaItem) {
        if let bookmark = item.originalBookmarkData,
           let resolved = try? OriginalMediaBookmark.resolve(bookmark) {
            if resolved.url.startAccessingSecurityScopedResource() { scopedURL = resolved.url }
            player = AVPlayer(url: resolved.url)
            return
        }
        // Videos from the Photos library play through PhotoKit.
        guard let localIdentifier = item.photosLocalIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else { return }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        let requestedID = item.id
        PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { playerItem, _ in
            guard let playerItem else { return }
            DispatchQueue.main.async {
                guard selection.viewerRequest?.itemID == requestedID else { return }
                player = AVPlayer(playerItem: playerItem)
            }
        }
    }

    private func stopVideo() {
        player?.pause()
        player = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }
}

/// Full-size images for the viewer: the open photo and its neighbours.
@MainActor
final class PhotoViewerImageCache {
    static let shared = PhotoViewerImageCache()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 8
        return cache
    }()

    func image(for id: String) -> NSImage? {
        cache.object(forKey: id as NSString)
    }

    func load(_ item: MediaItem) async -> NSImage? {
        if let cached = image(for: item.id) { return cached }
        let descriptor = PeopleMediaDescriptor(item)
        let cgImage = await Task.detached(priority: .userInitiated) {
            await PeopleImageLoader.load(descriptor)
        }.value
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: item.id as NSString)
        return image
    }
}

/// AppKit's player view. SwiftUI's `VideoPlayer` aborted the app on macOS 27
/// when it was first shown: its AVKit overlay could not find its superclass
/// `AVPlayerView`, because nothing else in the app loaded AVKit.
private struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
