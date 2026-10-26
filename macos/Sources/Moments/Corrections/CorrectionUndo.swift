import AppKit
import SwiftData
import SwiftUI

/// One correction to dates, places or people that can be taken back, from the
/// bar at the bottom of the window or with Edit > Undo. It runs at most once,
/// whichever of the two asks first.
@MainActor
final class CorrectionUndo: Identifiable {
    let id = UUID()
    /// What was changed, shown in the bar ("Adjusted the date of 3 photos").
    let message: String
    /// The Edit menu's name for it ("Undo Adjust Date and Time").
    let actionName: String
    private var restore: (@MainActor (ModelContext) -> Void)?
    /// The window's undo manager it was put on, so Undo from the bar can
    /// take it off the Edit menu again.
    weak var undoManager: UndoManager?

    init(message: String, actionName: String, restore: @escaping @MainActor (ModelContext) -> Void) {
        self.message = message
        self.actionName = actionName
        self.restore = restore
    }

    var isDone: Bool { restore == nil }

    func perform(in context: ModelContext) {
        guard let restore else { return }
        self.restore = nil
        if undoManager?.isUndoing != true { undoManager?.removeAllActions(withTarget: self) }
        restore(context)
        try? context.save()
    }
}

extension SelectionModel {
    /// Shows the correction's Undo bar and puts it on the window's undo stack.
    /// The window's own manager, not a popover's or a sheet's, so ⌘Z still
    /// finds it once they have closed.
    func recordCorrection(_ correction: CorrectionUndo, context: ModelContext) {
        lastCorrection = correction
        let undoManager = NSApp.mainWindow?.undoManager
        correction.undoManager = undoManager
        undoManager?.registerUndo(withTarget: correction) { [weak self] correction in
            MainActor.assumeIsolated {
                correction.perform(in: context)
                if self?.lastCorrection === correction { self?.lastCorrection = nil }
            }
        }
        undoManager?.setActionName(correction.actionName)
    }
}

/// The bar at the bottom of the window after a correction: what changed and
/// an Undo button. It stays while the pointer is over it.
struct CorrectionUndoBar: View {
    @Environment(SelectionModel.self) private var selection
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    /// Long enough to read the line and reach the button.
    static let lifetime: Duration = .seconds(6)

    var body: some View {
        ZStack(alignment: .bottom) {
            if let correction = selection.lastCorrection {
                HStack(spacing: 12) {
                    Text(correction.message)
                        .font(.callout)
                        .foregroundStyle(Paper.ink)
                        .lineLimit(1)
                    Button(String(localized: "Undo")) {
                        correction.perform(in: modelContext)
                        selection.lastCorrection = nil
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Paper.accent)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("correction.undo")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    Capsule()
                        .fill(Paper.raised)
                        .shadow(color: Paper.shadow.opacity(0.14), radius: 10, y: 4)
                )
                .overlay(Capsule().strokeBorder(Paper.ink.opacity(0.06)))
                .onHover { isHovering = $0 }
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: correction.id) { await hideLater(correction) }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("correction.bar")
            }
        }
        .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: selection.lastCorrection?.id)
    }

    private func hideLater(_ correction: CorrectionUndo) async {
        repeat {
            try? await Task.sleep(for: Self.lifetime)
            if Task.isCancelled { return }
        } while isHovering
        if selection.lastCorrection === correction { selection.lastCorrection = nil }
    }
}
