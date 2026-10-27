import AppKit
import SwiftUI

/// What a double click on a window's title bar does, as chosen in System
/// Settings ▸ Desktop & Dock ("Double-click a window's title bar to").
enum TitleBarDoubleClick {
    static func perform(in window: NSWindow?) {
        guard let window else { return }
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            window.performMiniaturize(nil)
        case "None":
            break
        case nil where defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"):
            // The older setting, from before the action had a menu.
            window.performMiniaturize(nil)
        default:
            // "Maximize" (Zoom), "Fill" and the default all make the window fill the screen.
            window.performZoom(nil)
        }
    }
}

extension View {
    /// For a header row that continues the title bar's paper: a double click
    /// on its empty background does what a double click on the title bar does.
    /// Its buttons and pickers keep their clicks.
    func actsAsTitleBar() -> some View {
        background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    TitleBarDoubleClick.perform(in: NSApp.currentEvent?.window ?? NSApp.keyWindow)
                }
        }
    }
}
