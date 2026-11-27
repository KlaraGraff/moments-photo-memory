import MapKit
import MomentsCore
import SwiftData
import SwiftUI

/// The mark for a location set by hand: a hollow pin, where the camera's is
/// filled. Used in the sheet, on map pins and in the viewer's info column.
struct ManualLocationPin: View {
    var size: CGFloat = 12
    var color: Color = Paper.accent

    var body: some View {
        // SF Symbols has no hollow map pin; a ring on a short stem reads as one.
        VStack(spacing: 0) {
            Circle()
                .strokeBorder(color, lineWidth: max(1.5, size * 0.16))
                .background(Circle().fill(Color.white))
                .frame(width: size * 0.72, height: size * 0.72)
            Rectangle()
                .fill(color)
                .frame(width: max(1.5, size * 0.12), height: size * 0.34)
        }
        .frame(width: size * 0.72, height: size * 1.06)
        .accessibilityHidden(true)
    }
}

/// Set Location: search a place name or click the map, drag the pin, or use
/// the place of a photo taken the same day. Nothing changes until the main
/// button is pressed.
struct ManualLocationSheet: View {
    @Environment(SelectionModel.self) private var selection
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum SearchState: Equatable {
        case idle
        case loading
        case results([PlaceSearchResult])
        case empty(String)
        case failed
    }

    private enum PinSource: Equatable {
        case search(name: String)
        case borrowed(photoID: String)
        case map
    }

    private struct Pin: Equatable {
        var point: GeoPoint
        var label: String?
        var source: PinSource
    }

    private struct Borrowed: Identifiable {
        let id: String
        let item: MediaItem
        let point: GeoPoint
        let interval: TimeInterval
    }

    @State private var query = ""
    @State private var search: SearchState = .idle
    /// The words the shown results are for, so Return and the pause after
    /// typing do not search the same words twice.
    @State private var searchedWords: String?
    @State private var pin: Pin?
    @State private var camera: MapCameraPosition = .automatic
    /// The selected photos, oldest first, read once when the sheet opens:
    /// `body` runs on every key typed, and the selection may be the whole
    /// library.
    @State private var items: [MediaItem] = []
    @State private var cameraLocatedCount = 0
    @State private var unlocatedTargets: [MediaItem] = []
    @State private var borrowed: [Borrowed] = []
    @State private var loadedSuggestions = false
    @State private var includeCameraLocated = false
    @State private var dragOffset: CGSize?
    @FocusState private var searchFocused: Bool

    private let itemIDs: [String]
    private let searcher: any PlaceSearching = PlaceSearch.current
    private static let mapSpace = "location.map"

    init(itemIDs: [String]) {
        self.itemIDs = itemIDs
    }

    private var unlocatedCount: Int { items.count - cameraLocatedCount }
    /// Some photos have the camera's location and some have none: the sheet
    /// asks which to change.
    private var isMixed: Bool { cameraLocatedCount > 0 && unlocatedCount > 0 }

    private var targets: [MediaItem] {
        includeCameraLocated || !isMixed ? items : unlocatedTargets
    }

    private func loadItems() {
        items = ManualLocationEditing.items(withIDs: itemIDs, context: modelContext)
            .filter { $0.deletedAt == nil }
            .sorted { lhs, rhs in
                let left = lhs.effectiveCaptureDate ?? .distantFuture
                let right = rhs.effectiveCaptureDate ?? .distantFuture
                if left != right { return left < right }
                return lhs.id < rhs.id
            }
        let located = Set(items.filter { $0.cameraLocation != nil }.map(\.id))
        cameraLocatedCount = located.count
        let ids = Set(ManualLocation.targets(
            items.map { ManualLocation.Target(id: $0.id, hasCameraLocation: located.contains($0.id)) },
            includingCameraLocated: false
        ))
        unlocatedTargets = items.filter { ids.contains($0.id) }
    }

    private var title: String {
        items.count > 1
            ? String(localized: "Set Location of \(items.count) Photos")
            : String(localized: "Set Location")
    }

    private var confirmTitle: String {
        targets.count > 1
            ? String(localized: "Set Location of \(targets.count) Photos")
            : String(localized: "Set Location")
    }

    var body: some View {
        PaperSheet(title, subtitle: String(localized: "Search for a place, or click the map. You can drag the pin.")) {
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        photoStrip
                        searchSection
                        suggestionSection
                        if isMixed { scopeSection }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                .frame(width: 240)
                map
                    .frame(minWidth: 320, maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Paper.rule, lineWidth: 1))
            }
        } footer: {
            Button(String(localized: "Cancel")) { close() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("location.cancel")
            Button(confirmTitle) { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(pin == nil || targets.isEmpty)
                .accessibilityIdentifier("location.done")
        }
        .frame(minWidth: 624, idealWidth: 720, maxWidth: 960, minHeight: 440, idealHeight: 500, maxHeight: 720)
        .background(Paper.raised)
        .onAppear(perform: start)
        .task(id: query) { await searchAfterPause() }
    }

    // MARK: Left column

    private var photoStrip: some View {
        let shown = Array(items.prefix(5))
        return HStack(spacing: 6) {
            ForEach(shown, id: \.id) { item in
                ThumbnailView(item: item, width: 80, height: 80)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if items.count > shown.count {
                Text(verbatim: "+\(items.count - shown.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Paper.muted)
                    .frame(width: 40, height: 40)
                    .background(Paper.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("location.photos")
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $query, prompt: Text(String(localized: "Search for a place or address")))
                .textFieldStyle(.paper)
                .focused($searchFocused)
                .onSubmit { Task { await runSearch(query) } }
                .accessibilityIdentifier("location.search")
            switch search {
            case .idle:
                EmptyView()
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Searching…"))
                }
                .font(.caption)
                .foregroundStyle(Paper.muted)
            case .results(let results):
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        resultRow(result)
                            .accessibilityIdentifier("location.result.\(index)")
                    }
                }
            case .empty(let words):
                note(String(localized: "Nothing found for “\(words)”. Try other words, or click the map."))
            case .failed:
                note(String(localized: "Place search isn’t available right now. You can still click the map."))
            }
        }
    }

    private func resultRow(_ result: PlaceSearchResult) -> some View {
        let isChosen = pin?.source == .search(name: result.name) && pin?.point == result.point
        return Button {
            drop(result.point, label: result.name, source: .search(name: result.name), zoom: true)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .foregroundStyle(Paper.ink)
                    .lineLimit(1)
                if !result.detail.isEmpty {
                    Text(result.detail)
                        .font(.caption)
                        .foregroundStyle(Paper.muted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isChosen ? Paper.well : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var suggestionSection: some View {
        if loadedSuggestions {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Same place as a photo from that day"))
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Paper.muted)
                if borrowed.isEmpty {
                    note(String(localized: "No photo from that day has a location."))
                } else {
                    ForEach(Array(borrowed.enumerated()), id: \.element.id) { index, suggestion in
                        suggestionRow(suggestion)
                            .accessibilityIdentifier("location.suggestion.\(index)")
                    }
                }
            }
        }
    }

    private func suggestionRow(_ suggestion: Borrowed) -> some View {
        HStack(spacing: 8) {
            ThumbnailView(item: suggestion.item, width: 64, height: 64)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.intervalText(suggestion.interval))
                    .font(.callout)
                    .foregroundStyle(Paper.ink)
                if let name = suggestion.item.namedPlace {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(Paper.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button(String(localized: "Use This Place")) {
                let time = suggestion.item.effectiveCaptureDate.map { PhotoDateEditor.timeText($0, in: suggestion.item.captureTimeZone) } ?? ""
                drop(
                    suggestion.point,
                    label: String(localized: "From the photo taken at \(time)"),
                    source: .borrowed(photoID: suggestion.id),
                    zoom: true
                )
            }
            .controlSize(.small)
        }
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $includeCameraLocated) {
                Text(String(localized: "Only the \(unlocatedCount) without a location")).tag(false)
                Text(String(localized: "All \(items.count), including \(cameraLocatedCount) with a camera location")).tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityIdentifier("location.scope")
            if includeCameraLocated {
                note(String(localized: "The camera’s location is kept and can be restored."))
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Paper.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let pin {
                    Annotation(pin.label ?? "", coordinate: pin.point.coordinate, anchor: .bottom) {
                        pinMark(proxy: proxy)
                    }
                }
            }
            .mapControls { MapZoomStepper() }
            .coordinateSpace(.named(Self.mapSpace))
            .onTapGesture(coordinateSpace: .named(Self.mapSpace)) { location in
                guard let coordinate = proxy.convert(location, from: .named(Self.mapSpace)) else { return }
                drop(GeoPoint(coordinate), label: nil, source: .map, zoom: false)
            }
            .overlay(alignment: .top) {
                if pin == nil {
                    Text(String(localized: "Click the map to drop a pin"))
                        .font(.caption)
                        .foregroundStyle(Paper.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Paper.raised.opacity(0.94), in: Capsule())
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityIdentifier("location.map")
    }

    private func pinMark(proxy: MapProxy) -> some View {
        ManualLocationPin(size: 30)
            .shadow(color: Paper.shadow.opacity(0.3), radius: 3, y: 1)
            .scaleEffect(dragOffset == nil ? 1 : 1.12, anchor: .bottom)
            .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: dragOffset == nil)
            .contentShape(Rectangle())
            // A click on the pin itself leaves it where it is.
            .onTapGesture {}
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.mapSpace))
                    .onChanged { value in
                        guard let current = pin else { return }
                        // Keep the pin's tip where it was relative to the
                        // pointer, so it does not jump to the pointer.
                        let offset: CGSize
                        if let dragOffset {
                            offset = dragOffset
                        } else {
                            let tip: CGPoint = proxy.convert(current.point.coordinate, to: .named(Self.mapSpace)) ?? value.startLocation
                            offset = CGSize(width: tip.x - value.startLocation.x, height: tip.y - value.startLocation.y)
                            dragOffset = offset
                        }
                        let target = CGPoint(x: value.location.x + offset.width, y: value.location.y + offset.height)
                        if let coordinate = proxy.convert(target, from: .named(Self.mapSpace)) {
                            pin = Pin(point: GeoPoint(coordinate), label: current.source == .map ? current.label : nil, source: .map)
                        }
                    }
                    .onEnded { _ in dragOffset = nil }
            )
            .help(String(localized: "Search for a place, or click the map. You can drag the pin."))
            .accessibilityElement()
            .accessibilityLabel(pin?.label ?? String(localized: "Set Location"))
            .accessibilityIdentifier("location.pin")
    }

    // MARK: Actions

    private func start() {
        loadItems()
        searchFocused = true
        // A photo already placed by hand opens at its place.
        if let existing = items.lazy.compactMap({ $0.manualLocation?.point }).first {
            pin = Pin(point: existing, label: items.first?.namedPlace, source: .map)
            camera = .region(Self.region(around: existing))
        } else if items.count == 1, let point = items.first?.cameraLocation {
            camera = .region(Self.region(around: point))
        }
        loadSuggestions()
    }

    private func loadSuggestions() {
        let days = Array(Set(items.compactMap(\.localDayKey))).prefix(31)
        var candidates: [MediaItem] = []
        for day in days {
            let key: String? = day
            let descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.localDayKey == key && $0.latitude != nil })
            candidates += ((try? modelContext.fetch(descriptor)) ?? []).filter { $0.deletedAt == nil }
        }
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let suggestions = ManualLocation.sameDaySuggestions(
            for: items.map(Self.dayPhoto(_:)),
            among: candidates.map(Self.dayPhoto(_:))
        )
        borrowed = suggestions.compactMap { suggestion in
            byID[suggestion.photoID].map { Borrowed(id: suggestion.photoID, item: $0, point: suggestion.point, interval: suggestion.interval) }
        }
        loadedSuggestions = !items.isEmpty
        if pin == nil, items.allSatisfy({ $0.cameraLocation == nil }), let first = borrowed.first {
            camera = .region(Self.region(around: first.point, span: 0.2))
        }
    }

    private static func dayPhoto(_ item: MediaItem) -> ManualLocation.DayPhoto {
        ManualLocation.DayPhoto(id: item.id, date: item.effectiveCaptureDate, dayKey: item.localDayKey, cameraPoint: item.cameraLocation)
    }

    private func drop(_ point: GeoPoint, label: String?, source: PinSource, zoom: Bool) {
        pin = Pin(point: point, label: label, source: source)
        if zoom {
            let region = Self.region(around: point)
            if reduceMotion {
                camera = .region(region)
            } else {
                withAnimation(Motion.snap) { camera = .region(region) }
            }
        }
    }

    private func searchAfterPause() async {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            search = .idle
            searchedWords = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled, words != searchedWords else { return }
        await runSearch(words)
    }

    private func runSearch(_ text: String) async {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words != searchedWords else { return }
        searchedWords = words
        search = .loading
        do {
            // Only the words go to Apple's search, not where the map is.
            let results = try await searcher.search(words)
            // A newer search (more typing) owns the list now.
            guard words == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            search = results.isEmpty ? .empty(words) : .results(results)
        } catch is CancellationError {
            if searchedWords == words { searchedWords = nil }
            return
        } catch {
            guard words == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            // Return tries the same words again.
            searchedWords = nil
            // MapKit says "no results" with an error.
            if let mapError = error as? MKError, mapError.code == .placemarkNotFound {
                search = .empty(words)
            } else {
                search = .failed
            }
        }
    }

    private func apply() {
        guard let pin else { return }
        let name: String?
        if case .search(let searched) = pin.source { name = searched } else { name = nil }
        if let undo = ManualLocationEditing.setLocation(pin.point, name: name, on: targets, context: modelContext) {
            selection.recordCorrection(undo, context: modelContext)
        }
        close()
    }

    private func close() {
        selection.locationItemIDs = nil
    }

    // MARK: Formatting

    static func region(around point: GeoPoint, span: Double = 0.02) -> MKCoordinateRegion {
        MKCoordinateRegion(center: point.coordinate, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
    }

    private static let intervalFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    /// "12 min earlier", "1 hr 5 min later".
    static func intervalText(_ interval: TimeInterval) -> String {
        let amount = intervalFormatter.string(from: max(60, abs(interval))) ?? ""
        return interval < 0
            ? String(localized: "\(amount) earlier")
            : String(localized: "\(amount) later")
    }
}
