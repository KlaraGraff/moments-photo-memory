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

/// Place and time under a photo, with the place's description when one was written.
struct PhotoPlaceLine: View {
    @Environment(SelectionModel.self) private var selection
    let item: MediaItem
    let placeNotes: [PlaceNote]
    @State private var showingDescription = false
    @State private var showingDateEditor = false

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
                    // The place goes to the map, the time opens the date editor.
                    if item.latitude != nil {
                        Button { selection.showOnMap(item.id) } label: {
                            Text(name)
                                .foregroundStyle(LibraryPalette.ink)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Show on Map"))
                        .accessibilityIdentifier("library.place.\(item.id)")
                    } else {
                        Text(name)
                            .foregroundStyle(LibraryPalette.ink)
                            .lineLimit(1)
                    }
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
                    }
                    .contextMenu {
                        if AuthorNames.isLocal(memory.authorAccountID) {
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
        let author = AuthorNames.label(isOwn: AuthorNames.isLocal(memory.authorAccountID), myName: myName, partnerName: partnerName)
        switch memory.scope {
        case .trip:
            return "\(author) · \(String(localized: "Whole trip"))"
        case .day, .photo:
            return "\(author) · \(memory.scopeKey)"
        }
    }
}
