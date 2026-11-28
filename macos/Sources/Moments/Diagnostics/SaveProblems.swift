import AppKit
import MomentsCore
import Observation
import SwiftData
import SwiftUI

extension ModelContext: @retroactive SaveTarget {
    public func commitChanges() throws { try save() }
}

extension ModelContext {
    /// Saves, and never fails silently: a failure is logged and shown at the
    /// bottom of the window, and the changes stay in this context (on
    /// screen) until a later save or Try Again writes them. Returns whether
    /// it saved. Use it wherever a save used to be `try? context.save()`.
    @discardableResult
    func saveOrReport(file: StaticString = #fileID, line: UInt = #line) -> Bool {
        #if DEBUG
        // A UI test that makes a save fail checks what stays on screen, so
        // autosave must not quietly write it first.
        if SaveProblems.failsSavesForUITest { autosaveEnabled = false }
        #endif
        return SaveProblems.guard.save(self, site: DiagnosticSanitizer.site(file: "\(file)", line: line))
    }
}

/// The app's save guard and what the window shows about it.
@MainActor
@Observable
final class SaveProblems {
    static let shared = SaveProblems()

    /// Every save in the app goes through this one guard.
    nonisolated static let `guard`: SaveGuard = {
        let saving = SaveGuard(journal: MomentsLog.journal)
        saving.onEvent = { event in
            MomentsLog.writeToSystemLog(event, level: event.name == "save-failed" ? .error : .default)
        }
        saving.onChange = { _ in
            // Read again on the main thread, so a late hop never shows an
            // older state than the newest.
            if Thread.isMainThread {
                MainActor.assumeIsolated { SaveProblems.shared.refresh() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { SaveProblems.shared.refresh() } }
            }
        }
        // Autosave, or a save that throws to its caller, may write a context
        // that failed before: then nothing is unsaved any more.
        _ = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { note in
            if let context = note.object as? ModelContext { saving.markSaved(context) }
        }
        #if DEBUG
        // -MomentsUITestFailSaveIn <File.swift>: the first save made in that
        // file fails, to show the notice in a UI test without a broken store.
        if let file = uiTestFailingFile {
            let remaining = FailureCounter(1)
            saving.injectFailure = { site in
                site.hasPrefix(file + ":") && remaining.take() ? NSError(domain: "MomentsUITestFailSave", code: 1) : nil
            }
        }
        #endif
        return saving
    }()

    #if DEBUG
    nonisolated static let uiTestFailingFile: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-MomentsUITestFailSaveIn"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()

    nonisolated static var failsSavesForUITest: Bool { uiTestFailingFile != nil }
    #endif

    /// What could not be saved; nil while everything is saved.
    private(set) var problem: SaveProblem?
    /// The revision of the notice the person closed: it stays closed until
    /// saving fails again.
    private(set) var dismissedRevision: Int?

    var visibleProblem: SaveProblem? {
        guard let problem, problem.revision != dismissedRevision else { return nil }
        return problem
    }

    func refresh() {
        let current = Self.guard.problem
        if current != problem { problem = current }
    }

    func tryAgain() {
        Self.guard.retryFailed()
        refresh()
    }

    func dismiss() {
        dismissedRevision = problem?.revision
    }

    /// Before quitting: one more try, and if changes are still unsaved, ask
    /// whether to quit anyway, as they would be lost. Tests pass their own
    /// `quitAnyway` in place of the alert.
    func confirmQuit(quitAnyway: (() -> Bool)? = nil) -> NSApplication.TerminateReply {
        guard Self.guard.hasUnsavedChanges, !Self.guard.retryFailed() else { return .terminateNow }
        refresh()
        let quit = quitAnyway?() ?? Self.askToQuitAnyway()
        return quit ? .terminateNow : .terminateCancel
    }

    static func askToQuitAnyway() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Some changes aren't saved")
        alert.informativeText = String(localized: "Moments couldn't save your latest changes. If you quit now, they will be lost.")
        alert.addButton(withTitle: String(localized: "Don't Quit"))
        alert.addButton(withTitle: String(localized: "Quit Anyway"))
        return alert.runModal() == .alertSecondButtonReturn
    }
}

#if DEBUG
private final class FailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    init(_ count: Int) { remaining = count }
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}
#endif

/// The strip at the bottom of the window while a change could not be
/// saved: what happened, Try Again, and a close button. It sits below the
/// pages rather than over them, so clicks on it always reach it.
struct SaveProblemStrip: View {
    private var problems: SaveProblems { .shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if problems.visibleProblem != nil {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Paper.accent)
                        .accessibilityHidden(true)
                    Text(String(localized: "Couldn't save your latest changes. They're kept here until saving works."))
                        .font(.callout)
                        .foregroundStyle(Paper.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("save.problem.message")
                    Spacer(minLength: 8)
                    Button(String(localized: "Try Again")) { problems.tryAgain() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Paper.accent)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("save.problem.retry")
                    Button {
                        problems.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Paper.muted)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Close"))
                    .accessibilityLabel(String(localized: "Close"))
                    .accessibilityIdentifier("save.problem.close")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Paper.raised)
                .overlay(alignment: .top) {
                    Rectangle().fill(Paper.ink.opacity(0.08)).frame(height: 1)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("save.problem")
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.animation(Motion.snap, reduceMotion: reduceMotion), value: problems.visibleProblem?.revision)
    }
}
