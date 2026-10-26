import SwiftUI
import SwiftData

/// The ruled line under a photo: type anything, press Save, and the words are
/// kept and handed to the AI model. Its suggestions appear right here, under
/// the same photo, and nothing is written until the person accepts it.
struct PhotoNoteSection: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PhotoNoteService.self) private var service
    let item: MediaItem
    let state: LibraryViewState
    @Query private var notes: [PhotoNote]
    @FocusState private var isFocused: Bool
    @State private var showingOriginals = false

    init(item: MediaItem, state: LibraryViewState) {
        self.item = item
        self.state = state
        let mediaID = item.id
        _notes = Query(filter: #Predicate<PhotoNote> { $0.mediaID == mediaID }, sort: \PhotoNote.createdAt)
    }

    private var draft: Binding<String> {
        Binding(
            get: { state.noteDrafts[item.id] ?? "" },
            set: { state.noteDrafts[item.id] = $0.isEmpty ? nil : $0 }
        )
    }

    private var hasDraft: Bool {
        !(state.noteDrafts[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Notes that still need something: suggestions to decide, or organizing
    /// that is running, waiting or failed.
    private var openNotes: [PhotoNote] {
        let open: Set<PhotoNoteStatus> = [.organizing, .ready, .waiting, .failed]
        return notes.filter { open.contains($0.status) }
    }

    private var latestClosedNote: PhotoNote? {
        guard let latest = notes.last, latest.status == .done || latest.status == .nothingFound else { return nil }
        return latest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(openNotes, id: \.id) { note in
                PhotoNoteStatusView(note: note, item: item, state: state)
            }
            if let note = latestClosedNote {
                closedNoteLine(note)
            }
            composer
            if showingOriginals {
                originals
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .serif))
                .foregroundStyle(LibraryPalette.ink)
                .lineLimit(1...8)
                .focused($isFocused)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isFocused ? LibraryPalette.accent : LibraryPalette.rule)
                        .frame(height: isFocused ? 1.5 : 1)
                }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    save()
                    return .handled
                }
                .accessibilityLabel(String(localized: "Note for this photo"))
                .accessibilityIdentifier("library.note.\(item.id)")

            if isFocused || hasDraft {
                HStack(spacing: 10) {
                    Text(String(localized: "Places, corrections, descriptions, feelings: write anything. Your words are kept and AI organizes them."))
                        .font(.caption)
                        .foregroundStyle(LibraryPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(String(localized: "Save")) { save() }
                        .buttonStyle(.borderedProminent)
                        .tint(LibraryPalette.accent)
                        .controlSize(.small)
                        .disabled(!hasDraft)
                        .help(String(localized: "Save (⌘↩)"))
                        .accessibilityIdentifier("library.note.save.\(item.id)")
                }
            }

            if !notes.isEmpty {
                Button(showingOriginals ? String(localized: "Hide original words") : String(localized: "Original words (\(notes.count))")) {
                    showingOriginals.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
                .foregroundStyle(LibraryPalette.muted)
            }
        }
    }

    private var originals: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(notes.reversed(), id: \.id) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.text)
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(LibraryPalette.ink)
                        .textSelection(.enabled)
                    Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(LibraryPalette.muted)
                }
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) { Rectangle().fill(LibraryPalette.rule).frame(width: 2) }
    }

    @ViewBuilder
    private func closedNoteLine(_ note: PhotoNote) -> some View {
        let record = note.undoRecord
        if note.status == .nothingFound {
            Text(String(localized: "Saved. There was nothing to organize, so only your words were kept."))
                .font(.caption)
                .foregroundStyle(LibraryPalette.muted)
        } else if !record.isEmpty {
            HStack(spacing: 8) {
                Text(String(localized: "Written from your note."))
                    .font(.caption)
                    .foregroundStyle(LibraryPalette.muted)
                Button(String(localized: "Undo")) {
                    try? NoteApplier.undo(note, context: modelContext)
                    try? modelContext.save()
                }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityIdentifier("library.note.undo.\(item.id)")
            }
        }
    }

    private func save() {
        guard hasDraft, let text = state.noteDrafts[item.id] else { return }
        if service.save(text, for: item, context: modelContext) != nil {
            state.noteDrafts[item.id] = nil
            isFocused = false
        }
    }
}

/// One note's state under the photo: organizing, the suggestions, or why it
/// could not be organized yet.
private struct PhotoNoteStatusView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PhotoNoteService.self) private var service
    let note: PhotoNote
    let item: MediaItem
    let state: LibraryViewState

    var body: some View {
        switch note.status {
        case .organizing where service.isRunning(note):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Your words are saved. Organizing…"))
                    .font(.caption)
                    .foregroundStyle(LibraryPalette.muted)
            }
        case .ready:
            if state.collapsedNoteIDs.contains(note.id) {
                Button(String(localized: "\(pendingCount) suggestions waiting")) {
                    state.collapsedNoteIDs.remove(note.id)
                }
                .buttonStyle(.link)
                .font(.caption)
                .foregroundStyle(LibraryPalette.accent)
            } else {
                suggestionsPanel
            }
        default:
            notOrganized
        }
    }

    private var pendingCount: Int {
        note.suggestions.filter { $0.decision == .pending }.count
    }

    private var notOrganized: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(reason)
                .font(.caption)
                .foregroundStyle(LibraryPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(String(localized: "Try again")) {
                    Task { await service.organize(note, item: item, context: modelContext) }
                }
                .buttonStyle(.link)
                .font(.caption)
                SettingsLink {
                    Text(String(localized: "AI model settings"))
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    private var reason: String {
        let saved = String(localized: "Your words are saved.")
        switch note.status {
        case .failed:
            return "\(saved) \(String(localized: "Organizing failed:")) \(note.failureReason ?? "")"
        case .waiting:
            return "\(saved) \(note.failureReason ?? String(localized: "No AI model is available right now."))"
        default:
            return "\(saved) \(String(localized: "Organizing was interrupted."))"
        }
    }

    private var suggestionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(String(localized: "Organized into \(pendingCount) items. Nothing is written until you choose."))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LibraryPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let label = note.organizerLabel {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(LibraryPalette.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay(Capsule().stroke(LibraryPalette.rule))
                }
            }
            ForEach(note.suggestions.filter { $0.decision == .pending }) { suggestion in
                NoteSuggestionCard(note: note, item: item, suggestion: suggestion)
            }
            HStack(spacing: 10) {
                Text(String(localized: "Your original words are saved under this photo."))
                    .font(.caption)
                    .foregroundStyle(LibraryPalette.muted)
                Spacer(minLength: 4)
                Button(String(localized: "Later")) {
                    state.collapsedNoteIDs.insert(note.id)
                }
                .controlSize(.small)
                Button(String(localized: "Use all")) {
                    let ids = Set(note.suggestions.filter { $0.decision == .pending }.map(\.id))
                    _ = try? NoteApplier.accept(ids, of: note, item: item, context: modelContext)
                    try? modelContext.save()
                }
                .buttonStyle(.borderedProminent)
                .tint(LibraryPalette.accent)
                .controlSize(.small)
                .accessibilityIdentifier("library.note.useAll.\(item.id)")
            }
        }
    }
}

private struct NoteSuggestionCard: View {
    @Environment(\.modelContext) private var modelContext
    let note: PhotoNote
    let item: MediaItem
    let suggestion: NoteSuggestion
    @State private var isEditing = false
    @State private var editedText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption)
                .foregroundStyle(LibraryPalette.accent)

            if isEditing {
                TextField("", text: $editedText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
            } else {
                content
            }

            if suggestion.kind == .placeCorrection, !suggestion.nearbyMediaIDs.isEmpty {
                Toggle(String(localized: "Also change the \(suggestion.nearbyMediaIDs.count) photos taken nearby at the same time"), isOn: Binding(
                    get: { suggestion.applyToNearby },
                    set: { value in update { $0.applyToNearby = value } }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(LibraryPalette.muted)
            }

            if suggestion.kind == .memory {
                Picker(String(localized: "Write to"), selection: Binding(
                    get: { suggestion.scope ?? .photo },
                    set: { value in update { $0.scope = value } }
                )) {
                    Text(String(localized: "This photo")).tag(NoteMemoryScope.photo)
                    if item.effectiveCaptureDate != nil {
                        Text(String(localized: "This day")).tag(NoteMemoryScope.day)
                    }
                    if item.tripID != nil {
                        Text(String(localized: "Whole trip")).tag(NoteMemoryScope.trip)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
            }

            if suggestion.kind == .placeDescription {
                Text(String(localized: "Shown with this place wherever it appears."))
                    .font(.caption)
                    .foregroundStyle(LibraryPalette.muted)
            }

            HStack(spacing: 8) {
                Spacer()
                if isEditing {
                    Button(String(localized: "Cancel")) { isEditing = false }
                        .controlSize(.small)
                    Button(String(localized: "Done")) {
                        let text = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { update { $0.text = text } }
                        isEditing = false
                    }
                    .controlSize(.small)
                } else {
                    Button(String(localized: "Skip")) {
                        NoteApplier.reject(suggestion.id, of: note)
                        try? modelContext.save()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    Button(String(localized: "Edit")) {
                        editedText = suggestion.text
                        isEditing = true
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    Button(String(localized: "Use")) {
                        _ = try? NoteApplier.accept([suggestion.id], of: note, item: item, context: modelContext)
                        try? modelContext.save()
                    }
                    .buttonStyle(.bordered)
                    .tint(LibraryPalette.accent)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.7))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(LibraryPalette.line))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var title: String {
        switch suggestion.kind {
        case .placeCorrection: return String(localized: "Place correction")
        case .placeDescription: return String(localized: "About \(suggestion.placeName ?? "")")
        case .memory: return String(localized: "Memory")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch suggestion.kind {
        case .placeCorrection:
            HStack(spacing: 8) {
                if let previous = suggestion.previousPlaceName {
                    Text(previous)
                        .strikethrough()
                        .foregroundStyle(LibraryPalette.muted)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(LibraryPalette.muted)
                        .accessibilityHidden(true)
                }
                Text(suggestion.text)
                    .foregroundStyle(LibraryPalette.ink)
            }
            .font(.system(.body, design: .serif))
        case .placeDescription, .memory:
            Text(suggestion.text)
                .font(.system(.body, design: .serif))
                .foregroundStyle(LibraryPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func update(_ change: (inout NoteSuggestion) -> Void) {
        var suggestions = note.suggestions
        guard let index = suggestions.firstIndex(where: { $0.id == suggestion.id }) else { return }
        change(&suggestions[index])
        note.suggestions = suggestions
        note.updatedAt = .now
        try? modelContext.save()
    }
}

/// Place and time under a photo, with the place's description when one was written.
struct PhotoPlaceLine: View {
    let item: MediaItem
    let placeNotes: [PlaceNote]
    @State private var showingDescription = false

    private var description: String? {
        guard let name = item.effectivePlaceName else { return nil }
        let key = PlaceNote.key(for: name)
        let texts = placeNotes.filter { $0.placeKey == key }.map(\.text).filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private var correctedFrom: String? {
        guard let override = item.placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty,
              let original = item.place?.name, original != override else { return nil }
        return original
    }

    var body: some View {
        if item.effectivePlaceName != nil || item.effectiveCaptureDate != nil {
            HStack(spacing: 6) {
                if let name = item.effectivePlaceName {
                    Text(name)
                        .foregroundStyle(LibraryPalette.ink)
                        .lineLimit(1)
                }
                if let time = item.effectiveCaptureDate?.formatted(date: .omitted, time: .shortened) {
                    Text(time)
                        .foregroundStyle(LibraryPalette.muted)
                }
                if let correctedFrom {
                    Text(String(localized: "Corrected, was \(correctedFrom)"))
                        .foregroundStyle(LibraryPalette.muted)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(LibraryPalette.line.opacity(0.7)))
                }
                if let description {
                    Button {
                        showingDescription.toggle()
                    } label: {
                        Image(systemName: "text.quote")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(LibraryPalette.accent)
                    .accessibilityLabel(String(localized: "About this place"))
                    .popover(isPresented: $showingDescription) {
                        Text(description)
                            .font(.system(.body, design: .serif))
                            .padding(14)
                            .frame(maxWidth: 320, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.caption)
        }
    }
}

/// Day and trip memories written from notes, shown under a Library section's title.
struct CollectionMemoryLines: View {
    @Environment(\.modelContext) private var modelContext
    let memories: [CollectionMemory]

    var body: some View {
        if !memories.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(memories, id: \.id) { memory in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(memory.text)
                            .font(.system(.body, design: .serif))
                            .foregroundStyle(LibraryPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: "— \(label(for: memory))")
                            .font(.caption)
                            .foregroundStyle(LibraryPalette.accent)
                    }
                    .contextMenu {
                        if memory.authorAccountID == MomentsAccount.localID {
                            Button(String(localized: "Delete"), role: .destructive) {
                                modelContext.delete(memory)
                                try? modelContext.save()
                            }
                        }
                    }
                }
            }
        }
    }

    private func label(for memory: CollectionMemory) -> String {
        let author = memory.authorAccountID == MomentsAccount.localID ? String(localized: "Me") : String(localized: "Partner")
        switch memory.scope {
        case .trip:
            return "\(author) · \(String(localized: "Whole trip"))"
        case .day, .photo:
            return "\(author) · \(memory.scopeKey)"
        }
    }
}
