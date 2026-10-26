import AppKit
import SwiftUI
import SwiftData

/// The ruled line under a photo, edited in place like a caption in Photos:
/// click and type, Return saves, Option-Return starts a new line, Escape
/// cancels, and clicking elsewhere saves. Saving keeps the words and hands
/// them to the AI model; its suggestions wait behind `PhotoNoteBadge`.
struct PhotoNoteSection: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PhotoNoteService.self) private var service
    let item: MediaItem
    let state: LibraryViewState
    @FocusState private var isFocused: Bool

    private var draft: Binding<String> {
        Binding(
            get: { state.noteDrafts[item.id] ?? "" },
            set: { state.noteDrafts[item.id] = $0.isEmpty ? nil : $0 }
        )
    }

    private var hasDraft: Bool {
        !(state.noteDrafts[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        TextField("", text: draft, prompt: Text(String(localized: "Add a note…")), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(.body, design: .serif))
            .foregroundStyle(LibraryPalette.ink)
            .lineLimit(1...6)
            .focused($isFocused)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isFocused ? LibraryPalette.accent : LibraryPalette.rule)
                    .frame(height: isFocused ? 1.5 : 1)
            }
            // Return submits and Option-Return inserts a line break (the
            // vertical field's own behavior), so Return that confirms an input
            // method's candidate never saves half-typed words.
            .onSubmit { save() }
            .onExitCommand {
                state.noteDrafts[item.id] = nil
                isFocused = false
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { save() }
            }
            // Clicking the sidebar can remove the cell in the same update
            // that ends editing; the words are still saved.
            .onDisappear { save() }
            .help(String(localized: "Places, corrections, descriptions, feelings: write anything. Return saves; your words are kept and AI organizes them. Option-Return starts a new line."))
            .accessibilityLabel(String(localized: "Note for this photo"))
            .accessibilityIdentifier("library.note.\(item.id)")
    }

    private func save() {
        guard hasDraft, let text = state.noteDrafts[item.id] else { return }
        if service.save(text, for: item, context: modelContext) != nil {
            state.noteDrafts[item.id] = nil
            isFocused = false
        }
    }
}

/// A small mark at the end of the place line once a photo has notes: a spinner
/// while organizing, the number of suggestions waiting, or a warning. Clicking
/// it opens the suggestions and the original words in a popover, so the grid
/// cell never grows around them.
struct PhotoNoteBadge: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PhotoNoteService.self) private var service
    let item: MediaItem
    @Query private var notes: [PhotoNote]
    @State private var showingDetails = false

    init(item: MediaItem) {
        self.item = item
        let mediaID = item.id
        _notes = Query(filter: #Predicate<PhotoNote> { $0.mediaID == mediaID }, sort: \PhotoNote.createdAt)
    }

    private var pendingCount: Int {
        notes.filter { $0.status == .ready }
            .reduce(0) { $0 + $1.suggestions.filter { $0.decision == .pending }.count }
    }

    private var isOrganizing: Bool {
        notes.contains { service.isRunning($0) }
    }

    private var needsAttention: Bool {
        notes.contains { $0.status == .failed || $0.status == .waiting || ($0.status == .organizing && !service.isRunning($0)) }
    }

    var body: some View {
        if !notes.isEmpty {
            Button {
                showingDetails.toggle()
            } label: {
                label
            }
            .buttonStyle(.plain)
            .help(String(localized: "Notes on this photo"))
            .accessibilityIdentifier("library.note.badge.\(item.id)")
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                PhotoNoteDetails(item: item, notes: notes) { showingDetails = false }
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        if isOrganizing {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(String(localized: "Organizing…"))
            }
            .font(.caption)
            .foregroundStyle(LibraryPalette.muted)
        } else if pendingCount > 0 {
            Label(String(localized: "\(pendingCount) suggestions"), systemImage: "sparkles")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(LibraryPalette.accent))
        } else if needsAttention {
            Image(systemName: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(LibraryPalette.accent)
                .accessibilityLabel(String(localized: "Not organized yet"))
        } else {
            Image(systemName: "text.bubble")
                .font(.caption)
                .foregroundStyle(LibraryPalette.muted)
                .accessibilityLabel(String(localized: "Notes on this photo"))
        }
    }
}

/// The popover behind `PhotoNoteBadge`: open suggestions, then every note's
/// original words with Undo for what it wrote.
private struct PhotoNoteDetails: View {
    @Environment(\.modelContext) private var modelContext
    let item: MediaItem
    let notes: [PhotoNote]
    let close: () -> Void

    private var openNotes: [PhotoNote] {
        let open: Set<PhotoNoteStatus> = [.organizing, .ready, .waiting, .failed]
        return notes.filter { open.contains($0.status) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(openNotes, id: \.id) { note in
                PhotoNoteStatusView(note: note, item: item, close: close)
            }
            if !openNotes.isEmpty {
                Divider()
            }
            Text(String(localized: "Original words"))
                .font(.caption.weight(.medium))
                .foregroundStyle(LibraryPalette.muted)
            ForEach(notes.reversed(), id: \.id) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.text)
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(LibraryPalette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(LibraryPalette.muted)
                        if note.status == .nothingFound {
                            Text(String(localized: "Nothing to organize"))
                                .font(.caption2)
                                .foregroundStyle(LibraryPalette.muted)
                        }
                        if !note.undoRecord.isEmpty {
                            Button(String(localized: "Undo")) {
                                try? NoteApplier.undo(note, context: modelContext)
                                try? modelContext.save()
                            }
                            .buttonStyle(.link)
                            .font(.caption2)
                            .accessibilityIdentifier("library.note.undo.\(note.id)")
                        }
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(LibraryPalette.rule).frame(width: 2) }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .background(LibraryPalette.content)
    }
}

extension View {
    /// Clicking anywhere that isn't a text field ends text editing, as in
    /// other Mac apps; SwiftUI otherwise keeps a field focused until the
    /// person clicks another field.
    func endsTextEditingOnOutsideClick() -> some View {
        modifier(EndTextEditingOnOutsideClick())
    }
}

private struct EndTextEditingOnOutsideClick: ViewModifier {
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                    // Local monitors run on the main thread.
                    MainActor.assumeIsolated {
                        guard let window = event.window,
                              window.firstResponder is NSTextView,
                              let frameView = window.contentView?.superview else { return }
                        let hit = frameView.hitTest(event.locationInWindow)
                        if !(hit is NSTextView || hit is NSTextField) {
                            window.makeFirstResponder(nil)
                        }
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
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
    let close: () -> Void

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
            suggestionsPanel
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
                if !note.undoRecord.isEmpty {
                    Button(String(localized: "Undo")) {
                        try? NoteApplier.undo(note, context: modelContext)
                        try? modelContext.save()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
                Button(String(localized: "Later")) { close() }
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
        guard let name = item.namedPlace else { return nil }
        let key = PlaceNote.key(for: name)
        let texts = placeNotes.filter { $0.placeKey == key }.map(\.text).filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private var correctedFrom: String? {
        guard let override = item.placeOverrideName?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty,
              let original = item.place.flatMap(PlaceDisplayName.resolvedName(of:)), original != override else { return nil }
        return original
    }

    var body: some View {
        if item.namedPlace != nil || item.effectiveCaptureDate != nil {
            HStack(spacing: 6) {
                if let name = item.namedPlace {
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
