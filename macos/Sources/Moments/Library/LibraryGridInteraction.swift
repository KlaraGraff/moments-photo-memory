import AppKit
import SwiftUI

extension View {
    /// Keyboard for a Library-style photo grid: arrow keys move the
    /// selection, Space or Return opens the photo, Esc clears the selection,
    /// Command-A selects all and Delete (or ⌘⌫ without asking) deletes the
    /// selection. Clicks and drags between photos are
    /// `libraryMarqueeSelection`'s.
    func libraryGridInteraction(state: LibraryViewState, proxy: ScrollViewProxy) -> some View {
        modifier(LibraryGridInteraction(state: state, proxy: proxy))
    }

    /// Keeps `state.gridColumns` (for the grid and the up and down arrows)
    /// in step with the chosen photos per row, capped by what the window has
    /// room for. On the scroll view's content, not a section, so it holds
    /// while every heading is scrolled away.
    func reportsLibraryGridColumns(to state: LibraryViewState) -> some View {
        modifier(LibraryGridColumnsReporter(state: state))
    }
}

private struct LibraryGridColumnsReporter: ViewModifier {
    let state: LibraryViewState
    @AppStorage(LibraryThumbnailSize.storageKey) private var chosen = LibraryThumbnailSize.defaultColumns

    func body(content: Content) -> some View {
        let columns = LibraryThumbnailSize.shown(chosen: chosen, windowWidth: state.windowWidth).columns
        content.onChange(of: columns, initial: true) { _, columns in
            if state.gridColumns != columns { state.gridColumns = columns }
        }
    }
}

private struct LibraryGridInteraction: ViewModifier {
    @Environment(SelectionModel.self) private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Environment(\.photoDeletionScope) private var deletionScope
    let state: LibraryViewState
    let proxy: ScrollViewProxy
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onMoveCommand { direction in
                guard selection.viewerRequest == nil else { return }
                move(direction)
            }
            .onExitCommand {
                guard selection.viewerRequest == nil else { return }
                selection.clear()
            }
            .onKeyPress(.space) { openFocused() }
            .onKeyPress(.return) { openFocused() }
            // Delete asks first and ⌘⌫ deletes at once, as in Photos.
            .onKeyPress(keys: [.delete, .deleteForward]) { press in
                deleteSelection(confirm: !press.modifiers.contains(.command))
            }
            // Edit ▸ Delete.
            .onDeleteCommand { _ = deleteSelection(confirm: true) }
            .onReceive(NotificationCenter.default.publisher(for: .momentsDeleteWithoutAsking)) { _ in
                _ = deleteSelection(confirm: false)
            }
            .onCommand(#selector(NSResponder.selectAll(_:))) {
                selection.select(state.orderedItemIDs, focus: selection.focusedItemID)
            }
            // A click on a photo makes the grid the keyboard target; the
            // viewer keeps the keys while it is open.
            .onChange(of: selection.focusedItemID) { _, focused in
                guard focused != nil, selection.viewerRequest == nil, !Self.isEditingText else { return }
                isFocused = true
            }
            .onChange(of: selection.viewerRequest) { _, request in
                // Back from the viewer: keep the photo it showed in view.
                guard request == nil, let focused = selection.focusedItemID else { return }
                proxy.scrollTo("item:\(focused)", anchor: nil)
                isFocused = true
            }
    }

    private static var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    private func move(_ direction: MoveCommandDirection) {
        let mapped: LibraryGridNavigation.Direction
        switch direction {
        case .left: mapped = .left
        case .right: mapped = .right
        case .up: mapped = .up
        case .down: mapped = .down
        @unknown default: return
        }
        guard let next = LibraryGridNavigation.move(
            from: selection.focusedItemID,
            mapped,
            sections: state.gridSections,
            columns: state.gridColumns
        ) else { return }
        selection.select(next)
        selection.anchorItemID = next
        if reduceMotion {
            proxy.scrollTo("item:\(next)", anchor: nil)
        } else {
            withAnimation(.snappy(duration: 0.18)) { proxy.scrollTo("item:\(next)", anchor: nil) }
        }
    }

    private func deleteSelection(confirm: Bool) -> KeyPress.Result {
        guard selection.viewerRequest == nil, selection.pendingDeletion == nil, !Self.isEditingText,
              !selection.selectedItemIDs.isEmpty else { return .ignored }
        let shown = state.orderedItemIDs.filter(selection.selectedItemIDs.contains)
        PhotoDeletion.request(deletionScope(shown), confirm: confirm, selection: selection, context: modelContext, undoManager: undoManager)
        return .handled
    }

    private func openFocused() -> KeyPress.Result {
        guard selection.viewerRequest == nil, let focused = selection.focusedItemID,
              state.orderedItemIDs.contains(focused) else { return .ignored }
        selection.openViewer(focused, in: state.viewerItemIDs)
        return .handled
    }
}

/// The window subtitle: the page's own line, or "216 items selected" while
/// photos are selected, like Photos. A modifier of its own, so the selection
/// changing during a rubber-band drag updates the title bar without
/// rebuilding the page under it.
struct LibrarySelectionSubtitle: ViewModifier {
    @Environment(SelectionModel.self) private var selection
    let idle: String

    func body(content: Content) -> some View {
        let count = selection.selectedItemIDs.count
        content
            .navigationSubtitle(count > 0 ? String(localized: "\(count) items selected") : idle)
            // Tests read the count here; people see it in the title bar.
            .background(alignment: .topLeading) {
                Text(String(count))
                    .font(.system(size: 1))
                    .foregroundStyle(.clear)
                    .allowsHitTesting(false)
                    .accessibilityValue(String(count))
                    .accessibilityIdentifier("library.selectionCount")
            }
    }
}

/// The toolbar's thumbnail size control: − slider +, with ⌘− and ⌘+ like
/// Photos. A wider window has more steps toward small photos.
struct LibraryZoomControl: View {
    @Environment(SelectionModel.self) private var selection
    @AppStorage(LibraryThumbnailSize.storageKey) private var chosen = LibraryThumbnailSize.defaultColumns
    let state: LibraryViewState

    /// While the large viewer is open, ⌘− and ⌘+ zoom the photo instead.
    private func shortcut(_ key: KeyEquivalent) -> KeyboardShortcut? {
        selection.viewerRequest == nil ? KeyboardShortcut(key, modifiers: .command) : nil
    }

    /// The window's steps, smallest photos first, as the slider runs.
    private var steps: [Int] { LibraryThumbnailSize.steps(windowWidth: state.windowWidth).reversed() }

    private var position: Int {
        let shown = LibraryThumbnailSize.shown(chosen: chosen, windowWidth: state.windowWidth).columns
        return steps.firstIndex(of: shown) ?? 0
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { zoom(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut(shortcut("-"))
                .disabled(position <= 0)
                .help(String(localized: "Smaller thumbnails (⌘−)"))
                .accessibilityIdentifier("library.zoom-out")
            Slider(
                value: Binding(get: { Double(position) }, set: { chosen = steps[min(max(Int($0.rounded()), 0), steps.count - 1)] }),
                in: 0...Double(max(steps.count - 1, 1)),
                step: 1
            )
            .frame(width: 90)
            .accessibilityLabel(String(localized: "Thumbnail size"))
            .accessibilityIdentifier("library.zoom")
            Button { zoom(1) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut(shortcut("="))
                .disabled(position >= steps.count - 1)
                .help(String(localized: "Larger thumbnails (⌘+)"))
                .accessibilityIdentifier("library.zoom-in")
        }
        // Keyboards with a "+" key send ⌘+ rather than ⌘=.
        .background {
            Button("") { zoom(1) }
                .keyboardShortcut(shortcut("+"))
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private func zoom(_ step: Int) {
        if let next = LibraryThumbnailSize.zoomed(chosen: chosen, by: step, windowWidth: state.windowWidth) {
            chosen = next
        }
    }
}
