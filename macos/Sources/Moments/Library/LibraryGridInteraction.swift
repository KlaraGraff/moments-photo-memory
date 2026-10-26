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

    /// Reports the grid's column count to `state` for the up and down arrows.
    func measuresLibraryGridColumns(_ state: LibraryViewState, minimum: CGFloat, spacing: CGFloat) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        state.gridColumns = LibraryGridNavigation.columns(width: geometry.size.width, minimum: minimum, spacing: spacing)
                    }
                    .onChange(of: geometry.size.width) { _, width in
                        state.gridColumns = LibraryGridNavigation.columns(width: width, minimum: minimum, spacing: spacing)
                    }
            }
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
            // A click on a photo makes the grid the keyboard target, unless
            // the click went into a note field.
            .onChange(of: selection.focusedItemID) { _, focused in
                guard focused != nil, !Self.isEditingText else { return }
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
        selection.openViewer(focused, in: state.orderedItemIDs)
        return .handled
    }
}
