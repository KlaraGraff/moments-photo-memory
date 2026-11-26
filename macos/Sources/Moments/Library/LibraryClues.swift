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
    /// At most this many unnamed groups ask for a name at a time.
    static let maximumUnnamed = 6

    /// Named people first, most photos first; then the largest unnamed groups.
    /// Faces in screenshots and in Recently Deleted photos do not count.
    static func entries(faces: [FaceObservation], people: [Person], itemsByID: [String: MediaItem]) -> [PeopleStripEntry] {
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
            let cover: FaceObservation? = PeopleFacePicker.cover(group, keyFaceID: PeopleStoreActions.keyFaceID(for: personID))
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
        return named + Array(unnamed.prefix(maximumUnnamed))
    }

    /// The named people in a set of photos, most photos first, for the small
    /// faces on a chapter.
    static func people(in mediaIDs: Set<String>, faces: [FaceObservation], people: [Person], limit: Int) -> [PeopleStripEntry] {
        var names: [String: String] = [:]
        for person in people where !person.hidden {
            let name: String = person.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty { names[person.id] = name }
        }
        var byPerson: [String: [FaceObservation]] = [:]
        for face in faces {
            guard let personID = face.personID, names[personID] != nil, mediaIDs.contains(face.mediaID) else { continue }
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
                cover: PeopleFacePicker.cover(group),
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

@MainActor
enum PersonClue {
    /// The Library, showing only this person's photos.
    static func showPhotos(ofPerson personID: String, name: String?, store: LibraryStore, selection: SelectionModel) {
        var ids = Set<String>()
        for face in store.faces where face.personID == personID {
            guard let item = store.itemsByID[face.mediaID], !item.isScreenshot else { continue }
            ids.insert(face.mediaID)
        }
        selection.showInLibrary(ids, title: name ?? String(localized: "Who is this?"), personID: personID)
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
struct LibraryPeopleStrip: View {
    let entries: [PeopleStripEntry]
    @Environment(SelectionModel.self) private var selection

    var body: some View {
        if !entries.isEmpty {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(entries) { entry in
                        Button { open(entry) } label: { label(entry) }
                            .buttonStyle(.plain)
                            .help(entry.name.map { String(localized: "Show photos of \($0)") } ?? String(localized: "Who is this?"))
                            .accessibilityLabel(entry.name ?? String(localized: "Who is this?"))
                            .accessibilityIdentifier("library.person." + (entry.name ?? "unnamed"))
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.never)
            .padding(.bottom, 22)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.people")
        }
    }

    private func label(_ entry: PeopleStripEntry) -> some View {
        VStack(spacing: 4) {
            PersonFace(face: entry.cover, size: 48)
            Text(verbatim: entry.name ?? "?")
                .font(.caption)
                .foregroundStyle(entry.name == nil ? LibraryPalette.muted : LibraryPalette.ink)
                .lineLimit(1)
            Text(verbatim: "\(entry.photoCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(LibraryPalette.muted)
        }
        .frame(width: 64)
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
/// every photo. A person's or a place's name is typed right here; a name
/// another one already has joins the two.
struct LibraryScopeHeading: View {
    let scope: LibraryScope
    let photoCount: Int
    @Environment(SelectionModel.self) private var selection
    @Environment(LibraryStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Person.name) private var people: [Person]
    @State private var nameText = ""
    @State private var stops: [TripRouteStop] = []
    @FocusState private var isNaming: Bool

    private var isPerson: Bool { scope.personID != nil || scope.clusterID != nil }
    private var isPlace: Bool { scope.placeName != nil }

    /// The faces this heading is about: the person's, or the unnamed group's.
    private var faces: [FaceObservation] {
        if let personID = scope.personID {
            return store.faces.filter { (face: FaceObservation) -> Bool in face.personID == personID }
        }
        if let clusterID = scope.clusterID {
            return store.faces.filter { (face: FaceObservation) -> Bool in face.personID == nil && face.clusterID == clusterID }
        }
        return []
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if isPerson {
                PersonFace(face: cover, size: 40)
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
                    .help(String(localized: "Type a place name. Return saves; empty goes back to the place found when importing."))
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
            Button {
                selection.libraryScope = nil
            } label: {
                Label(String(localized: "All photos"), systemImage: "xmark")
            }
            .help(String(localized: "Back to all photos"))
            .accessibilityIdentifier("library.scope.close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, PaperMetrics.screenInset)
        .padding(.top, PaperMetrics.screenTopInset)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.scope")
        .task(id: scope) {
            nameText = scope.personID != nil || scope.placeName != nil ? scope.title : ""
            let items: [MediaItem] = scope.itemIDs.compactMap { (id: String) -> MediaItem? in store.itemsByID[id] }
            stops = MiniMapStops.make(items)
            // A group nobody has named: the cursor waits in the name field.
            if scope.clusterID != nil { isNaming = true }
        }
    }

    private var cover: FaceObservation? {
        let group: [FaceObservation] = faces
        if let personID = scope.personID {
            return PeopleFacePicker.cover(group, keyFaceID: PeopleStoreActions.keyFaceID(for: personID))
        }
        return PeopleFacePicker.cover(group)
    }

    /// Typing a name: an unnamed group becomes that person; a person takes
    /// the new name. A name another person already has joins the two, so
    /// "merge" is never a separate step.
    private func commitName() {
        let value: String = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let personID = scope.personID {
            guard let person = people.first(where: { (person: Person) -> Bool in person.id == personID }),
                  person.name != value else { return }
            var shownID: String = personID
            if let target = PeopleStoreActions.mergeCandidate(forName: value, people: people, excluding: personID) {
                PeopleStoreActions.merge(sourceID: personID, into: target.id, people: people, observations: store.faces, context: modelContext)
                shownID = target.id
            } else {
                person.name = value
                person.updatedAt = .now
            }
            try? modelContext.save()
            selection.libraryScope = LibraryScope(title: value, itemIDs: scope.itemIDs, personID: shownID)
        } else if let clusterID = scope.clusterID {
            let group: [FaceObservation] = faces
            guard !group.isEmpty else { return }
            let target: Person? = PeopleStoreActions.mergeCandidate(forName: value, people: people)
            let shownID: String? = PeopleStoreActions.name(
                faces: group,
                as: value,
                mergingInto: target,
                keepSeparate: false,
                people: people,
                observations: store.faces,
                context: modelContext
            )
            try? modelContext.save()
            selection.libraryScope = LibraryScope(
                title: value,
                itemIDs: scope.itemIDs,
                personID: shownID,
                clusterID: shownID == nil ? clusterID : nil
            )
        }
    }

    /// Typing over a place's name renames the place for every photo taken
    /// there. A name another place already has joins the two places.
    private func commitPlaceName() {
        guard let oldName = scope.placeName else { return }
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
        try? modelContext.save()
        let selection: SelectionModel = self.selection
        let store: LibraryStore = self.store
        selection.recordCorrection(CorrectionUndo(
            message: String(localized: "Renamed “\(oldName)” to “\(value)”"),
            actionName: String(localized: "Rename Place"),
            restore: { context in
                PlaceNames.restore(changes, context: context)
                // Still looking at the renamed place: show it under its old name again.
                if selection.libraryScope?.placeName == value {
                    PlaceClue.showPhotos(at: oldName, store: store, selection: selection)
                }
            }
        ), context: modelContext)
        // The photos now listed under the new name: more than before when
        // the name joined another place.
        PlaceClue.showPhotos(at: value, store: store, selection: selection)
    }

    /// "Ignore this group": a stranger, or something that is not a face. The
    /// group leaves the row of faces; Undo brings it back.
    private func ignore() {
        let free: [FaceObservation] = faces.filter { (face: FaceObservation) -> Bool in face.personID == nil }
        guard !free.isEmpty else { return }
        let snapshot = IgnoredFacesSnapshot(free)
        guard let person = PeopleStoreActions.ignore(faces: free, context: modelContext) else { return }
        try? modelContext.save()
        let hiddenPersonID: String = person.id
        selection.libraryScope = nil
        selection.recordCorrection(CorrectionUndo(
            message: String(localized: "Ignore this group"),
            actionName: String(localized: "Ignore Group"),
            restore: { context in snapshot.restore(hiddenPersonID: hiddenPersonID, context: context) }
        ), context: modelContext)
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
        }
        return hasher.finalize()
    }

    var body: some View {
        HStack(spacing: -4) {
            ForEach(shown) { entry in
                Button {
                    selection.showInLibrary(entry.mediaIDs, title: entry.name ?? "", personID: entry.personID)
                } label: {
                    PersonFace(face: entry.cover, size: 20)
                        .overlay { Circle().stroke(Paper.canvas, lineWidth: 1.5) }
                }
                .buttonStyle(.plain)
                .help(String(localized: "Show photos of \(entry.name ?? "")"))
                .accessibilityLabel(entry.name ?? "")
                .accessibilityIdentifier("library.section.person." + (entry.name ?? ""))
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

/// The named people in a chapter's photos, as small faces with names. A face
/// opens that person's photos in the Library.
struct ChapterPeopleRow: View {
    let itemIDs: Set<String>
    @Environment(LibraryStore.self) private var store
    @Environment(SelectionModel.self) private var selection
    @Query(sort: \Person.name) private var people: [Person]
    @State private var entries: [PeopleStripEntry] = []

    private var key: Int {
        var hasher = Hasher()
        hasher.combine(itemIDs.count)
        hasher.combine(store.photoFaceRevision)
        hasher.combine(store.refreshCount)
        for person in people {
            hasher.combine(person.id)
            hasher.combine(person.name)
            hasher.combine(person.hidden)
        }
        return hasher.finalize()
    }

    var body: some View {
        Group {
            if !entries.isEmpty {
                HStack(spacing: 12) {
                    ForEach(entries) { entry in
                        Button { open(entry) } label: {
                            HStack(spacing: 6) {
                                PersonFace(face: entry.cover, size: 26)
                                Text(verbatim: entry.name ?? "")
                                    .font(.callout)
                                    .foregroundStyle(Paper.ink)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Show photos of \(entry.name ?? "")"))
                        .accessibilityLabel(entry.name ?? "")
                        .accessibilityIdentifier("trips.person." + (entry.name ?? ""))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("trips.people")
            }
        }
        .task(id: key) {
            entries = PeopleStrip.people(in: itemIDs, faces: store.faces, people: people, limit: 6)
        }
    }

    private func open(_ entry: PeopleStripEntry) {
        guard let personID = entry.personID else { return }
        PersonClue.showPhotos(ofPerson: personID, name: entry.name, store: store, selection: selection)
    }
}

// MARK: - Places

@MainActor
enum PlaceClue {
    /// The Library, showing only the photos taken at the place called
    /// `name`: the photos whose own place name is that, and the photos of
    /// places with that name or inside one.
    static func showPhotos(at name: String, store: LibraryStore, selection: SelectionModel) {
        let key: String = PlaceNames.key(name)
        guard !key.isEmpty else { return }
        var ids: [String] = []
        for item in store.regularItems where PlaceNames.matches(item, key: key) {
            ids.append(item.id)
        }
        selection.showInLibrary(ids, title: name, placeName: name)
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
