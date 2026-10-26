import AppKit
import AVKit
import Photos
import SwiftData
import SwiftUI

/// The large view of one photo, opened by a double click, Space or Return.
/// It covers the screen it was opened from, like Photos: the arrow keys page
/// through the photos that screen showed, Esc or Space goes back.
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
    @FocusState private var isFocused: Bool

    private var index: Int? { request.itemIDs.firstIndex(of: request.itemID) }
    private var hasPrevious: Bool { (index ?? 0) > 0 }
    private var hasNext: Bool { (index ?? request.itemIDs.count) < request.itemIDs.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                media
                    .padding(.horizontal, 64)
                    .padding(.vertical, 12)
                pagingButtons
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            if let item {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        PhotoPlaceLine(item: item, placeNotes: placeNotes)
                        Spacer(minLength: 0)
                        PhotoNoteBadge(item: item)
                    }
                    if libraryState.memoryDrafts[item.id] != nil
                        || item.latestMemory?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        MemoryEditor(item: item, state: libraryState)
                    }
                    PhotoNoteSection(item: item, state: libraryState)
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 34)
                .padding(.bottom, 22)
            }
        }
        .background(LibraryPalette.content)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("viewer")
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                close()
            } label: {
                Label(String(localized: "Back"), systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            // Esc goes back wherever the keyboard focus is.
            .keyboardShortcut(.cancelAction)
            .help(String(localized: "Back (Esc)"))
            .accessibilityIdentifier("viewer.close")

            Spacer(minLength: 8)

            VStack(spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(LibraryPalette.ink)
                    .lineLimit(1)
                if let index {
                    Text("\(index + 1) / \(request.itemIDs.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(LibraryPalette.muted)
                        .accessibilityIdentifier("viewer.counter")
                        .accessibilityValue("\(index + 1)")
                }
            }

            Spacer(minLength: 8)

            if let item {
                Button {
                    item.setFavorite(!item.isFavorite, context: modelContext)
                    try? modelContext.save()
                } label: {
                    Image(systemName: item.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(item.isFavorite ? .yellow : LibraryPalette.muted)
                        .symbolEffect(.bounce, value: item.isFavorite)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Favorite"))
                .accessibilityLabel(String(localized: "Favorite"))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var media: some View {
        if let player {
            VideoPlayer(player: player)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .shadow(color: Paper.shadow.opacity(0.12), radius: 10, y: 4)
                .accessibilityLabel(title)
                .accessibilityIdentifier("viewer.image")
        } else {
            ProgressView().controlSize(.small)
        }
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
        if reduceMotion {
            selection.viewerRequest = nil
        } else {
            withAnimation(.easeOut(duration: 0.16)) { selection.viewerRequest = nil }
        }
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
