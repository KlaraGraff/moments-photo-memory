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
    @Query private var placeNotes: [PlaceNote]
    @State private var item: MediaItem?
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var scopedURL: URL?
    @State private var isHovering = false
    @State private var peopleNames: [String] = []
    @State private var zoom: CGFloat = 1
    @FocusState private var isFocused: Bool

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
                        .frame(width: 300)
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
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) { step(-1) ? .handled : .ignored }
        .onKeyPress(.rightArrow) { step(1) ? .handled : .ignored }
        .onKeyPress(.space) {
            close()
            return .handled
        }
        .onExitCommand { close() }
        .task(id: request.itemID) { await load(request.itemID) }
        .onDisappear { stopVideo() }
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
                // Esc closes wherever the keyboard focus is.
                .keyboardShortcut(.cancelAction)
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
            zoomButton("minus.magnifyingglass", label: String(localized: "Zoom out"), enabled: zoom > 1) { setZoom(zoom / 2) }
                .keyboardShortcut("-", modifiers: .command)
            zoomButton("plus.magnifyingglass", label: String(localized: "Zoom in"), enabled: zoom < Self.maximumZoom) { setZoom(zoom * 2) }
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

    private static let maximumZoom: CGFloat = 4

    private func setZoom(_ value: CGFloat) {
        let clamped = min(max(value, 1), Self.maximumZoom)
        if reduceMotion {
            zoom = clamped
        } else {
            withAnimation(Motion.snap) { zoom = clamped }
        }
    }

    /// The right-hand column: where and when, who, and the words written for this photo.
    private var infoPanel: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dateTitle)
                            .font(.system(size: 20, weight: .medium, design: .serif))
                            .foregroundStyle(LibraryPalette.ink)
                        if let time = timeTitle {
                            Text(time)
                                .font(.callout)
                                .foregroundStyle(LibraryPalette.muted)
                        }
                    }

                    infoRow(String(localized: "Place")) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            PhotoPlaceLine(item: item, placeNotes: placeNotes)
                            Spacer(minLength: 0)
                            PhotoNoteBadge(item: item)
                        }
                    }
                    if let trip = item.trip?.effectiveName, !trip.isEmpty {
                        infoRow(String(localized: "Trip")) {
                            Text(trip).foregroundStyle(LibraryPalette.ink)
                        }
                    }
                    if !peopleNames.isEmpty {
                        infoRow(String(localized: "People")) {
                            Text(peopleNames.joined(separator: ", ")).foregroundStyle(LibraryPalette.ink)
                        }
                    }
                    if libraryState.memoryDrafts[item.id] != nil
                        || item.latestMemory?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        infoRow(String(localized: "Memory")) {
                            MemoryEditor(item: item, state: libraryState)
                        }
                    }
                    infoRow(String(localized: "Note")) {
                        PhotoNoteSection(item: item, state: libraryState)
                    }
                }
                .padding(20)
            }
        }
    }

    private func infoRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(LibraryPalette.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var media: some View {
        if let player {
            VideoPlayerView(player: player)
                .accessibilityIdentifier("viewer.video")
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(28)
        } else if let image {
            GeometryReader { geometry in
                let fitted = Self.fittedSize(image.size, in: CGSize(width: geometry.size.width - 56, height: geometry.size.height - 56))
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width * zoom, height: fitted.height * zoom)
                        .shadow(color: Paper.shadow.opacity(0.12), radius: 10, y: 4)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                        // Double click toggles between fitted and twice the size, like Photos.
                        .onTapGesture(count: 2) { setZoom(zoom > 1 ? 1 : 2) }
                        .accessibilityLabel(title)
                        .accessibilityIdentifier("viewer.image")
                }
                .scrollIndicators(zoom > 1 ? .automatic : .hidden)
                .scrollDisabled(zoom <= 1)
            }
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

    private var dateTitle: String {
        guard let date = item?.effectiveCaptureDate else { return item?.title ?? String(localized: "Undated") }
        return date.formatted(date: .long, time: .omitted)
    }

    private var timeTitle: String? {
        item?.effectiveCaptureDate?.formatted(date: .omitted, time: .shortened)
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
        zoom = 1
        peopleNames = names(of: id)
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

    /// Named, visible people found in this photo.
    private func names(of mediaID: String) -> [String] {
        let faces = (try? modelContext.fetch(FetchDescriptor<FaceObservation>(predicate: #Predicate { $0.mediaID == mediaID }))) ?? []
        let personIDs = Set(faces.compactMap(\.personID))
        guard !personIDs.isEmpty else { return [] }
        let people = (try? modelContext.fetch(FetchDescriptor<Person>())) ?? []
        return people
            .filter { personIDs.contains($0.id) && !$0.hidden }
            .compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
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
