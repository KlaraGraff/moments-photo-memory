import AppKit
import SwiftUI
import SwiftData

/// The ruled line under a photo, edited in place like a caption in Photos:
/// click and type, Return saves, Option-Return starts a new line, Escape
/// cancels, and clicking elsewhere saves. Saving keeps the words and hands
/// them to the AI model, whose result is written right away; `PhotoNoteBadge`
/// opens it for changes or Undo.
struct PhotoNoteSection: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PhotoNoteService.self) private var service
    let item: MediaItem
    let state: LibraryViewState
    /// The large viewer has room for longer words: a box of several lines
    /// instead of the single ruled line under a grid photo.
    var isLarge = false
    @FocusState private var isFocused: Bool
    @State private var savedCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .lineLimit(isLarge ? 6...20 : 1...6)
            .focused($isFocused)
            .modifier(NoteFieldChrome(isLarge: isLarge, isFocused: isFocused, reduceMotion: reduceMotion))
            // Return submits and Option-Return inserts a line break (the
            // vertical field's own behavior), so Return that confirms an input
            // method's candidate never saves half-typed words.
            .onSubmit { save() }
            .onExitCommand {
                // In the viewer's large box Esc only ends typing (the words are
                // kept and saved); under a grid photo it cancels the line.
                if !isLarge { state.noteDrafts[item.id] = nil }
                isFocused = false
            }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    state.focusedNoteItemID = item.id
                } else {
                    if state.focusedNoteItemID == item.id { state.focusedNoteItemID = nil }
                    save()
                }
            }
            // Clicking the sidebar can remove the cell in the same update
            // that ends editing; the words are still saved.
            .onDisappear {
                save()
                if state.focusedNoteItemID == item.id { state.focusedNoteItemID = nil }
            }
            .help(String(localized: "Places, corrections, descriptions, feelings: write anything. Return saves; your words are kept and AI organizes them. Option-Return starts a new line."))
            .accessibilityLabel(String(localized: "Note for this photo"))
            .accessibilityIdentifier("library.note.\(item.id)")
            .overlay(alignment: .trailing) {
                TransientCheckmark(trigger: savedCount, label: String(localized: "Saved"))
                    .allowsHitTesting(false)
            }
    }

    private func save() {
        guard hasDraft, let text = state.noteDrafts[item.id] else { return }
        if service.save(text, for: item, context: modelContext) != nil {
            state.noteDrafts[item.id] = nil
            isFocused = false
            savedCount += 1
        }
    }
}

/// The ruled line under a grid photo, or a soft box in the large viewer.
private struct NoteFieldChrome: ViewModifier {
    let isLarge: Bool
    let isFocused: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if isLarge {
            content
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(LibraryPalette.well.opacity(isFocused ? 0.55 : 0.8), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isFocused ? LibraryPalette.muted.opacity(0.45) : LibraryPalette.rule.opacity(0.6))
                )
                .shadow(color: Paper.shadow.opacity(isFocused ? 0.08 : 0), radius: 6, y: 1)
                .animation(Motion.animation(Motion.settle, reduceMotion: reduceMotion), value: isFocused)
        } else {
            content
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    // Focus deepens the ruled line instead of switching to a bright one.
                    Rectangle()
                        .fill(isFocused ? LibraryPalette.muted.opacity(0.7) : LibraryPalette.rule)
                        .frame(height: isFocused ? 1.5 : 1)
                        .animation(Motion.animation(Motion.settle, reduceMotion: reduceMotion), value: isFocused)
                }
        }
    }
}

/// A small mark at the end of the place line once a photo has notes: a spinner
/// while organizing, a sparkle once the AI's result is written, suggestions
/// waiting after an undo, or a warning. Clicking it opens the details in a
/// popover, so the grid cell never grows around them.
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
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ProgressView().controlSize(.mini)
                    .inlineIcon()
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
        } else if notes.contains(where: { $0.status == .done && !$0.undoRecord.isEmpty }) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(LibraryPalette.accent)
                .accessibilityLabel(String(localized: "Notes on this photo"))
        } else {
            Image(systemName: "text.bubble")
                .font(.caption)
                .foregroundStyle(LibraryPalette.muted)
                .accessibilityLabel(String(localized: "Notes on this photo"))
        }
    }
}

/// The popover behind `PhotoNoteBadge`: anything still open, what each note
/// wrote (editable, with Undo), then every note's original words.
struct PhotoNoteDetails: View {
    let item: MediaItem
    let notes: [PhotoNote]
    /// Shown in the viewer's column rather than in a popover.
    var isInline = false
    var close: (() -> Void)?

    private var openNotes: [PhotoNote] {
        let open: Set<PhotoNoteStatus> = [.organizing, .ready, .waiting, .failed]
        return notes.filter { open.contains($0.status) }
    }

    private var writtenNotes: [PhotoNote] {
        notes.filter { $0.status == .done && $0.suggestions.contains { $0.decision == .accepted } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(openNotes, id: \.id) { note in
                PhotoNoteStatusView(note: note, item: item, close: close)
            }
            ForEach(writtenNotes.reversed(), id: \.id) { note in
                WrittenNoteView(note: note, item: item)
            }
            Text(String(localized: "Original words"))
                .font(.caption.weight(.medium))
                .foregroundStyle(LibraryPalette.muted)
                // Space, not a rule, sets the original words apart.
                .padding(.top, openNotes.isEmpty && writtenNotes.isEmpty ? 0 : 6)
            ForEach(notes.reversed(), id: \.id) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.text)
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(LibraryPalette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(LibraryPalette.muted)
                        if note.status == .nothingFound {
                            Text(String(localized: "Nothing to organize"))
                                .font(.caption2)
                                .foregroundStyle(LibraryPalette.muted)
                        }
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(LibraryPalette.rule).frame(width: 2) }
            }
        }
        .padding(isInline ? 0 : 16)
        .frame(width: isInline ? nil : 360, alignment: .leading)
        .frame(maxWidth: isInline ? .infinity : nil, alignment: .leading)
        .background(isInline ? Color.clear : LibraryPalette.content)
    }
}

/// The AI's result and the original words under the viewer's note box.
struct PhotoNoteResults: View {
    let item: MediaItem
    @Query private var notes: [PhotoNote]

    init(item: MediaItem) {
        self.item = item
        let mediaID = item.id
        _notes = Query(filter: #Predicate<PhotoNote> { $0.mediaID == mediaID }, sort: \PhotoNote.createdAt)
    }

    var body: some View {
        if !notes.isEmpty {
            PhotoNoteDetails(item: item, notes: notes, isInline: true)
        }
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
    let close: (() -> Void)?

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
                .simultaneousGesture(TapGesture().onEnded { SettingsTab.select(.aiModel) })
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                        .background(LibraryPalette.well, in: Capsule())
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
                if let close {
                    Button(String(localized: "Later")) { close() }
                        .controlSize(.small)
                }
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
            Text(NoteSuggestionContent.title(for: suggestion))
                .font(.caption)
                .foregroundStyle(LibraryPalette.accent)

            if isEditing {
                TextField("", text: $editedText, axis: .vertical)
                    .textFieldStyle(.paper)
                    .lineLimit(1...6)
            } else {
                NoteSuggestionContent(suggestion: suggestion, reveal: Date.now.timeIntervalSince(note.updatedAt) < 8)
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
        .paperCard(cornerRadius: 8, padding: 10)
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

/// What a suggestion says, shared by the pending card and the written list.
/// Words the AI has just written come in with the ink reveal.
private struct NoteSuggestionContent: View {
    let suggestion: NoteSuggestion
    var reveal = false
    /// Decided once when the text first shows, so the person's own later
    /// edits or toggles never replay it as if the AI had just written it.
    @State private var revealsOnAppear: Bool?

    static func title(for suggestion: NoteSuggestion) -> String {
        switch suggestion.kind {
        case .placeCorrection: return String(localized: "Place correction")
        case .placeDescription: return String(localized: "About \(suggestion.placeName ?? "")")
        case .memory: return String(localized: "Memory")
        }
    }

    var body: some View {
        switch suggestion.kind {
        case .placeCorrection:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let previous = suggestion.previousPlaceName {
                    Text(previous)
                        .strikethrough()
                        .foregroundStyle(LibraryPalette.muted)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(LibraryPalette.muted)
                        .accessibilityHidden(true)
                }
                written
                    .foregroundStyle(LibraryPalette.ink)
            }
            .font(.system(.body, design: .serif))
        case .placeDescription, .memory:
            written
                .font(.system(.body, design: .serif))
                .foregroundStyle(LibraryPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var written: some View {
        Group {
            if revealsOnAppear ?? reveal {
                InkRevealText(text: suggestion.text)
            } else {
                Text(suggestion.text)
            }
        }
        .onAppear { if revealsOnAppear == nil { revealsOnAppear = reveal } }
    }
}

/// One note whose suggestions were written: what changed, each item can be
/// changed in place, and Undo takes the whole note back.
private struct WrittenNoteView: View {
    @Environment(\.modelContext) private var modelContext
    let note: PhotoNote
    let item: MediaItem

    private var written: [NoteSuggestion] {
        note.suggestions.filter { $0.decision == .accepted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(String(localized: "Organized and saved"), systemImage: "sparkles")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LibraryPalette.ink)
                Spacer(minLength: 4)
                if let label = note.organizerLabel {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(LibraryPalette.muted)
                }
                Button(String(localized: "Undo")) {
                    try? NoteApplier.undo(note, context: modelContext)
                    try? modelContext.save()
                }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityIdentifier("library.note.undo.\(note.id)")
            }
            ForEach(written) { suggestion in
                WrittenSuggestionRow(note: note, item: item, suggestion: suggestion)
            }
        }
    }
}

private struct WrittenSuggestionRow: View {
    @Environment(\.modelContext) private var modelContext
    let note: PhotoNote
    let item: MediaItem
    let suggestion: NoteSuggestion
    @State private var isEditing = false
    @State private var editedText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(NoteSuggestionContent.title(for: suggestion))
                    .font(.caption)
                    .foregroundStyle(LibraryPalette.accent)
                if suggestion.kind == .placeCorrection, suggestion.applyToNearby, !suggestion.nearbyMediaIDs.isEmpty {
                    Text(String(localized: "also \(suggestion.nearbyMediaIDs.count) photos nearby"))
                        .font(.caption)
                        .foregroundStyle(LibraryPalette.muted)
                }
                Spacer(minLength: 4)
                if !isEditing {
                    Button(String(localized: "Edit")) {
                        editedText = suggestion.text
                        isEditing = true
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            if isEditing {
                TextField("", text: $editedText, axis: .vertical)
                    .textFieldStyle(.paper)
                    .lineLimit(1...6)
                    .onSubmit { commit() }
                    .onExitCommand { isEditing = false }
                HStack {
                    Spacer()
                    Button(String(localized: "Cancel")) { isEditing = false }
                        .controlSize(.small)
                    Button(String(localized: "Done")) { commit() }
                        .controlSize(.small)
                }
            } else {
                NoteSuggestionContent(suggestion: suggestion, reveal: Date.now.timeIntervalSince(note.updatedAt) < 8)
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) { Rectangle().fill(LibraryPalette.accent.opacity(0.5)).frame(width: 2) }
    }

    private func commit() {
        let text = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        guard !text.isEmpty, text != suggestion.text else { return }
        try? NoteApplier.revise(suggestion.id, of: note, to: text, item: item, context: modelContext)
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
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
                        .background(Capsule().fill(LibraryPalette.well))
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
