import AppKit
import SwiftUI

extension View {
    /// Keyboard and background clicks for a Library-style photo grid: arrow
    /// keys move the selection, Space or Return opens the photo, Esc clears
    /// the selection, Command-A selects all and a click between photos
    /// deselects everything.
    func libraryGridInteraction(state: LibraryViewState, proxy: ScrollViewProxy) -> some View {
        modifier(LibraryGridInteraction(state: state, proxy: proxy))
    }

    /// A click on the grid's background, between photos, deselects all.
    func deselectsOnBackgroundClick(_ selection: SelectionModel) -> some View {
        background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { selection.clear() }
                .accessibilityHidden(true)
        }
    }

    /// Keeps `state.gridColumns` (for the up and down arrows) in step with
    /// the window width and zoom level. On the scroll view's content, not a
    /// section, so it holds while every heading is scrolled away.
    func reportsLibraryGridColumns(to state: LibraryViewState) -> some View {
        modifier(LibraryGridColumnsReporter(state: state))
    }
}

private struct LibraryGridColumnsReporter: ViewModifier {
    let state: LibraryViewState
    @AppStorage(LibraryThumbnailSize.storageKey) private var level = LibraryThumbnailSize.defaultLevel

    func body(content: Content) -> some View {
        let size = LibraryThumbnailSize(level: level)
        let columns = LibraryGridNavigation.columns(windowWidth: state.windowWidth, minimum: size.minimumWidth, spacing: size.spacing)
        content.onChange(of: columns, initial: true) { _, columns in
            if state.gridColumns != columns { state.gridColumns = columns }
        }
    }
}

private struct LibraryGridInteraction: ViewModifier {
    @Environment(SelectionModel.self) private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    private func openFocused() -> KeyPress.Result {
        guard selection.viewerRequest == nil, let focused = selection.focusedItemID,
              state.orderedItemIDs.contains(focused) else { return .ignored }
        selection.openViewer(focused, in: state.viewerItemIDs)
        return .handled
    }
}

/// The toolbar's thumbnail size control: − slider +, with ⌘− and ⌘+ like Photos.
struct LibraryZoomControl: View {
    @Environment(SelectionModel.self) private var selection
    @AppStorage(LibraryThumbnailSize.storageKey) private var level = LibraryThumbnailSize.defaultLevel

    /// While the large viewer is open, ⌘− and ⌘+ zoom the photo instead.
    private func shortcut(_ key: KeyEquivalent) -> KeyboardShortcut? {
        selection.viewerRequest == nil ? KeyboardShortcut(key, modifiers: .command) : nil
    }

    private var maximum: Int { LibraryThumbnailSize.maximumLevel }

    var body: some View {
        HStack(spacing: 6) {
            Button { zoom(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut(shortcut("-"))
                .disabled(level <= 0)
                .help(String(localized: "Smaller thumbnails (⌘−)"))
                .accessibilityIdentifier("library.zoom-out")
            Slider(
                value: Binding(get: { Double(level) }, set: { level = Int($0.rounded()) }),
                in: 0...Double(maximum),
                step: 1
            )
            .frame(width: 90)
            .accessibilityLabel(String(localized: "Thumbnail size"))
            .accessibilityIdentifier("library.zoom")
            Button { zoom(1) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut(shortcut("="))
                .disabled(level >= maximum)
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
        level = LibraryThumbnailSize(level: level + step).level
    }
}
