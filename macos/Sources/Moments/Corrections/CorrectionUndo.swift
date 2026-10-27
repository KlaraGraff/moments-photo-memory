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

    /// Long enough to read the line and reach the button. UI tests get
    /// longer, as a hosted Mac can take seconds between two steps.
    static let lifetime: Duration = ProcessInfo.processInfo.arguments.contains("-MomentsUITesting") ? .seconds(30) : .seconds(6)

    var body: some View {
        ZStack(alignment: .bottom) {
            if let correction = selection.lastCorrection {
                UndoBarLayer(
                    id: correction.id,
                    message: correction.message,
                    undo: {
                        correction.perform(in: modelContext)
                        selection.lastCorrection = nil
                    },
                    onHover: { isHovering = $0 }
                )
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                // The bar can go while the pointer is on it, with no word
                // that it left: start each one as not hovered.
                .task(id: correction.id) {
                    isHovering = false
                    await hideLater(correction)
                }
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

/// The capsule itself, with room around it for its shadow.
private struct CorrectionUndoCapsule: View {
    let message: String
    let undo: () -> Void
    let onHover: (Bool) -> Void
    /// Where the Undo button is, in the capsule's own view.
    var onUndoFrame: (CGRect) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.callout)
                .foregroundStyle(Paper.ink)
                .lineLimit(1)
            Button(String(localized: "Undo"), action: undo)
                .buttonStyle(.borderless)
                .foregroundStyle(Paper.accent)
                .fontWeight(.semibold)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: UndoFrameKey.self, value: proxy.frame(in: .named(UndoFrameKey.space)))
                })
                .accessibilityIdentifier("correction.undo")
        }
        .onPreferenceChange(UndoFrameKey.self, perform: onUndoFrame)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(Paper.raised)
                .shadow(color: Paper.shadow.opacity(0.14), radius: 10, y: 4)
        )
        .overlay(Capsule().strokeBorder(Paper.ink.opacity(0.06)))
        .onHover(perform: onHover)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("correction.bar")
        .padding(12)
        // The hosting view's own space: .global is the window's.
        .coordinateSpace(name: UndoFrameKey.space)
    }
}

private struct UndoFrameKey: PreferenceKey {
    static let space = "correction.bar"
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// The capsule in an AppKit view of its own, which takes the clicks on Undo
/// itself. Over the Library, AppKit hands a click there to the views behind
/// (the note fields, and the scroll view once the Library has redrawn after
/// a change), so the button was drawn and in reach but did nothing.
private struct UndoBarLayer: NSViewRepresentable {
    /// The content changes only with this: the bar is set up once per
    /// correction, not again on every redraw of the view behind it.
    let id: UUID
    let message: String
    let undo: () -> Void
    let onHover: (Bool) -> Void

    final class Coordinator {
        /// Measures the content: the shown view has no Auto Layout size, so
        /// its own fitting size is zero.
        let measure: NSHostingController<CorrectionUndoCapsule>
        var id: UUID
        weak var view: UndoBarHostingView?

        init(id: UUID, capsule: CorrectionUndoCapsule) {
            self.id = id
            measure = NSHostingController(rootView: capsule)
        }
    }

    private func capsule(reportingTo coordinator: Coordinator?) -> CorrectionUndoCapsule {
        CorrectionUndoCapsule(message: message, undo: undo, onHover: onHover) { [weak coordinator] frame in
            coordinator?.view?.undoFrame = frame
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(id: id, capsule: capsule(reportingTo: nil))
    }

    func makeNSView(context: Context) -> UndoBarHostingView {
        let view = UndoBarHostingView(rootView: capsule(reportingTo: context.coordinator))
        // SwiftUI sets the frame; no Auto Layout size of its own to fight it.
        view.sizingOptions = []
        view.onUndo = undo
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: UndoBarHostingView, context: Context) {
        guard context.coordinator.id != id else { return }
        context.coordinator.id = id
        view.rootView = capsule(reportingTo: context.coordinator)
        view.onUndo = undo
        context.coordinator.measure.rootView = capsule(reportingTo: nil)
    }

    /// Its own size, but no wider than offered, so a long line truncates.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: UndoBarHostingView, context: Context) -> CGSize? {
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let ideal = context.coordinator.measure.sizeThatFits(in: unbounded)
        return CGSize(width: min(ideal.width, proposal.width ?? ideal.width), height: ideal.height)
    }
}

/// Watches the window's clicks and takes the ones on Undo before AppKit
/// looks for the view under them, including the click that makes the
/// window key (the first one after a sheet closes).
private final class UndoBarHostingView: NSHostingView<CorrectionUndoCapsule> {
    /// The Undo button, in SwiftUI's coordinates for this view (top left).
    var undoFrame = CGRect.zero
    var onUndo: (() -> Void)?
    private var monitor: Any?
    private var isPressing = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        // Off the window (the bar has gone): no monitor left behind.
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            // Local monitors run on the main thread.
            MainActor.assumeIsolated { self?.take(event) ?? false } ? nil : event
        }
    }

    /// True when the event was Undo's and is handled here.
    private func take(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            guard isOnUndo(event) else { return false }
            isPressing = true
            return true
        case .leftMouseDragged:
            return isPressing
        case .leftMouseUp:
            guard isPressing else { return false }
            isPressing = false
            // Let go off the button: no Undo, as with any button.
            if isOnUndo(event) { onUndo?() }
            return true
        default:
            return false
        }
    }

    private func isOnUndo(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil,
              !isHiddenOrHasHiddenAncestor, alphaValue > 0, !undoFrame.isEmpty else { return false }
        var target = undoFrame.insetBy(dx: -4, dy: -4)
        if !isFlipped { target.origin.y = bounds.height - target.maxY }
        return convert(target, to: nil).contains(event.locationInWindow)
    }
}
