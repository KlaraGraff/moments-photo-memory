import AppKit
import AVKit
import Photos
import SwiftData
import SwiftUI

/// The large view of one photo, opened by a double click, Space or Return:
/// a card over the dimmed window with the photo on the left and what is
/// known about it on the right. The arrow keys page through the photos the
/// screen showed; Esc, Space or a click outside the card closes it.
struct PhotoViewer: View {
    @Environment(SelectionModel.self) private var selection
    @Environment(\.modelContext) private var modelContext
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
    /// How far two fingers have moved sideways in this swipe, and whether it
    /// already turned the page.
    @State private var swipeDistance: CGFloat = 0
    @State private var swipePaged = false
    @State private var isEditingInfo = false
    @FocusState private var isFocused: Bool

    /// A text field in the column has the keyboard: Esc and the arrows are its own.
    private var isEditingText: Bool {
        isEditingInfo || libraryState.focusedNoteItemID != nil
    }

    /// A text field or text view in this window is being typed in.
    private var isTyping: Bool {
        isEditingText || NSApp.keyWindow?.firstResponder is NSText
    }

    private var index: Int? { request.itemIDs.firstIndex(of: request.itemID) }
    private var hasPrevious: Bool { (index ?? 0) > 0 }
    private var hasNext: Bool { (index ?? request.itemIDs.count) < request.itemIDs.count - 1 }

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
        }
        // When a field in the column lets go of the keyboard, the arrows page again.
        .onChange(of: isEditingText) { _, editing in
            if !editing { isFocused = true }
        }
        // Key presses reach these handlers even while a field in the column
        // has the keyboard; then the keys are the field's own.
        .onKeyPress(.leftArrow) { !isTyping && step(-1) ? .handled : .ignored }
        .onKeyPress(.rightArrow) { !isTyping && step(1) ? .handled : .ignored }
        .onKeyPress(.space) {
            guard !isTyping else { return .ignored }
            close()
            return .handled
        }
        .task(id: request.itemID) { await load(request.itemID) }
        .onDisappear {
            stopVideo()
            removeEventMonitor()
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
                Text("\(index + 1) / \(request.itemIDs.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(LibraryPalette.muted)
                    .accessibilityIdentifier("viewer.counter")
                    .accessibilityValue("\(index + 1)")
            }
            headerButton("chevron.left", label: String(localized: "Previous photo"), identifier: "viewer.previous") { _ = step(-1) }
                .disabled(!hasPrevious)
            headerButton("chevron.right", label: String(localized: "Next photo"), identifier: "viewer.next") { _ = step(1) }
                .disabled(!hasNext)
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

    /// The photo, fitted with room around it; zoom makes it scroll.
    private var imageArea: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                media
                pagingButtons
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if player == nil, image != nil {
                zoomBar.padding(.bottom, 16)
            }
        }
        .background(Paper.well)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
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
        guard player == nil, image != nil, let location = hoverLocation else { return false }
        let wheel = !event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.command) || wheel {
            let delta = wheel ? event.scrollingDeltaY * 12 : event.scrollingDeltaY
            guard delta != 0 else { return true }
            var next = zoom
            next.zoom(to: zoom.scale * exp(delta / 120), anchor: location, fitted: fittedSize, area: areaSize)
            zoom = next
            return true
        }
        guard zoom.isZoomed else { return swipe(event) }
        var next = zoom
        next.pan(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY), fitted: fittedSize, area: areaSize)
        zoom = next
        return true
    }

    /// Two fingers sideways on the trackpad turn to the next or previous
    /// photo, once per swipe, as in Photos. The slide that continues after
    /// the fingers lift is swallowed so it doesn't scroll the grid behind.
    private func swipe(_ event: NSEvent) -> Bool {
        if !event.momentumPhase.isEmpty { return swipePaged || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) }
        guard event.hasPreciseScrollingDeltas else { return false }
        if event.phase.contains(.began) {
            swipeDistance = 0
            swipePaged = false
        }
        swipeDistance += event.scrollingDeltaX
        guard abs(swipeDistance) > abs(event.scrollingDeltaY) || swipePaged else { return false }
        if !swipePaged, abs(swipeDistance) > 50 {
            // Fingers moving left bring the next photo in from the right.
            let towardsNext = event.isDirectionInvertedFromDevice ? swipeDistance < 0 : swipeDistance > 0
            _ = step(towardsNext ? 1 : -1)
            swipePaged = true
        }
        return true
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

    @ViewBuilder
    private var media: some View {
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
                .onContinuousHover { phase in
                    if case .active(let location) = phase { hoverLocation = location } else { hoverLocation = nil }
                }
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
            pagingButton("chevron.left", label: String(localized: "Previous photo"), identifier: "viewer.previous", enabled: hasPrevious) { _ = step(-1) }
            Spacer()
            pagingButton("chevron.right", label: String(localized: "Next photo"), identifier: "viewer.next", enabled: hasNext) { _ = step(1) }
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

    /// Moves to the neighbouring photo; false at either end.
    private func step(_ offset: Int) -> Bool {
        guard let index else { return false }
        let target = index + offset
        guard request.itemIDs.indices.contains(target) else { return false }
        let id = request.itemIDs[target]
        selection.select(id)
        selection.anchorItemID = id
        selection.viewerRequest?.itemID = id
        isFocused = true
        return true
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
        zoom = ViewerZoom()
        if let cached = PhotoViewerImageCache.shared.image(for: id) {
            image = cached
        } else {
            // The grid's thumbnail first, so the photo appears at once; the
            // full-size image replaces it when it is ready.
            image = await ThumbnailCache.shared.image(for: found, width: 560, height: 420)
            if let full = await PhotoViewerImageCache.shared.load(found), !Task.isCancelled {
                image = full
            }
        }
        guard !Task.isCancelled else { return }
        if found.kind == .video { startVideo(found) }
        prefetchNeighbours()
    }

    private func prefetchNeighbours() {
        guard let index else { return }
        for offset in [1, -1] where request.itemIDs.indices.contains(index + offset) {
            let id = request.itemIDs[index + offset]
            var descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let neighbour = try? modelContext.fetch(descriptor).first else { continue }
            Task { _ = await PhotoViewerImageCache.shared.load(neighbour) }
        }
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
