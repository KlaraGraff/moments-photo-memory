import MomentsCore
import SwiftData
import SwiftUI

// MARK: Settings

/// Settings › Your places: the places the person named, the places found in
/// their photos waiting for a yes or no, the places a visit to is no trip,
/// and how long a stay makes daily life. Each change sorts the trips nobody
/// touched again.
struct KnownPlacesSettingsSection: View {
    @Environment(\.modelContext) private var modelContext
    @State private var book = KnownPlaceStore.book()
    /// `nil` while the photos are searched.
    @State private var found: [FoundPlace]?
    @State private var hasLocatedPhotos = true
    @State private var isAdding = false
    @State private var removing: KnownPlace?
    @State private var days = KnownPlaceStore.book().effectiveLivedThereDays

    private var named: [KnownPlace] { book.places.filter { $0.role != .notTrip } }
    private var notTrip: [KnownPlace] { book.places.filter { $0.role == .notTrip } }
    private var open: [FoundPlace] {
        let candidates = book.open((found ?? []).map(\.candidate))
        return (found ?? []).filter { place in candidates.contains { $0.centre == place.candidate.centre } }
    }

    var body: some View {
        Group {
            yourPlaces
            if !open.isEmpty { foundPlaces }
            notTripPlaces
            stayLength
        }
        .task { await search() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDecisionChanged)) { note in
            guard note.object as? String == KnownPlaceStore.key else { return }
            book = KnownPlaceStore.book()
        }
        .task(id: days) {
            // Steps of the stepper settle before the trips are sorted again.
            guard days != book.effectiveLivedThereDays else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            change { $0.setLivedThereDays(days) }
        }
        .sheet(isPresented: $isAdding) {
            AddPlaceSheet { place in change { $0.add(place) } }
        }
        .confirmationDialog(
            removing.map { String(localized: "Remove “\($0.role.label) · \($0.name)”?") } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { place in
            Button(String(localized: "Remove Place"), role: .destructive) {
                change { $0.remove(place.id) }
            }
            .accessibilityIdentifier("settings.places.remove.confirm")
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { place in
            Text(String(localized: "Chapters you already have stay as they are. From now on, photos from \(place.name) can be trips again."))
        }
    }

    // MARK: Sections

    private var yourPlaces: some View {
        Section {
            if named.isEmpty {
                if found == nil {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "Looking for the places you spend your time at…"))
                            .foregroundStyle(Paper.muted)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.places.loading")
                } else if !hasLocatedPhotos {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "No photo locations yet"))
                            .foregroundStyle(Paper.ink)
                        Text(String(localized: "After you import photos with locations, Moments finds the places you spend your time at and asks you once. You can also add one yourself now."))
                            .font(.callout)
                            .foregroundStyle(Paper.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.places.empty")
                }
            }
            ForEach(named) { place in
                PlaceRow(place: place, roles: PlaceRole.chosen, onRole: { role in change { $0.setRole(role, of: place.id) } }, onRemove: { removing = place })
            }
            Button {
                isAdding = true
            } label: {
                Label(String(localized: "Add Place…"), systemImage: "plus")
            }
            .accessibilityIdentifier("settings.places.add")
        } header: {
            Text(String(localized: "Your places"))
        } footer: {
            Text(String(localized: "Moments uses these places to tell daily life from trips. Kept on this Mac."))
                .font(.caption)
                .foregroundStyle(Paper.muted)
        }
    }

    private var foundPlaces: some View {
        Section {
            ForEach(open) { place in
                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(Paper.muted)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name).foregroundStyle(Paper.ink)
                        Text("\(place.dateSpan()) · \(place.detail)")
                            .font(.caption)
                            .foregroundStyle(Paper.muted)
                    }
                    Spacer(minLength: 8)
                    Menu {
                        ForEach(PlaceRole.chosen, id: \.self) { role in
                            Button(role.label) { confirm(place, as: role) }
                        }
                    } label: {
                        Text(place.candidate.suggestedRole.label)
                    } primaryAction: {
                        confirm(place, as: place.candidate.suggestedRole)
                    }
                    .fixedSize()
                    .help(String(localized: "Confirm what this place is"))
                    .accessibilityIdentifier("settings.places.found.confirm")
                    Button(String(localized: "No")) {
                        change { $0.decline(place.candidate.centre) }
                    }
                    .accessibilityIdentifier("settings.places.found.decline")
                }
                .accessibilityElement(children: .contain)
            }
        } header: {
            Text(String(localized: "Found in your photos"))
        } footer: {
            Text(String(localized: "Are these places you live or work at? Time there is not counted as a trip."))
                .font(.caption)
                .foregroundStyle(Paper.muted)
        }
    }

    private var notTripPlaces: some View {
        Section {
            if notTrip.isEmpty {
                Text(String(localized: "None yet. When you choose “This is not a trip” on a trip, you can add its place here."))
                    .font(.callout)
                    .foregroundStyle(Paper.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(notTrip) { place in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "\(place.name) (within \(Int(TripSegmenter().awayRadiusMeters / 1_000)) km)"))
                            .foregroundStyle(Paper.ink)
                        Text(String(localized: "Added \(place.addedAt.formatted(date: .abbreviated, time: .omitted))"))
                            .font(.caption)
                            .foregroundStyle(Paper.muted)
                    }
                    Spacer(minLength: 8)
                    Button(String(localized: "Remove")) { removing = place }
                        .accessibilityIdentifier("settings.places.nottrip.remove")
                }
            }
        } header: {
            Text(String(localized: "Visiting these places is no trip"))
        }
    }

    private var stayLength: some View {
        Section {
            Stepper(value: $days, in: KnownPlaceBook.livedThereDaysRange) {
                LabeledContent(String(localized: "A stay this long is daily life")) {
                    Text(String(localized: "\(days) days"))
                        .monospacedDigit()
                        .foregroundStyle(Paper.ink)
                }
            }
            .accessibilityIdentifier("settings.places.days")
        } footer: {
            Text(String(localized: "Living somewhere for this many days or more, like a new work site, is daily life, not a trip."))
                .font(.caption)
                .foregroundStyle(Paper.muted)
        }
    }

    // MARK: Changes

    private func confirm(_ place: FoundPlace, as role: PlaceRole) {
        change { $0.confirm(place.candidate, name: place.name, role: role, now: .now) }
    }

    private func change(_ edit: (inout KnownPlaceBook) -> Void) {
        KnownPlaceStore.change(context: modelContext, edit)
        book = KnownPlaceStore.book()
    }

    private func search() async {
        let items = (try? modelContext.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        hasLocatedPhotos = items.contains { $0.latitude != nil && $0.longitude != nil }
        found = await KnownPlaceStore.findPlaces(items: items, book: book)
    }
}

/// One named place: what it is, when, and what that means for trips.
private struct PlaceRow: View {
    let place: KnownPlace
    let roles: [PlaceRole]
    let onRole: (PlaceRole) -> Void
    let onRemove: () -> Void
    @Environment(\.locale) private var locale

    private var when: String? {
        guard let since = place.since else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("yyyyMM")
        let first = formatter.string(from: since)
        guard let until = place.until else { return String(localized: "\(first) – now") }
        return "\(first) – \(formatter.string(from: until))"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: place.role.symbol)
                .foregroundStyle(Paper.accent)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(place.name).foregroundStyle(Paper.ink)
                    Text(place.role.label)
                        .font(.caption)
                        .foregroundStyle(Paper.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Paper.well, in: Capsule())
                }
                Text([when, place.role.meaning].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Paper.muted)
            }
            Spacer(minLength: 8)
            Menu {
                Picker(String(localized: "This place is"), selection: Binding(get: { place.role }, set: onRole)) {
                    ForEach(roles, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Button(String(localized: "Remove…"), role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "Change or remove"))
            .accessibilityLabel(String(localized: "Change or remove \(place.name)"))
            .accessibilityIdentifier("settings.places.more")
        }
        .accessibilityElement(children: .contain)
    }
}

/// Adds a place by hand, from the cities in the library.
private struct AddPlaceSheet: View {
    let onAdd: (KnownPlace) -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var cities: [City] = []
    @State private var query = ""
    @State private var chosen: City.ID?
    @State private var role: PlaceRole = .home

    struct City: Identifiable {
        let id: String
        let name: String
        let centre: GeoPoint
        let photos: Int
    }

    private var shown: [City] {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return cities }
        return cities.filter { $0.name.localizedCaseInsensitiveContains(typed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Add a place"))
                .font(.system(size: 20, weight: .medium, design: .serif))
                .foregroundStyle(Paper.ink)
            TextField("", text: $query, prompt: Text(String(localized: "Search cities in your photos")))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.places.add.search")
            List(shown, selection: $chosen) { city in
                HStack {
                    Text(city.name)
                    Spacer()
                    Text(String(localized: "\(city.photos) photos"))
                        .monospacedDigit()
                        .foregroundStyle(Paper.muted)
                }
                .tag(city.id)
            }
            .frame(minHeight: 200)
            .overlay {
                if cities.isEmpty {
                    Text(String(localized: "No named places in your photos yet."))
                        .foregroundStyle(Paper.muted)
                }
            }
            Picker(String(localized: "This place is"), selection: $role) {
                ForEach(PlaceRole.chosen, id: \.self) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("settings.places.add.role")
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Add")) {
                    guard let city = cities.first(where: { $0.id == chosen }) else { return }
                    onAdd(KnownPlace(name: city.name, role: role, centre: city.centre, addedAt: .now))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil)
                .accessibilityIdentifier("settings.places.add.done")
            }
        }
        .padding(PaperMetrics.sheetInset)
        .frame(width: 420, height: 440)
        .background(Paper.canvas)
        .onAppear(perform: load)
    }

    /// Each named city with a location, most photographed first.
    private func load() {
        let items = (try? modelContext.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        var counts: [String: (place: Place, count: Int)] = [:]
        for item in items {
            var current = item.place
            var depth = 0
            while let place = current, place.kind != .city, depth < 4 {
                current = place.parent
                depth += 1
            }
            guard let city = current, city.kind == .city else { continue }
            counts[city.id, default: (city, 0)].count += 1
        }
        cities = counts.values.compactMap { entry in
            guard let name = PlaceDisplayName.resolvedName(of: entry.place),
                  let latitude = entry.place.latitude, let longitude = entry.place.longitude else { return nil }
            return City(id: entry.place.id, name: name, centre: GeoPoint(latitude: latitude, longitude: longitude), photos: entry.count)
        }
        .sorted { $0.photos == $1.photos ? $0.name < $1.name : $0.photos > $1.photos }
    }
}

// MARK: Chapters page

/// After an import: the places the photos call home, one row each, to say
/// what each one is. "Later" asks again only in Settings.
struct PlaceConfirmSheet: View {
    let places: [FoundPlace]
    /// The roles chosen; `nil` for "Neither".
    let onConfirm: ([(FoundPlace, PlaceRole?)]) -> Void
    let onLater: () -> Void
    @State private var roles: [String: PlaceRole?] = [:]

    private func role(of place: FoundPlace) -> PlaceRole? {
        roles[place.id] ?? place.candidate.suggestedRole
    }

    private var confirmedCount: Int { places.filter { role(of: $0) != nil }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Are these the places you spend your time at?"))
                    .font(.system(size: 20, weight: .medium, design: .serif))
                    .foregroundStyle(Paper.ink)
                Text(String(localized: "Once you confirm, photos taken there are not counted as trips. You can change this in Settings."))
                    .foregroundStyle(Paper.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(places) { place in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(place.name)
                                    .font(.headline)
                                    .foregroundStyle(Paper.ink)
                                Spacer(minLength: 8)
                                Text(place.dateSpan())
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(Paper.muted)
                            }
                            Text(place.detail)
                                .font(.callout)
                                .foregroundStyle(Paper.muted)
                            Picker(String(localized: "\(place.name) is"), selection: Binding(
                                get: { role(of: place) },
                                set: { roles[place.id] = .some($0) }
                            )) {
                                ForEach(PlaceRole.chosen, id: \.self) { Text($0.label).tag(PlaceRole?.some($0)) }
                                Text(String(localized: "Neither")).tag(PlaceRole?.none)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .accessibilityIdentifier("places.confirm.role")
                        }
                        .padding(12)
                        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .frame(maxHeight: 380)
            HStack {
                Spacer()
                Button(String(localized: "Later")) { onLater() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("places.confirm.later")
                Button(confirmedCount == 0 ? String(localized: "Done") : String(localized: "Confirm \(confirmedCount) places")) {
                    onConfirm(places.map { ($0, role(of: $0)) })
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("places.confirm.done")
            }
        }
        .padding(PaperMetrics.sheetInset)
        .frame(width: 560)
        .background(Paper.canvas)
    }
}

/// Above the chapters, when the photos show a new place they call home:
/// is it a new work site, or was it a trip?
struct NewPlaceBanner: View {
    let place: FoundPlace
    let onWork: () -> Void
    let onTrip: () -> Void
    let onLater: () -> Void

    private var weeks: Int {
        max(1, Int((place.candidate.lastDate.timeIntervalSince(place.candidate.firstDate) / (7 * 86_400)).rounded()))
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(Paper.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "You've been in \(place.name) for \(String(localized: "\(weeks) weeks")). Is it a new work site?"))
                    .foregroundStyle(Paper.ink)
                Text(String(localized: "If it is, these weeks stay daily life and are not one long trip."))
                    .font(.callout)
                    .foregroundStyle(Paper.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(String(localized: "Work site"), action: onWork)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("places.banner.work")
            Button(String(localized: "It was a trip"), action: onTrip)
                .accessibilityIdentifier("places.banner.trip")
            Button(action: onLater) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Paper.muted)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Ask me later"))
            .accessibilityLabel(String(localized: "Ask me later"))
            .accessibilityIdentifier("places.banner.later")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Paper.line))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("places.banner")
    }
}

/// What "This is not a trip" turns the trip into.
enum NotTripChoice: Equatable {
    /// The photos go back to daily life; no chapter is left.
    case dailyLife
    /// The chapter stays, as the kind the person typed.
    case custom(String)
}

/// "This is not a trip": daily life, or a chapter of a kind the person
/// names, and whether visits to this place are no trip from now on.
struct NotTripSheet: View {
    let tripName: String
    /// "Oct 10 – 12, 2026 · 86 photos"
    let summary: String
    /// Where the trip was, when its photos have locations.
    let placeName: String?
    let usedTypes: [String]
    let onDone: (NotTripChoice, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isCustom = false
    @State private var label = ""
    @State private var remember = true
    @FocusState private var labelFocused: Bool

    private var typed: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var suggestions: [String] {
        usedTypes.isEmpty ? [String(localized: "Business trip"), String(localized: "Visiting family")] : Array(usedTypes.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "“\(tripName)” is not a trip"))
                    .font(.system(size: 20, weight: .medium, design: .serif))
                    .foregroundStyle(Paper.ink)
                Text(String(localized: "\(summary). Where should they go?"))
                    .foregroundStyle(Paper.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                option(isOn: !isCustom, title: String(localized: "Daily life"), detail: String(localized: "The photos stay in the Library, with no chapter of their own")) {
                    isCustom = false
                }
                .accessibilityIdentifier("trips.nottrip.daily")
                VStack(alignment: .leading, spacing: 8) {
                    option(isOn: isCustom, title: String(localized: "It is…"), detail: String(localized: "Keeps the chapter, as the kind you write, not as a trip")) {
                        isCustom = true
                        labelFocused = true
                    }
                    .accessibilityIdentifier("trips.nottrip.custom")
                    if isCustom {
                        TextField("", text: $label, prompt: Text(String(localized: "Business trip, Site visit, Training…")))
                            .textFieldStyle(.roundedBorder)
                            .focused($labelFocused)
                            .padding(.leading, 30)
                            .accessibilityLabel(String(localized: "Kind of chapter"))
                            .accessibilityIdentifier("trips.nottrip.label")
                        HStack(spacing: 6) {
                            Text(usedTypes.isEmpty ? String(localized: "For example:") : String(localized: "Used before:"))
                                .font(.caption)
                                .foregroundStyle(Paper.muted)
                            FlowChips(suggestions.map { name in
                                FlowChips.Chip(id: name, label: name, symbol: "tag", isOn: typed == name) { label = name }
                            })
                        }
                        .padding(.leading, 30)
                    }
                }
            }
            if let placeName {
                Toggle(isOn: $remember) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "From now on, visits to \(placeName) (within \(Int(TripSegmenter().awayRadiusMeters / 1_000)) km) are no trip"))
                        Text(String(localized: "Listed in Settings › Your places, where you can remove it."))
                            .font(.caption)
                            .foregroundStyle(Paper.muted)
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("trips.nottrip.remember")
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCustom && !typed.isEmpty ? String(localized: "Make it “\(typed)”") : String(localized: "Make it daily life")) {
                    onDone(isCustom ? .custom(typed) : .dailyLife, placeName != nil && remember)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCustom && typed.isEmpty)
                .accessibilityIdentifier("trips.nottrip.done")
            }
        }
        .padding(PaperMetrics.sheetInset)
        .frame(width: 460)
        .background(Paper.canvas)
    }

    private func option(isOn: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isOn ? Paper.accent : Paper.muted)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold).foregroundStyle(Paper.ink)
                    Text(detail).font(.caption).foregroundStyle(Paper.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Paper.raised, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isOn ? Paper.accent : Paper.line, lineWidth: isOn ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
