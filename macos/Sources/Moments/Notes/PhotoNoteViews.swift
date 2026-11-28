import AppKit
import SwiftUI
import SwiftData

/// A memory's field: the ruled line under a grid photo, or a soft box in
/// the large viewer.
struct MemoryFieldChrome: ViewModifier {
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

/// Shown at a memory field's corner while a model reads the words just written.
struct AIOrganizingMark: View {
    var body: some View {
        Label(String(localized: "AI is organizing…"), systemImage: "sparkles")
            .font(.caption2)
            .foregroundStyle(LibraryPalette.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(LibraryPalette.well))
            .transition(.opacity)
    }
}

/// What AI added, marked as such, with a way to take it back.
struct AIAddedMark: View {
    var text: String?
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .accessibilityLabel(Text(verbatim: "AI"))
            if let text {
                Text(text).lineLimit(1)
            }
            Button(String(localized: "Undo"), action: undo)
                .buttonStyle(.plain)
                .underline()
                .help(String(localized: "Take back what AI added from this memory"))
        }
        .font(.caption)
        .foregroundStyle(LibraryPalette.muted)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(LibraryPalette.well))
    }
}

/// Place and time under a photo, with the place's description when one was written.
struct PhotoPlaceLine: View {
    @Environment(SelectionModel.self) private var selection
    @Environment(LibraryStore.self) private var store
    @Environment(PhotoNoteService.self) private var notes
    @Environment(\.modelContext) private var modelContext
    let item: MediaItem
    let placeNotes: [PlaceNote]
    @State private var showingDescription = false
    @State private var showingDateEditor = false

    private var describing: [PlaceNote] {
        guard let name = item.namedPlace else { return [] }
        let key = PlaceNote.key(for: name)
        return placeNotes.filter { $0.placeKey == key && !$0.text.isEmpty }
    }

    private var description: String? {
        let texts = describing.map(\.text)
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// The note whose AI pass wrote this description, to undo it.
    private var describedByNoteID: String? {
        describing.filter { AuthorNames.isLocal($0.authorAccountID) }.compactMap(\.sourceNoteID).last
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
                    // The place shows the photos taken there, the time opens
                    // the date editor.
                    Button { PlaceClue.showPhotos(at: name, store: store, selection: selection) } label: {
                        Text(name)
                            .foregroundStyle(LibraryPalette.ink)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Photos taken here"))
                    .accessibilityIdentifier("library.place.\(item.id)")
                }
                if let time = item.effectiveCaptureDate.map({ PhotoDateEditor.timeText($0, in: item.captureTimeZone) }) {
                    Button {
                        showingDateEditor = true
                    } label: {
                        Text(time)
                            .foregroundStyle(LibraryPalette.muted)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Adjust date and time"))
                    .accessibilityIdentifier("library.time.\(item.id)")
                    .popover(isPresented: $showingDateEditor, arrowEdge: .bottom) {
                        PhotoDateEditor(items: [item]) { showingDateEditor = false }
                    }
                }
                if let correctedFrom, let fix = notes.placeFix(for: item) {
                    AIAddedMark(text: String(localized: "AI · was \(correctedFrom)")) {
                        notes.undo(noteID: fix.noteID, context: modelContext)
                    }
                    .accessibilityIdentifier("library.place.ai.\(item.id)")
                } else if let correctedFrom {
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
                        VStack(alignment: .leading, spacing: 10) {
                            Text(description)
                                .font(.system(.body, design: .serif))
                                .fixedSize(horizontal: false, vertical: true)
                            if let noteID = describedByNoteID {
                                AIAddedMark {
                                    showingDescription = false
                                    notes.undo(noteID: noteID, context: modelContext)
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: 320, alignment: .leading)
                    }
                }
            }
            .font(.caption)
        }
    }
}

/// Day and trip memories, shown under a Library section's title: written
/// by hand, or by AI from what a photo's memory said about the day or trip.
struct CollectionMemoryLines: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PhotoNoteService.self) private var notes
    @AppStorage(AuthorNames.myNameKey) private var myName = ""
    @AppStorage(AuthorNames.partnerNameKey) private var partnerName = ""
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
                        // Put here by AI from a photo's memory.
                        if let noteID = memory.sourceNoteID, AuthorNames.isLocal(memory.authorAccountID) {
                            AIAddedMark {
                                notes.undo(noteID: noteID, context: modelContext)
                            }
                        }
                    }
                    .contextMenu {
                        if AuthorNames.isLocal(memory.authorAccountID) {
                            Button(String(localized: "Delete"), role: .destructive) {
                                modelContext.delete(memory)
                                modelContext.saveOrReport()
                            }
                        }
                    }
                }
            }
        }
    }

    private func label(for memory: CollectionMemory) -> String {
        let author = AuthorNames.label(isOwn: AuthorNames.isLocal(memory.authorAccountID), myName: myName, partnerName: partnerName)
        switch memory.scope {
        case .trip:
            return "\(author) · \(String(localized: "Whole trip"))"
        case .day, .photo:
            return "\(author) · \(memory.scopeKey)"
        }
    }
}
