import SwiftData
import SwiftUI

/// The viewer's right-hand column. Everything in it can be changed where it
/// stands: click the date to adjust it, type over the place, pick another
/// trip, say who a face is, and write a longer note whose AI result shows
/// right under it.
struct PhotoInfoPanel: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: MediaItem
    let libraryState: LibraryViewState
    /// True while one of the column's own fields is being typed in, so the
    /// viewer leaves Esc and the arrow keys to that field.
    @Binding var isEditing: Bool

    @Query private var trips: [Trip]
    @Query private var people: [Person]
    @Query private var faces: [FaceObservation]

    @State private var placeText = ""
    @State private var tripNameText = ""
    @State private var isRenamingTrip = false
    @State private var showingDatePicker = false
    @State private var draftDate = Date.now
    @State private var namingFaceID: String?
    @State private var faceNameText = ""
    @State private var isHoveringDate = false
    @FocusState private var field: Field?

    private enum Field: Hashable {
        case place, tripName, faceName
    }

    init(item: MediaItem, libraryState: LibraryViewState, isEditing: Binding<Bool>) {
        self.item = item
        self.libraryState = libraryState
        _isEditing = isEditing
        let mediaID = item.id
        _faces = Query(filter: #Predicate<FaceObservation> { $0.mediaID == mediaID }, sort: \FaceObservation.rectX)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                dateSection
                row(String(localized: "Place")) { placeField }
                row(String(localized: "Trip")) { tripField }
                if !visibleFaces.isEmpty {
                    row(String(localized: "People")) { peopleList }
                }
                if libraryState.memoryDrafts[item.id] != nil
                    || item.latestMemory?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    row(String(localized: "Memory")) {
                        MemoryEditor(item: item, state: libraryState)
                    }
                }
                row(String(localized: "Note")) {
                    VStack(alignment: .leading, spacing: 14) {
                        PhotoNoteSection(item: item, state: libraryState, isLarge: true)
                        PhotoNoteResults(item: item)
                    }
                }
            }
            .padding(20)
        }
        .onAppear { placeText = item.namedPlace ?? "" }
        .onChange(of: item.namedPlace) { _, name in
            // The AI or another screen corrected the place while the field was idle.
            if field != .place { placeText = name ?? "" }
        }
        .onChange(of: field) { _, value in isEditing = value != nil }
        // Paging away while typing: keep what was typed and give the keys back.
        .onDisappear {
            commitPlace()
            if isRenamingTrip { commitTripName() }
            if let id = namingFaceID, let face = faces.first(where: { $0.id == id }) { commitFaceName(face) }
            isEditing = false
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(LibraryPalette.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Date and time

    private var dateSection: some View {
        Button {
            draftDate = item.effectiveCaptureDate ?? .now
            showingDatePicker = true
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.effectiveCaptureDate?.formatted(date: .long, time: .omitted) ?? String(localized: "Add a date"))
                        .font(.system(size: 20, weight: .medium, design: .serif))
                        .foregroundStyle(item.effectiveCaptureDate == nil ? LibraryPalette.muted : LibraryPalette.ink)
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(LibraryPalette.muted)
                        .opacity(isHoveringDate || showingDatePicker ? 1 : 0)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let time = item.effectiveCaptureDate?.formatted(date: .omitted, time: .shortened) {
                        Text(time)
                            .font(.callout)
                            .foregroundStyle(LibraryPalette.muted)
                    }
                    if item.userCorrectedCaptureDateUTC != nil {
                        editedMark
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringDate = $0 }
        .help(String(localized: "Adjust date and time"))
        .accessibilityIdentifier("viewer.date")
        .popover(isPresented: $showingDatePicker, arrowEdge: .leading) { datePopover }
    }

    private var editedMark: some View {
        Text(String(localized: "Edited"))
            .font(.caption2)
            .foregroundStyle(LibraryPalette.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(LibraryPalette.well))
    }

    private var datePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Adjust date and time"))
                .font(.headline)
                .foregroundStyle(LibraryPalette.ink)
            DatePicker("", selection: $draftDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            DatePicker(String(localized: "Time"), selection: $draftDate, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
            if item.userCorrectedCaptureDateUTC != nil, let original = item.captureDate {
                Text(String(localized: "Original: \(original.formatted(date: .abbreviated, time: .shortened))"))
                    .font(.caption)
                    .foregroundStyle(LibraryPalette.muted)
            }
            HStack {
                if item.userCorrectedCaptureDateUTC != nil, item.captureDate != nil {
                    Button(String(localized: "Use original")) {
                        PhotoInfoEditing.revertCaptureDate(on: item)
                        save()
                        showingDatePicker = false
                    }
                }
                Spacer()
                Button(String(localized: "Cancel")) { showingDatePicker = false }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Done")) {
                    PhotoInfoEditing.setCaptureDate(draftDate, on: item)
                    save()
                    showingDatePicker = false
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("viewer.date.done")
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 280)
    }

    // MARK: Place

    private var placeField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("", text: $placeText, prompt: Text(String(localized: "Add a place")))
                .textFieldStyle(.plain)
                .foregroundStyle(LibraryPalette.ink)
                .focused($field, equals: .place)
                .modifier(InlineFieldUnderline(isFocused: field == .place, reduceMotion: reduceMotion))
                .onSubmit { commitPlace() }
                .onExitCommand {
                    placeText = item.namedPlace ?? ""
                    field = nil
                }
                .onChange(of: field) { old, _ in
                    if old == .place { commitPlace() }
                }
                .help(String(localized: "Type a place name. Return saves; empty goes back to the place found when importing."))
                .accessibilityIdentifier("viewer.place")
            if let correctedFrom {
                Text(String(localized: "Corrected, was \(correctedFrom)"))
                    .font(.caption2)
                    .foregroundStyle(LibraryPalette.muted)
            }
        }
    }

    private var correctedFrom: String? {
        guard let override = item.placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty,
              let original = item.place.flatMap(PlaceDisplayName.resolvedName(of:)), original != override else { return nil }
        return original
    }

    private func commitPlace() {
        guard placeText.trimmingCharacters(in: .whitespacesAndNewlines) != (item.namedPlace ?? "") else { return }
        PhotoInfoEditing.setPlaceName(placeText, on: item, context: modelContext)
        save()
        placeText = item.namedPlace ?? ""
        if field == .place { field = nil }
    }

    // MARK: Trip

    @ViewBuilder
    private var tripField: some View {
        if isRenamingTrip, let trip = item.trip {
            TextField("", text: $tripNameText, prompt: Text(trip.name))
                .textFieldStyle(.plain)
                .foregroundStyle(LibraryPalette.ink)
                .focused($field, equals: .tripName)
                .modifier(InlineFieldUnderline(isFocused: field == .tripName, reduceMotion: reduceMotion))
                // The field only exists after the menu closes, so focus it then.
                .onAppear { DispatchQueue.main.async { field = .tripName } }
                .onSubmit { commitTripName() }
                .onExitCommand {
                    isRenamingTrip = false
                    field = nil
                }
                .onChange(of: field) { old, _ in
                    if old == .tripName, isRenamingTrip { commitTripName() }
                }
        } else {
            Menu {
                ForEach(namedTrips, id: \.id) { trip in
                    Button {
                        PhotoInfoEditing.setTrip(trip, on: item)
                        save()
                    } label: {
                        if trip.id == item.trip?.id {
                            Label(trip.effectiveName, systemImage: "checkmark")
                        } else {
                            Text(trip.effectiveName)
                        }
                    }
                }
                Divider()
                Button(String(localized: "Not in a trip")) {
                    PhotoInfoEditing.setTrip(nil, on: item)
                    save()
                }
                .disabled(item.trip == nil)
                if let trip = item.trip {
                    Divider()
                    Button(String(localized: "Rename “\(trip.effectiveName)”…")) {
                        tripNameText = trip.effectiveName
                        isRenamingTrip = true
                    }
                }
            } label: {
                Text(item.trip?.effectiveName ?? String(localized: "Not in a trip"))
                    .foregroundStyle(item.trip == nil ? LibraryPalette.muted : LibraryPalette.ink)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("viewer.trip")
        }
    }

    /// Newest trip first.
    private var namedTrips: [Trip] {
        trips
            .filter { !$0.effectiveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.startDate ?? .distantPast, $0.id) > ($1.startDate ?? .distantPast, $1.id) }
    }

    private func commitTripName() {
        if let trip = item.trip {
            PhotoInfoEditing.renameTrip(trip, to: tripNameText)
            save()
        }
        isRenamingTrip = false
        if field == .tripName { field = nil }
    }

    // MARK: People

    private var hiddenPersonIDs: Set<String> {
        Set(people.filter(\.hidden).map(\.id))
    }

    /// Faces in this photo, left to right, leaving out people the person hid.
    private var visibleFaces: [FaceObservation] {
        faces.filter { face in face.personID.map { !hiddenPersonIDs.contains($0) } ?? true }
    }

    private var namedPeople: [Person] {
        people
            .filter { !$0.hidden && $0.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
            .sorted { ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending }
    }

    private func name(of face: FaceObservation) -> String? {
        guard let personID = face.personID,
              let name = people.first(where: { $0.id == personID })?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    private var peopleList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(visibleFaces, id: \.id) { face in
                HStack(spacing: 8) {
                    FaceCropView(data: face.cropData, cacheKey: face.id, size: 26)
                    if namingFaceID == face.id {
                        TextField("", text: $faceNameText, prompt: Text(String(localized: "Name")))
                            .textFieldStyle(.plain)
                            .foregroundStyle(LibraryPalette.ink)
                            .focused($field, equals: .faceName)
                            .modifier(InlineFieldUnderline(isFocused: field == .faceName, reduceMotion: reduceMotion))
                            .onAppear { DispatchQueue.main.async { field = .faceName } }
                            .onSubmit { commitFaceName(face) }
                            .onExitCommand {
                                namingFaceID = nil
                                field = nil
                            }
                            .onChange(of: field) { old, _ in
                                if old == .faceName, namingFaceID == face.id { commitFaceName(face) }
                            }
                    } else {
                        faceMenu(face)
                    }
                }
            }
        }
    }

    private func faceMenu(_ face: FaceObservation) -> some View {
        let current = name(of: face)
        return Menu {
            Section(String(localized: "Who is this?")) {
                ForEach(namedPeople.filter { $0.id != face.personID }, id: \.id) { person in
                    Button(person.name ?? "") { assign(face, to: person) }
                }
                Button(String(localized: "New name…")) {
                    faceNameText = ""
                    namingFaceID = face.id
                }
            }
            if face.personID != nil {
                Divider()
                Button(String(localized: "Not \(current ?? String(localized: "this person"))")) {
                    PeopleStoreActions.remove(face: face)
                    save()
                }
            }
        } label: {
            Text(current ?? String(localized: "Who is this?"))
                .foregroundStyle(current == nil ? LibraryPalette.muted : LibraryPalette.ink)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func assign(_ face: FaceObservation, to person: Person) {
        guard let name = person.name else { return }
        let observations = (try? modelContext.fetch(FetchDescriptor<FaceObservation>())) ?? []
        PeopleStoreActions.name(
            faces: [face], as: name, mergingInto: person, keepSeparate: false,
            people: people, observations: observations, context: modelContext
        )
        save()
    }

    private func commitFaceName(_ face: FaceObservation) {
        let value = faceNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        namingFaceID = nil
        if field == .faceName { field = nil }
        guard !value.isEmpty else { return }
        // A name someone already has joins them, as on the People screen.
        if let existing = PeopleStoreActions.mergeCandidate(forName: value, people: people) {
            assign(face, to: existing)
            return
        }
        let observations = (try? modelContext.fetch(FetchDescriptor<FaceObservation>())) ?? []
        PeopleStoreActions.name(
            faces: [face], as: value, mergingInto: nil, keepSeparate: false,
            people: people, observations: observations, context: modelContext
        )
        save()
    }

    private func save() {
        try? modelContext.save()
    }
}

/// A field that reads as plain text until it is clicked: a faint rule
/// appears under it on focus, like the note line.
private struct InlineFieldUnderline: ViewModifier {
    let isFocused: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 3)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isFocused ? LibraryPalette.muted.opacity(0.7) : LibraryPalette.rule.opacity(0.5))
                    .frame(height: isFocused ? 1.5 : 1)
                    .animation(Motion.animation(Motion.settle, reduceMotion: reduceMotion), value: isFocused)
            }
    }
}
