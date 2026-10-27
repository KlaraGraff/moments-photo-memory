import AppKit
import SwiftData
import SwiftUI

/// Every way of deleting photos goes through here: the Delete key, ⌘⌫, the
/// grid's context menu and the viewer's trash button.
@MainActor
enum PhotoDeletion {
    /// Asks to delete `ids`. Delete asks first, like Photos; ⌘⌫ (`confirm:
    /// false`) deletes straight away, with Undo right after either way.
    static func request(_ ids: [String], confirm: Bool, selection: SelectionModel, context: ModelContext, undoManager: UndoManager?) {
        let items = fetch(ids, context: context).filter { $0.deletedAt == nil }
        let own = items.filter { RecentlyDeleted.canDelete($0) }
        guard !own.isEmpty else {
            // Nothing here this person may delete.
            if !items.isEmpty { NSSound.beep() }
            return
        }
        if confirm {
            selection.pendingDeletion = PendingDeletion(itemIDs: own.map(\.id), othersCount: items.count - own.count)
        } else {
            perform(own.map(\.id), selection: selection, context: context, undoManager: undoManager)
        }
    }

    /// Moves the photos to Recently Deleted, registers ⌘Z and shows the bar.
    static func perform(_ ids: [String], selection: SelectionModel, context: ModelContext, undoManager: UndoManager?) {
        let moved = RecentlyDeleted.moveToTrash(fetch(ids, context: context), context: context)
        guard !moved.isEmpty else { return }
        selection.forget(deleted: Set(moved))
        let target = DeletionUndoTarget()
        registerUndo(moved, target: target, selection: selection, context: context, undoManager: undoManager)
        selection.lastDeletion = DeletionNotice(itemIDs: moved, undoTarget: target)
        // One Undo bar at a time: the newest action's.
        selection.lastCorrection = nil
    }

    /// Undo puts them back; Redo deletes them again. The undo manager holds
    /// its targets weakly, so the handlers keep `target` alive themselves.
    private static func registerUndo(_ ids: [String], target: DeletionUndoTarget, selection: SelectionModel, context: ModelContext, undoManager: UndoManager?) {
        undoManager?.registerUndo(withTarget: target) { [target] _ in
            MainActor.assumeIsolated {
                RecentlyDeleted.recover(fetch(ids, context: context), context: context)
                // Undone: the bar has nothing left to offer.
                if selection.lastDeletion?.undoTarget === target { selection.lastDeletion = nil }
                undoManager?.registerUndo(withTarget: target) { [target] _ in
                    MainActor.assumeIsolated {
                        let moved = RecentlyDeleted.moveToTrash(fetch(ids, context: context), context: context)
                        selection.forget(deleted: Set(moved))
                        registerUndo(ids, target: target, selection: selection, context: context, undoManager: undoManager)
                    }
                }
                undoManager?.setActionName(String(localized: "Delete"))
            }
        }
        undoManager?.setActionName(String(localized: "Delete"))
    }

    /// The bar's Undo: the same as ⌘Z, which then has nothing left to undo.
    static func undo(_ notice: DeletionNotice, selection: SelectionModel, context: ModelContext, undoManager: UndoManager?) {
        undoManager?.removeAllActions(withTarget: notice.undoTarget)
        RecentlyDeleted.recover(fetch(notice.itemIDs, context: context), context: context)
        if selection.lastDeletion == notice { selection.lastDeletion = nil }
    }

    static func fetch(_ ids: [String], context: ModelContext) -> [MediaItem] {
        guard !ids.isEmpty else { return [] }
        return (try? context.fetch(FetchDescriptor<MediaItem>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
    }
}

extension Notification.Name {
    /// ⌘⌫ (or ⌘⌦) outside a text field: delete without asking.
    static let momentsDeleteWithoutAsking = Notification.Name("Moments.DeleteWithoutAsking")
}

/// SwiftUI treats ⌘-keys as menu shortcuts and never hands ⌘⌫ to
/// `onKeyPress`, so it is caught here and passed on to the grid or viewer.
/// A text field keeps ⌘⌫ (delete to the start of the line), an open alert
/// keeps its keys, and Settings has no photos to delete.
@MainActor
enum DeleteShortcutMonitor {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 51 is ⌫, 117 is ⌦.
            guard event.keyCode == 51 || event.keyCode == 117,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let window = event.window, window.isKeyWindow, window.attachedSheet == nil,
                  !(window.firstResponder is NSText),
                  !(window.identifier?.rawValue.contains("Settings") ?? false) else { return event }
            NotificationCenter.default.post(name: .momentsDeleteWithoutAsking, object: nil)
            return nil
        }
    }
}

private struct PhotoDeletionScopeKey: EnvironmentKey {
    static let defaultValue: @MainActor ([String]) -> [String] = { $0 }
}

extension EnvironmentValues {
    /// Turns what a grid shows into the photos behind it: a stacked burst
    /// is one cell but deleting it deletes every photo in it, as in Photos.
    var photoDeletionScope: @MainActor ([String]) -> [String] {
        get { self[PhotoDeletionScopeKey.self] }
        set { self[PhotoDeletionScopeKey.self] = newValue }
    }
}

/// The "Delete from Moments?" alert, once for the whole window.
struct PhotoDeletionConfirmation: ViewModifier {
    @Environment(SelectionModel.self) private var selection
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content.alert(
            Self.title(selection.pendingDeletion?.itemIDs.count ?? 0),
            isPresented: Binding(
                get: { selection.pendingDeletion != nil },
                set: { if !$0 { selection.pendingDeletion = nil } }
            ),
            presenting: selection.pendingDeletion
        ) { pending in
            Button(String(localized: "Delete"), role: .destructive) {
                selection.pendingDeletion = nil
                PhotoDeletion.perform(pending.itemIDs, selection: selection, context: modelContext, undoManager: undoManager)
            }
            .accessibilityIdentifier("delete.confirm")
            Button(String(localized: "Cancel"), role: .cancel) { selection.pendingDeletion = nil }
        } message: { pending in
            Text(Self.message(othersCount: pending.othersCount))
        }
    }

    static func title(_ count: Int) -> String {
        count == 1
            ? String(localized: "Delete this photo from Moments?")
            : String(localized: "Delete \(count) photos from Moments?")
    }

    static func message(othersCount: Int) -> String {
        var text = String(localized: "They stay in Recently Deleted for 30 days. Your original files on this Mac and in Apple Photos are not touched.")
        if othersCount > 0 {
            text += "\n\n" + String(localized: "\(othersCount) photos your partner added stay; only they can delete them.")
        }
        return text
    }
}

/// "3 moved to Recently Deleted · Undo" at the foot of the window; hides itself.
struct DeletionUndoBar: View {
    @Environment(SelectionModel.self) private var selection
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let notice = selection.lastDeletion {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .foregroundStyle(Paper.muted)
                Text(String(localized: "\(notice.itemIDs.count) moved to Recently Deleted"))
                    .foregroundStyle(Paper.ink)
                Button(String(localized: "Undo")) {
                    withAnimation(reduceMotion ? nil : Motion.settle) {
                        PhotoDeletion.undo(notice, selection: selection, context: modelContext, undoManager: undoManager)
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Paper.accent)
                .accessibilityIdentifier("delete.undo")
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Paper.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Paper.shadow.opacity(0.08)))
            .shadow(color: Paper.shadow.opacity(0.12), radius: 8, y: 2)
            .padding(.bottom, 18)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("delete.bar")
            .task(id: notice.id) {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled, selection.lastDeletion == notice else { return }
                withAnimation(reduceMotion ? nil : Motion.settle) { selection.lastDeletion = nil }
            }
        }
    }
}
