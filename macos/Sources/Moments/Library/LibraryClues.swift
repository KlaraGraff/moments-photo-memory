import SwiftData
import SwiftUI

// People and places are not pages. They show on the photos and the chapters,
// and each one is a way in: a face opens that person's photos, a place name
// the photos taken there, a small map the large map of the photos it stands
// for. This file holds those shared pieces.

// MARK: - People

/// One person, or one unnamed group of faces, in the Library's row of faces.
struct PeopleStripEntry: Identifiable {
    /// "person.<id>" or "cluster.<id>".
    let id: String
    let personID: String?
    let clusterID: String?
    /// `nil` for a group nobody has named yet.
    let name: String?
    let cover: FaceObservation?
    let mediaIDs: Set<String>

    var photoCount: Int { mediaIDs.count }
}

@MainActor
enum PeopleStrip {
    /// An unnamed group shows once it is in this many photos.
    static let minimumUnnamedPhotos = 5

    /// Everyone: named people first, most photos first; then every unnamed
    /// group big enough to ask about, largest first. There is no cap, so the
    /// row never hides people; it scrolls instead (`LibraryPeopleStrip`).
    /// Faces in screenshots and in Recently Deleted photos do not count.
    static func entries(
        faces: [FaceObservation],
        people: [Person],
        itemsByID: [String: MediaItem],
        decisions: any DecisionStore = LibraryDecisions.shared
    ) -> [PeopleStripEntry] {
        var names: [String: String] = [:]
        for person in people where !person.hidden {
            let name: String = person.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty { names[person.id] = name }
        }
        // A face is a SwiftData model, so each property is read once.
        var byPerson: [String: [FaceObservation]] = [:]
        var byCluster: [String: [FaceObservation]] = [:]
        var photos: [String: Set<String>] = [:]
        for face in faces {
            let mediaID: String = face.mediaID
            guard let item = itemsByID[mediaID], !item.isScreenshot else { continue }
            if let personID = face.personID {
                guard names[personID] != nil else { continue }
                byPerson[personID, default: []].append(face)
                photos["person." + personID, default: []].insert(mediaID)
            } else if let clusterID = face.clusterID, !clusterID.hasPrefix("loose-") {
                byCluster[clusterID, default: []].append(face)
                photos["cluster." + clusterID, default: []].insert(mediaID)
            }
        }
        var named: [PeopleStripEntry] = []
        for (personID, group) in byPerson {
            let mediaIDs: Set<String> = photos["person." + personID] ?? []
            let cover: FaceObservation? = PeopleFacePicker.cover(group, keyFaceID: PeopleStoreActions.keyFaceID(for: personID, defaults: decisions))
            named.append(PeopleStripEntry(
                id: "person." + personID,
                personID: personID,
                clusterID: nil,
                name: names[personID],
                cover: cover,
                mediaIDs: mediaIDs
            ))
        }
        named.sort { (left: PeopleStripEntry, right: PeopleStripEntry) -> Bool in
            if left.photoCount != right.photoCount { return left.photoCount > right.photoCount }
            return (left.name ?? "").localizedStandardCompare(right.name ?? "") == .orderedAscending
        }
        var unnamed: [PeopleStripEntry] = []
        for (clusterID, group) in byCluster {
            guard group.count >= PeopleStoreActions.minimumCardFaces else { continue }
            let mediaIDs: Set<String> = photos["cluster." + clusterID] ?? []
            guard mediaIDs.count >= minimumUnnamedPhotos else { continue }
            unnamed.append(PeopleStripEntry(
                id: "cluster." + clusterID,
                personID: nil,
                clusterID: clusterID,
                name: nil,
                cover: PeopleFacePicker.cover(group),
                mediaIDs: mediaIDs
            ))
        }
        unnamed.sort { (left: PeopleStripEntry, right: PeopleStripEntry) -> Bool in
            if left.photoCount != right.photoCount { return left.photoCount > right.photoCount }
            return left.id < right.id
        }
        return named + unnamed
    }

    /// The named people in a set of photos, most photos first, for the small
    /// faces on a chapter.
    static func people(
        in mediaIDs: Set<String>,
        faces: [FaceObservation],
        people: [Person],
        limit: Int,
        decisions: any DecisionStore = LibraryDecisions.shared
    ) -> [PeopleStripEntry] {
        var names: [String: String] = [:]
        for person in people where !person.hidden {
            let name: String = person.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty { names[person.id] = name }
        }
        var byPerson: [String: [FaceObservation]] = [:]
        // All of a person's faces: the face that stands for them is the same everywhere.
        var everywhere: [String: [FaceObservation]] = [:]
        for face in faces {
            guard let personID = face.personID, names[personID] != nil else { continue }
            everywhere[personID, default: []].append(face)
            guard mediaIDs.contains(face.mediaID) else { continue }
            byPerson[personID, default: []].append(face)
        }
        var result: [PeopleStripEntry] = []
        for (personID, group) in byPerson {
            let ids: Set<String> = Set(group.map { (face: FaceObservation) -> String in face.mediaID })
            result.append(PeopleStripEntry(
                id: "person." + personID,
                personID: personID,
                clusterID: nil,
                name: names[personID],
                cover: PeopleFacePicker.cover(everywhere[personID] ?? group, keyFaceID: PeopleStoreActions.keyFaceID(for: personID, defaults: decisions)),
                mediaIDs: ids
            ))
        }
        result.sort { (left: PeopleStripEntry, right: PeopleStripEntry) -> Bool in
            if left.photoCount != right.photoCount { return left.photoCount > right.photoCount }
            return left.id < right.id
        }
        return Array(result.prefix(limit))
    }
}

extension PeopleStrip {
    /// Who was there, for each set of photos (a chapter's, by its id): the
    /// named people first, then the unnamed groups the row of faces asks
    /// about, most photos in the set first, at most `limit` each. Faces in
    /// screenshots, in photos that are gone, of hidden people, of people
    /// without a name and of groups too small to ask about do not count.
    static func companions(
        in sets: [String: Set<String>],
        faces: [FaceObservation],
        people: [Person],
        itemsByID: [String: MediaItem],
        limit: Int,
        decisions: any DecisionStore = LibraryDecisions.shared
    ) -> [String: [PeopleStripEntry]] {
        guard !sets.isEmpty, limit > 0 else { return [:] }
        var names: [String: String] = [:]
        for person in people where !person.hidden {
            let name: String = person.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty { names[person.id] = name }
        }
        // Which sets each photo is in.
        var owners: [String: [String]] = [:]
        for (setID, ids) in sets {
            for id in ids { owners[id, default: []].append(setID) }
        }
        // The groups the row of faces asks about, counted over every photo.
        var clusterFaces: [String: Int] = [:]
        var clusterPhotos: [String: Set<String>] = [:]
        // Each set's faces, by "person.<id>" or "cluster.<id>".
        var perSet: [String: [String: [FaceObservation]]] = [:]
        // Every photo's faces by the same key: a person shows the same face
        // on every chapter as in the row of faces, not the best one of that
        // chapter, which looked like somebody else.
        var everywhere: [String: [FaceObservation]] = [:]
        for face in faces {
            let mediaID: String = face.mediaID
            guard let item = itemsByID[mediaID], !item.isScreenshot else { continue }
            let key: String
            if let personID = face.personID {
                guard names[personID] != nil else { continue }
                key = "person." + personID
            } else if let clusterID = face.clusterID, !clusterID.hasPrefix("loose-") {
                key = "cluster." + clusterID
                clusterFaces[clusterID, default: 0] += 1
                clusterPhotos[clusterID, default: []].insert(mediaID)
            } else {
                continue
            }
            everywhere[key, default: []].append(face)
            guard let setIDs = owners[mediaID] else { continue }
            for setID in setIDs { perSet[setID, default: [:]][key, default: []].append(face) }
        }
        var askedIDs: Set<String> = []
        for (clusterID, photos) in clusterPhotos {
            guard (clusterFaces[clusterID] ?? 0) >= PeopleStoreActions.minimumCardFaces,
                  photos.count >= minimumUnnamedPhotos else { continue }
            askedIDs.insert(clusterID)
        }

        var result: [String: [PeopleStripEntry]] = [:]
        for (setID, groups) in perSet {
            var named: [PeopleStripEntry] = []
            var unnamed: [PeopleStripEntry] = []
            for (key, group) in groups {
                let mediaIDs: Set<String> = Set(group.map { (face: FaceObservation) -> String in face.mediaID })
                if key.hasPrefix("person.") {
                    let personID = String(key.dropFirst("person.".count))
                    named.append(PeopleStripEntry(
                        id: key,
                        personID: personID,
                        clusterID: nil,
                        name: names[personID],
                        cover: PeopleFacePicker.cover(everywhere[key] ?? group, keyFaceID: PeopleStoreActions.keyFaceID(for: personID, defaults: decisions)),
                        mediaIDs: mediaIDs
                    ))
                } else {
                    let clusterID = String(key.dropFirst("cluster.".count))
                    guard askedIDs.contains(clusterID) else { continue }
                    unnamed.append(PeopleStripEntry(
                        id: key,
                        personID: nil,
                        clusterID: clusterID,
                        name: nil,
                        cover: PeopleFacePicker.cover(everywhere[key] ?? group),
                        mediaIDs: mediaIDs
                    ))
                }
            }
            let byCount = { (left: PeopleStripEntry, right: PeopleStripEntry) -> Bool in
                if left.photoCount != right.photoCount { return left.photoCount > right.photoCount }
                return left.id < right.id
            }
            named.sort(by: byCount)
            unnamed.sort(by: byCount)
            let entries: [PeopleStripEntry] = Array((named + unnamed).prefix(limit))
            if !entries.isEmpty { result[setID] = entries }
        }
        return result
    }
}

@MainActor
enum PersonClue {
    /// The Library, showing every photo of this person or unnamed group.
    static func showPhotos(of entry: PeopleStripEntry, store: LibraryStore, selection: SelectionModel) {
        if let personID = entry.personID {
            showPhotos(ofPerson: personID, name: entry.name, store: store, selection: selection)
        } else if let clusterID = entry.clusterID {
            var ids = Set<String>()
            for face in store.faces where face.personID == nil && face.clusterID == clusterID {
                guard let item = store.itemsByID[face.mediaID], !item.isScreenshot else { continue }
                ids.insert(face.mediaID)
            }
            selection.showInLibrary(ids, title: String(localized: "Who is this?"), clusterID: clusterID)
        }
    }

    /// The Library, showing only this person's photos. `replacing` when
    /// they are already showing under another name (see `showInLibrary`).
    static func showPhotos(ofPerson personID: String, name: String?, store: LibraryStore, selection: SelectionModel, replacing: Bool = false) {
        var ids = Set<String>()
        for face in store.faces where face.personID == personID {
            guard let item = store.itemsByID[face.mediaID], !item.isScreenshot else { continue }
            ids.insert(face.mediaID)
        }
        selection.showInLibrary(ids, title: name ?? String(localized: "Who is this?"), personID: personID, replacing: replacing)
    }
}

/// A round face, or a plain disc while a group has no usable crop.
struct PersonFace: View {
    let face: FaceObservation?
    let size: CGFloat

    var body: some View {
        if let face {
            FaceCropView(data: face.cropData, cacheKey: face.id, size: size)
        } else {
            Circle()
                .fill(Paper.well)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(Paper.muted)
                }
        }
    }
}

/// Works out the library's people once per change to faces or names, for
/// the row of faces and the small faces on section titles. It draws nothing.
struct LibraryPeopleIndexer: View {
    let state: LibraryViewState
    @Environment(LibraryStore.self) private var store
    @Query(sort: \Person.name) private var people: [Person]

    private var key: Int {
        var hasher = Hasher()
        hasher.combine(store.photoFaceRevision)
        hasher.combine(store.refreshCount)
        hasher.combine(store.keyFaceRevision)
        for person in people {
            hasher.combine(person.id)
            hasher.combine(person.name)
            hasher.combine(person.hidden)
        }
        return hasher.finalize()
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: key) {
                state.peopleEntries = PeopleStrip.entries(faces: store.faces, people: people, itemsByID: store.itemsByID)
            }
    }
}

/// The people of the library as a row of faces over the photos. A click shows
/// that person's photos right here in the Library; a group nobody has named
/// yet shows as "?" and asks who it is.
///
/// Everyone is in the row, however many: it stays one line and scrolls
/// sideways. When more faces are off to a side, that edge fades out and a
/// round arrow button pages along, so it never looks like these are all the
/// people (a mouse wheel does not scroll a row sideways).
struct LibraryPeopleStrip: View {
    let entries: [PeopleStripEntry]
    @Environment(SelectionModel.self) private var selection
    /// The row's own frame in the strip's visible area: `minX` is 0 at the
    /// start and negative once scrolled.
    @State private var rowFrame: CGRect = .zero
    @State private var visibleWidth: CGFloat = 0

    private static let space = "library.people.viewport"
    /// The row itself, padding included: paging back to the first face
    /// scrolls here, so the row comes all the way back to its start.
    private static let startID = "library.people.start"
    private static let itemWidth: CGFloat = 64
    private static let spacing: CGFloat = 16
    private static let faceSize: CGFloat = 48
    private static let fadeWidth: CGFloat = 36

    private var step: CGFloat { Self.itemWidth + Self.spacing }
    private var hasEarlier: Bool { rowFrame.minX < -1 }
    private var hasLater: Bool { rowFrame.maxX > visibleWidth + 1 }
    /// The first unnamed group after the named people, which a hairline
    /// sets apart; `nil` when the row is all one kind.
    private var firstUnnamedID: String? {
        guard let index = entries.firstIndex(where: { (entry: PeopleStripEntry) -> Bool in entry.personID == nil }), index > 0 else { return nil }
        return entries[index].id
    }

    var body: some View {
        if !entries.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Self.spacing) {
                        ForEach(entries) { (entry: PeopleStripEntry) in
                            if entry.id == firstUnnamedID {
                                // A hairline between the people with a name
                                // and the groups that still ask for one.
                                Rectangle()
                                    .fill(Paper.rule)
                                    .frame(width: 1, height: Self.faceSize - 12)
                                    .padding(.top, 6)
                                    .accessibilityHidden(true)
                            }
                            Button { open(entry) } label: { label(entry) }
                                .buttonStyle(.plain)
                                .help(entry.name.map { String(localized: "Show photos of \($0)") } ?? String(localized: "Who is this?"))
                                .accessibilityLabel(entry.name ?? String(localized: "Who is this?"))
                                .accessibilityIdentifier("library.person." + (entry.name ?? "unnamed"))
                                .id(entry.id)
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 2)
                    .id(Self.startID)
                    .onGeometryChange(for: CGRect.self, of: { (geometry: GeometryProxy) -> CGRect in geometry.frame(in: .named(Self.space)) }) { (frame: CGRect) in
                        rowFrame = frame
                    }
                }
                .scrollIndicators(.never)
                .coordinateSpace(.named(Self.space))
                .onGeometryChange(for: CGFloat.self, of: { (geometry: GeometryProxy) -> CGFloat in geometry.size.width }) { (width: CGFloat) in
                    visibleWidth = width
                }
                .mask { edgeFade }
                .overlay(alignment: .topLeading) {
                    if hasEarlier {
                        pageButton(forward: false) { page(forward: false, proxy: proxy) }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if hasLater {
                        pageButton(forward: true) { page(forward: true, proxy: proxy) }
                    }
                }
                .animation(.easeOut(duration: 0.15), value: hasEarlier)
                .animation(.easeOut(duration: 0.15), value: hasLater)
            }
            .padding(.bottom, 22)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.people")
        }
    }

    /// Opaque in the middle; each edge fades out while more faces are past it.
    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [Color.black.opacity(hasEarlier ? 0 : 1), Color.black], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.fadeWidth)
            Color.black
            LinearGradient(colors: [Color.black, Color.black.opacity(hasLater ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.fadeWidth)
        }
    }

    private func pageButton(forward: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Paper.ink)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Paper.raised))
                .overlay(Circle().stroke(Paper.line, lineWidth: 1))
                .shadow(color: Paper.shadow.opacity(0.18), radius: 3, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Level with the middle of the faces.
        .padding(.top, 2 + (Self.faceSize - 28) / 2)
        .help(forward ? String(localized: "More people") : String(localized: "Earlier people"))
        .accessibilityLabel(forward ? String(localized: "More people") : String(localized: "Earlier people"))
        .accessibilityIdentifier(forward ? "library.people.more" : "library.people.earlier")
        .transition(.opacity)
    }

    /// Moves the row by about one width of faces, keeping one face of the
    /// last view in sight so the eye can follow.
    private func page(forward: Bool, proxy: ScrollViewProxy) {
        let perPage: Int = max(1, Int((visibleWidth / step).rounded(.down)) - 1)
        let first: Int = max(0, Int((-rowFrame.minX / step).rounded()))
        let target: Int = forward
            ? min(entries.count - 1, first + perPage)
            : max(0, first - perPage)
        guard entries.indices.contains(target) else { return }
        let id: String = target == 0 ? Self.startID : entries[target].id
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(id, anchor: .leading)
        }
    }

    private func label(_ entry: PeopleStripEntry) -> some View {
        VStack(spacing: 4) {
            PersonFace(face: entry.cover, size: Self.faceSize)
            Text(verbatim: entry.name ?? "?")
                .font(.caption)
                .foregroundStyle(entry.name == nil ? LibraryPalette.muted : LibraryPalette.ink)
                .lineLimit(1)
            Text(verbatim: "\(entry.photoCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(LibraryPalette.muted)
        }
        .frame(width: Self.itemWidth)
        .contentShape(Rectangle())
    }

    private func open(_ entry: PeopleStripEntry) {
        selection.showInLibrary(
            entry.mediaIDs,
            title: entry.name ?? String(localized: "Who is this?"),
            personID: entry.personID,
            clusterID: entry.clusterID
        )
    }
}

/// The row over the photos while the Library shows only some of them: whose
/// or where they are, how many, a small map of them, and the way back to
/// every photo. A person's or a place's name is typed right here. A name
/// another place already has joins the two places; a name another person
/// already has asks first, since two people can share a name.
struct LibraryScopeHeading: View {
    let scope: LibraryScope
    let photoCount: Int
    @Environment(SelectionModel.self) private var selection
    @Environment(LibraryStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Person.name) private var people: [Person]
    @State private var nameText = ""
    @State private var stops: [TripRouteStop] = []
    @State private var pendingMerge: PendingMerge?
    @State private var isPickingKeyFace = false
    @FocusState private var isNaming: Bool

    /// A typed name that another person already has, waiting for the answer
    /// to "merge or keep separate?".
    private struct PendingMerge: Equatable {
        let name: String
        let targetID: String
        let targetName: String
    }

    private var isPerson: Bool { scope.personID != nil || scope.clusterID != nil }
    private var isPlace: Bool { scope.placeName != nil }

    /// The faces this heading is about: the person's, or the unnamed group's,
    /// in the same photos the row of faces counts, so the heading shows the
    /// same face for them as the row and the chapters.
    private var faces: [FaceObservation] {
        let itemsByID: [String: MediaItem] = store.itemsByID
        let shown = { (face: FaceObservation) -> Bool in
            guard let item = itemsByID[face.mediaID] else { return false }
            return !item.isScreenshot
        }
        if let personID = scope.personID {
            return store.faces.filter { (face: FaceObservation) -> Bool in face.personID == personID && shown(face) }
        }
        if let clusterID = scope.clusterID {
            return store.faces.filter { (face: FaceObservation) -> Bool in face.personID == nil && face.clusterID == clusterID && shown(face) }
        }
        return []
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if isPerson {
                headingFace
                TextField("", text: $nameText, prompt: Text(String(localized: "Who is this?")))
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .medium, design: .serif))
                    .foregroundStyle(LibraryPalette.ink)
                    .frame(minWidth: 90, idealWidth: 160, maxWidth: 220)
                    .fixedSize(horizontal: true, vertical: false)
                    .focused($isNaming)
                    .onSubmit { commitName() }
                    .onChange(of: isNaming) { _, focused in
                        if !focused { commitName() }
                    }
                    .accessibilityIdentifier("library.scope.name")
            } else if isPlace {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(Paper.accent)
                TextField("", text: $nameText, prompt: Text(scope.title))
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .medium, design: .serif))
                    .foregroundStyle(LibraryPalette.ink)
                    .frame(minWidth: 90, idealWidth: 180, maxWidth: 260)
                    .fixedSize(horizontal: true, vertical: false)
                    .focused($isNaming)
                    .onSubmit { commitPlaceName() }
                    .onChange(of: isNaming) { _, focused in
                        if !focused { commitPlaceName() }
                    }
                    .help(String(localized: "Rename this place for every photo taken here. Return saves."))
                    .accessibilityIdentifier("library.scope.place")
            } else {
                Text(scope.title)
                    .font(.system(size: 19, weight: .medium, design: .serif))
                    .foregroundStyle(LibraryPalette.ink)
                    .lineLimit(1)
                    .accessibilityIdentifier("library.scope.title")
            }
            Text(String(localized: "\(photoCount) photos"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(LibraryPalette.muted)
                .lineLimit(1)
            if scope.clusterID != nil {
                Button(String(localized: "Ignore this group")) { ignore() }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("library.scope.ignore")
            }
            Spacer(minLength: 8)
            if !stops.isEmpty {
                PhotoMiniMap(stops: stops) {
                    selection.showMap(title: scope.title, itemIDs: scope.itemIDs)
                }
                .accessibilityIdentifier("library.scope.map")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, PaperMetrics.screenInset)
        .padding(.top, PaperMetrics.screenTopInset)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.scope")
        .alert(
            String(format: String(localized: "Merge with existing %@?"), pendingMerge?.targetName ?? ""),
            isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }),
            presenting: pendingMerge
        ) { pending in
            Button(String(localized: "Merge")) { resolve(pending, merge: true) }
                .keyboardShortcut(.defaultAction)
            Button(String(localized: "Keep separate")) { resolve(pending, merge: false) }
            Button(String(localized: "Cancel"), role: .cancel) {
                pendingMerge = nil
                resetName()
            }
        }
        .task(id: scope) {
            nameText = scope.personID != nil || scope.placeName != nil ? scope.title : ""
            let items: [MediaItem] = scope.itemIDs.compactMap { (id: String) -> MediaItem? in store.itemsByID[id] }
            stops = MiniMapStops.make(items)
            // A group nobody has named: the cursor waits in the name field.
            if scope.clusterID != nil { isNaming = true }
        }
    }

    /// A named person's face is a button: it opens their faces, and the one
    /// clicked stands for them from then on. An unnamed group has no choice
    /// to keep yet.
    @ViewBuilder
    private var headingFace: some View {
        if let personID = scope.personID {
            Button { isPickingKeyFace = true } label: {
                PersonFace(face: cover, size: 40).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Choose key photo"))
            .accessibilityLabel(String(localized: "Choose key photo"))
            .accessibilityValue(cover?.id ?? "")
            .accessibilityIdentifier("library.scope.face")
            .popover(isPresented: $isPickingKeyFace, arrowEdge: .bottom) {
                KeyFacePicker(faces: faces, current: cover?.id) { (face: FaceObservation) in
                    store.setKeyFace(face.id, for: personID)
                    isPickingKeyFace = false
                }
            }
        } else {
            PersonFace(face: cover, size: 40)
        }
    }

    private var cover: FaceObservation? {
        let group: [FaceObservation] = faces
        if let personID = scope.personID {
            // Read so a new key face redraws the heading.
            _ = store.keyFaceRevision
            return PeopleFacePicker.cover(group, keyFaceID: PeopleStoreActions.keyFaceID(for: personID))
        }
        return PeopleFacePicker.cover(group)
    }

    /// Typing a name: an unnamed group becomes that person; a person takes
    /// the new name. A name another person already has asks whether the two
    /// are the same person before anything is joined.
    private func commitName() {
        let value: String = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        // The question is on screen: the field losing focus to it is not a
        // second answer.
        guard !value.isEmpty, pendingMerge == nil else { return }
        if let personID = scope.personID {
            guard let person = people.first(where: { (person: Person) -> Bool in person.id == personID }),
                  person.name != value else { return }
            if let target = PeopleStoreActions.mergeCandidate(forName: value, people: people, excluding: personID) {
                pendingMerge = PendingMerge(name: value, targetID: target.id, targetName: target.name ?? value)
                return
            }
            rename(person, to: value, keepSeparate: false)
        } else if scope.clusterID != nil {
            if let target = PeopleStoreActions.mergeCandidate(forName: value, people: people) {
                pendingMerge = PendingMerge(name: value, targetID: target.id, targetName: target.name ?? value)
                return
            }
            nameGroup(as: value, mergingInto: nil, keepSeparate: false)
        }
    }

    /// The answer to "Merge with existing …?".
    private func resolve(_ pending: PendingMerge, merge: Bool) {
        pendingMerge = nil
        let target: Person? = merge
            ? people.first(where: { (person: Person) -> Bool in person.id == pending.targetID && !person.hidden })
            : nil
        // The other person went away while the question was up.
        guard !merge || target != nil else {
            resetName()
            return
        }
        if let personID = scope.personID {
            guard let person = people.first(where: { (person: Person) -> Bool in person.id == personID }) else { return }
            if let target {
                let shownName: String = target.name ?? pending.name
                PeopleStoreActions.merge(sourceID: personID, into: target.id, people: people, observations: store.faces, context: modelContext)
                modelContext.saveOrReport()
                // Both people's photos, now one person's.
                PersonClue.showPhotos(ofPerson: target.id, name: shownName, store: store, selection: selection, replacing: true)
            } else {
                rename(person, to: pending.name, keepSeparate: true)
            }
        } else if scope.clusterID != nil {
            nameGroup(as: pending.name, mergingInto: target, keepSeparate: !merge)
        }
    }

    private func rename(_ person: Person, to value: String, keepSeparate: Bool) {
        person.name = value
        person.updatedAt = .now
        // Otherwise a later naming would offer to fold the two together again.
        if keepSeparate { PeopleStoreActions.setKeepSeparate(person.id, true) }
        modelContext.saveOrReport()
        selection.libraryScope = LibraryScope(title: value, itemIDs: scope.itemIDs, personID: person.id)
    }

    private func nameGroup(as value: String, mergingInto target: Person?, keepSeparate: Bool) {
        guard let clusterID = scope.clusterID else { return }
        let group: [FaceObservation] = faces
        // A scan regrouped these faces meanwhile: nothing here to name.
        guard !group.isEmpty else {
            resetName()
            return
        }
        let shownID: String? = PeopleStoreActions.name(
            faces: group,
            as: value,
            mergingInto: target,
            keepSeparate: keepSeparate,
            people: people,
            observations: store.faces,
            context: modelContext
        )
        modelContext.saveOrReport()
        if let target, let shownID {
            // Joined someone: their photos and these, together.
            PersonClue.showPhotos(ofPerson: shownID, name: target.name ?? value, store: store, selection: selection, replacing: true)
        } else {
            selection.libraryScope = LibraryScope(
                title: value,
                itemIDs: scope.itemIDs,
                personID: shownID,
                clusterID: shownID == nil ? clusterID : nil
            )
        }
    }

    /// Back to the name the heading had before typing.
    private func resetName() {
        nameText = scope.personID != nil ? scope.title : ""
    }

    /// Typing over a place's name renames the place for every photo taken
    /// there. A name another place already has joins the two places.
    private func commitPlaceName() {
        // The scope as it is now: losing focus right after Return calls this
        // a second time, and the heading may not have been redrawn yet.
        guard let before: LibraryScope = self.selection.libraryScope, let oldName = before.placeName else { return }
        let value: String = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != oldName else {
            nameText = oldName
            return
        }
        let changes: PlaceNames.Changes = PlaceNames.rename(
            key: PlaceNames.key(oldName),
            to: value,
            items: store.regularItems,
            context: modelContext
        )
        guard !changes.isEmpty else {
            nameText = oldName
            return
        }
        modelContext.saveOrReport()
        let selection: SelectionModel = self.selection
        let store: LibraryStore = self.store
        selection.recordCorrection(CorrectionUndo(
            message: String(localized: "Renamed “\(oldName)” to “\(value)”"),
            actionName: String(localized: "Rename Place"),
            restore: { context in
                PlaceNames.restore(changes, context: context)
                // Still looking at the renamed place: back to what was shown
                // before, under its old name.
                if selection.libraryScope?.placeName == value {
                    selection.libraryScope = before
                }
            }
        ), context: modelContext)
        // The photos now listed under the new name: more than before when
        // the name joined another place.
        PlaceClue.showPhotos(at: value, store: store, selection: selection, replacing: true)
        // Typing is over, so a later change to the name (Undo) shows.
        isNaming = false
    }

    /// "Ignore this group": a stranger, or something that is not a face. The
    /// group leaves the row of faces; Undo brings it back.
    private func ignore() {
        let free: [FaceObservation] = faces.filter { (face: FaceObservation) -> Bool in face.personID == nil }
        guard !free.isEmpty else { return }
        let snapshot = IgnoredFacesSnapshot(free)
        guard let person = PeopleStoreActions.ignore(faces: free, context: modelContext) else { return }
        modelContext.saveOrReport()
        let hiddenPersonID: String = person.id
        selection.libraryScope = nil
        selection.recordCorrection(CorrectionUndo(
            message: String(localized: "Ignore this group"),
            actionName: String(localized: "Ignore Group"),
            restore: { context in snapshot.restore(hiddenPersonID: hiddenPersonID, context: context) }
        ), context: modelContext)
    }
}

/// Every face of one person, one per photo, sharpest first; the one clicked
/// becomes the face that stands for them.
struct KeyFacePicker: View {
    let faces: [FaceObservation]
    let current: String?
    let onPick: (FaceObservation) -> Void

    static let size: CGFloat = 64
    static let columns = 5

    /// One face per photo, so a burst does not fill the grid.
    private var choices: [FaceObservation] {
        var seen = Set<String>()
        var result: [FaceObservation] = []
        let sorted: [FaceObservation] = faces.sorted { (left: FaceObservation, right: FaceObservation) -> Bool in
            if left.quality != right.quality { return left.quality > right.quality }
            return left.id < right.id
        }
        for face in sorted {
            let mediaID: String = face.mediaID
            if face.id == current || seen.insert(mediaID).inserted { result.append(face) }
        }
        return result
    }

    var body: some View {
        let shown: [FaceObservation] = choices
        let rows: Int = (shown.count + Self.columns - 1) / Self.columns
        let gridHeight: CGFloat = min(CGFloat(rows) * (Self.size + 8), 340)
        VStack(alignment: .leading, spacing: 10) {
            PaperFormLabel(String(localized: "Choose key photo"))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.size), spacing: 8), count: Self.columns), spacing: 8) {
                    ForEach(shown, id: \.id) { (face: FaceObservation) in
                        Button { onPick(face) } label: {
                            FaceCropView(data: face.cropData, cacheKey: face.id, size: Self.size)
                                .overlay {
                                    if face.id == current {
                                        Circle().stroke(Paper.accent, lineWidth: 3)
                                    }
                                }
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library.scope.face.pick.\(face.id)")
                    }
                }
                .padding(2)
            }
            .frame(width: CGFloat(Self.columns) * Self.size + CGFloat(Self.columns - 1) * 8 + 4, height: gridHeight + 4)
        }
        .padding(14)
    }
}

/// The named people in one Library section, as small faces beside its
/// title. A face opens that person's photos.
struct LibrarySectionFaces: View {
    let sectionID: String
    let itemIDs: [String]
    let state: LibraryViewState
    @Environment(SelectionModel.self) private var selection
    @State private var shown: [PeopleStripEntry] = []

    static let limit = 4

    private var key: Int {
        var hasher = Hasher()
        hasher.combine(sectionID)
        hasher.combine(itemIDs.count)
        for entry in state.peopleEntries where entry.name != nil {
            hasher.combine(entry.id)
            hasher.combine(entry.photoCount)
            hasher.combine(entry.cover?.id)
        }
        return hasher.finalize()
    }

    var body: some View {
        HStack(spacing: -4) {
            ForEach(shown) { entry in
                Button {
                    selection.showInLibrary(
                        entry.mediaIDs,
                        title: entry.name ?? String(localized: "Who is this?"),
                        personID: entry.personID,
                        clusterID: entry.clusterID
                    )
                } label: {
                    PersonFace(face: entry.cover, size: 20)
                        .overlay { Circle().stroke(Paper.canvas, lineWidth: 1.5) }
                }
                .buttonStyle(.plain)
                .help(CompanionFaces.help(for: entry))
                .accessibilityLabel(entry.name ?? String(localized: "Who is this?"))
                .accessibilityIdentifier("library.section.person." + (entry.name ?? entry.id))
            }
        }
        .task(id: key) {
            var found: [PeopleStripEntry] = []
            for entry in state.peopleEntries where entry.name != nil {
                let isHere: Bool = itemIDs.contains { (id: String) -> Bool in entry.mediaIDs.contains(id) }
                if isHere { found.append(entry) }
                if found.count == Self.limit { break }
            }
            shown = found
        }
    }
}

/// The people in a chapter's photos, as faces with names; an unnamed group
/// shows as "Who is this?". A face opens that person's photos in the Library.
struct ChapterPeopleRow: View {
    let itemIDs: Set<String>
    /// The spacing of the stack this row sits in, taken back while there is
    /// nobody to show, so an empty row leaves no gap.
    var stackSpacing: CGFloat = 0
    @Environment(LibraryStore.self) private var store
    @Environment(SelectionModel.self) private var selection
    @Query(sort: \Person.name) private var people: [Person]
    @State private var entries: [PeopleStripEntry] = []

    private var key: Int {
        var hasher = Hasher()
        hasher.combine(itemIDs.count)
        hasher.combine(store.photoFaceRevision)
        hasher.combine(store.refreshCount)
        hasher.combine(store.keyFaceRevision)
        for person in people {
            hasher.combine(person.id)
            hasher.combine(person.name)
            hasher.combine(person.hidden)
        }
        return hasher.finalize()
    }

    var body: some View {
        // One view in either case: a modifier on an empty `Group` never runs,
        // so the lookup would not start.
        Group {
            if entries.isEmpty {
                Color.clear
                    .frame(width: 0, height: 0)
                    .padding(.top, -stackSpacing)
                    .accessibilityHidden(true)
            } else {
                HStack(spacing: 12) {
                    ForEach(entries) { entry in
                        Button { open(entry) } label: {
                            HStack(spacing: 6) {
                                PersonFace(face: entry.cover, size: 26)
                                Text(verbatim: entry.name ?? String(localized: "Who is this?"))
                                    .font(.callout)
                                    .foregroundStyle(entry.name == nil ? Paper.muted : Paper.ink)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(CompanionFaces.help(for: entry))
                        .accessibilityLabel(entry.name ?? String(localized: "Who is this?"))
                        .accessibilityIdentifier("trips.person." + (entry.name ?? entry.id))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("trips.people")
            }
        }
        .task(id: key) {
            let found = PeopleStrip.companions(in: ["chapter": itemIDs], faces: store.faces, people: people, itemsByID: store.itemsByID, limit: 6)
            entries = found["chapter"] ?? []
        }
    }

    private func open(_ entry: PeopleStripEntry) {
        PersonClue.showPhotos(of: entry, store: store, selection: selection)
    }
}

/// Who was on a chapter, as small overlapping faces on its card on the
/// shelf. A face opens that person's photos in the Library; the card itself
/// still opens the chapter.
struct CompanionFaces: View {
    let entries: [PeopleStripEntry]
    var size: CGFloat = 22
    @Environment(LibraryStore.self) private var store
    @Environment(SelectionModel.self) private var selection

    var body: some View {
        if !entries.isEmpty {
            HStack(spacing: -5) {
                ForEach(entries) { entry in
                    Button {
                        PersonClue.showPhotos(of: entry, store: store, selection: selection)
                    } label: {
                        PersonFace(face: entry.cover, size: size)
                            .overlay { Circle().stroke(Paper.raised, lineWidth: 1.5) }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(Self.help(for: entry))
                    .accessibilityLabel(entry.name ?? String(localized: "Who is this?"))
                    .accessibilityIdentifier("trips.card.person." + (entry.name ?? entry.id))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("trips.card.people")
        }
    }

    static func help(for entry: PeopleStripEntry) -> String {
        guard let name = entry.name else { return String(localized: "Who is this?") }
        return String(localized: "Show photos of \(name)")
    }
}

// MARK: - Places

@MainActor
enum PlaceClue {
    /// The Library, showing only the photos taken at the place called
    /// `name`: the photos whose own place name is that, and the photos of
    /// places with that name or inside one.
    static func showPhotos(at name: String, store: LibraryStore, selection: SelectionModel, replacing: Bool = false) {
        let key: String = PlaceNames.key(name)
        guard !key.isEmpty else { return }
        var ids: [String] = []
        for item in store.regularItems where PlaceNames.matches(item, key: key) {
            ids.append(item.id)
        }
        selection.showInLibrary(ids, title: name, placeName: name, replacing: replacing)
    }
}

enum MiniMapStops {
    /// Where a set of photos was taken, as a few stamps for a small map: one
    /// per half-degree cell with photos, the fullest cells first.
    @MainActor
    static func make(_ items: [MediaItem], limit: Int = 12) -> [TripRouteStop] {
        var sums: [String: (latitude: Double, longitude: Double, count: Int)] = [:]
        for item in items {
            guard let latitude = item.latitude, let longitude = item.longitude else { continue }
            let cell: String = "\(Int((latitude * 2).rounded())):\(Int((longitude * 2).rounded()))"
            let sum = sums[cell] ?? (0, 0, 0)
            sums[cell] = (sum.latitude + latitude, sum.longitude + longitude, sum.count + 1)
        }
        let cells = sums.sorted { (left, right) -> Bool in
            if left.value.count != right.value.count { return left.value.count > right.value.count }
            return left.key < right.key
        }
        return cells.prefix(limit).map { cell -> TripRouteStop in
            TripRouteStop(
                name: "",
                latitude: cell.value.latitude / Double(cell.value.count),
                longitude: cell.value.longitude / Double(cell.value.count)
            )
        }
    }
}

/// A small drawn map that opens the large one. It stands for a set of
/// photos: one photo, a person's, a place's, a chapter's.
struct PhotoMiniMap: View {
    let stops: [TripRouteStop]
    var width: CGFloat = 104
    var height: CGFloat = 58
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TripRouteMap(stops: stops, showsRoute: false, inset: CGSize(width: 14, height: 12))
                .frame(width: width, height: height)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Paper.muted)
                        .padding(4)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Open the map"))
        .accessibilityLabel(String(localized: "Open the map"))
    }
}
