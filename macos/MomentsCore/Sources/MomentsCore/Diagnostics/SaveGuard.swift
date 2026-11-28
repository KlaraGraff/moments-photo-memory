import Foundation

/// Something whose changes can be written to disk, like the app's database
/// context. Changes that could not be written stay in it, so trying again
/// later writes them.
public protocol SaveTarget: AnyObject {
    func commitChanges() throws
}

/// What the window says while changes could not be saved.
public struct SaveProblem: Equatable, Sendable {
    /// How many places hold changes that are not saved yet.
    public var unsavedTargets: Int
    /// The newest failure's error, as "domain/code".
    public var errorText: String
    /// Goes up with every new failure, so a notice the person closed shows
    /// again when saving fails once more.
    public var revision: Int
}

/// The one way the app saves: every save goes through here, and none fails
/// without a trace. A failed save is logged (where in the code, the error's
/// code, never the content), remembered so it can be tried again, and
/// reported to `onChange` so the window can say so. The changes themselves
/// stay in their context: nothing is rolled back, so what the person wrote
/// is still on screen and is saved once a later attempt works.
///
/// Safe to call from any thread. Only failures on the main thread are tried
/// again from `retryFailed()` (the window's Try Again), because a context
/// belongs to the thread it was used on; a failure elsewhere is still
/// logged and shown.
public final class SaveGuard: @unchecked Sendable {
    private struct Pending {
        weak var target: AnyObject?
        var site: String
        var isRetryable: Bool
        var error: String
    }

    public let journal: DiagnosticsJournal
    /// Called with the new state after every change to it, on the thread
    /// that saved.
    public var onChange: (@Sendable (SaveProblem?) -> Void)?
    /// Called with every event the guard adds to the journal, so the app can
    /// also write it to the system log.
    public var onEvent: (@Sendable (DiagnosticEvent) -> Void)?
    /// Tests and UI tests only: given the save's site, an error to fail it
    /// with instead of saving. Returning nil saves as usual.
    public var injectFailure: (@Sendable (String) -> (any Error)?)?

    private let lock = NSLock()
    private var pending: [ObjectIdentifier: Pending] = [:]
    private var revision = 0
    private var lastProblem: SaveProblem?

    public init(journal: DiagnosticsJournal) {
        self.journal = journal
    }

    /// Saves `target`, and returns whether it worked. `site` says where in
    /// the code the save is (see `DiagnosticSanitizer.site`).
    @discardableResult
    public func save(_ target: some SaveTarget, site: String) -> Bool {
        save(target, site: site, retryable: Thread.isMainThread)
    }

    @discardableResult
    public func save(_ target: some SaveTarget, site: String, retryable: Bool) -> Bool {
        let key = ObjectIdentifier(target)
        do {
            if let error = injectFailure?(site) { throw error }
            try target.commitChanges()
        } catch {
            let event = DiagnosticEvent(.saving, "save-failed", site: site, error: error)
            journal.record(event)
            onEvent?(event)
            lock.lock()
            // First drop what is gone, so a new context at a freed one's
            // address is not taken for it.
            let goneBefore = pruneLocked()
            revision += 1
            var entry = pending[key] ?? Pending(target: target, site: event.site ?? "code", isRetryable: retryable, error: "")
            entry.target = target
            entry.isRetryable = entry.isRetryable || retryable
            entry.error = event.errorText ?? "error"
            pending[key] = entry
            let (problem, dropped) = currentProblemLocked()
            lock.unlock()
            logDropped(goneBefore + dropped)
            publish(problem)
            return false
        }
        lock.lock()
        let goneBefore = pruneLocked()
        let wasPending = pending.removeValue(forKey: key) != nil
        let (problem, dropped) = currentProblemLocked()
        lock.unlock()
        logDropped(goneBefore + dropped)
        if wasPending {
            let event = DiagnosticEvent(.saving, "save-recovered", site: site)
            journal.record(event)
            onEvent?(event)
        }
        // Also when another context had gone meanwhile: the window hears it.
        publish(problem)
        return true
    }

    /// `target` was saved some other way (the context's own autosave, or a
    /// save that does not go through the guard): it has nothing unsaved now.
    public func markSaved(_ target: some SaveTarget) {
        lock.lock()
        let goneBefore = pruneLocked()
        let entry = pending.removeValue(forKey: ObjectIdentifier(target))
        let (problem, dropped) = currentProblemLocked()
        lock.unlock()
        logDropped(goneBefore + dropped)
        if let entry {
            // The site of the save that failed: this is often Try Again or
            // that same save, whose context announces it saved.
            let event = DiagnosticEvent(.saving, "save-recovered", site: entry.site)
            journal.record(event)
            onEvent?(event)
        }
        publish(problem)
    }

    /// Tries every failed main-thread save again. True when nothing is left
    /// unsaved.
    @discardableResult
    public func retryFailed() -> Bool {
        lock.lock()
        let retry = pending.values.compactMap { entry -> (SaveTarget, String)? in
            guard entry.isRetryable, let target = entry.target as? SaveTarget else { return nil }
            return (target, entry.site)
        }
        lock.unlock()
        for (target, site) in retry {
            save(target, site: site, retryable: true)
        }
        let problem = problem
        publish(problem)
        return problem == nil
    }

    /// The current state: nil once every failed save has been saved again
    /// (or its context is gone). Reading it also tells `onChange` when a
    /// context that held unsaved changes has gone since.
    public var problem: SaveProblem? {
        lock.lock()
        let (problem, dropped) = currentProblemLocked()
        let changed = problem != lastProblem
        lock.unlock()
        logDropped(dropped)
        if changed { publish(problem) }
        return problem
    }

    /// Whether anything is still unsaved, for a last try before quitting.
    public var hasUnsavedChanges: Bool { problem != nil }

    /// The state now, and how many contexts went away with unsaved changes
    /// since the last look (logged by the caller, after unlocking).
    private func currentProblemLocked() -> (SaveProblem?, dropped: Int) {
        let dropped = pruneLocked()
        guard let any = pending.values.first else { return (nil, dropped) }
        let errorText = lastErrorTextLocked() ?? any.error
        return (SaveProblem(unsavedTargets: pending.count, errorText: errorText, revision: revision), dropped)
    }

    /// Forgets contexts that went away; returns how many.
    private func pruneLocked() -> Int {
        let kept = pending.filter { $0.value.target != nil }
        let dropped = pending.count - kept.count
        pending = kept
        return dropped
    }

    private func logDropped(_ dropped: Int) {
        guard dropped > 0 else { return }
        // Its context went away with the changes still in it.
        let event = DiagnosticEvent(.saving, "save-dropped", count: dropped)
        journal.record(event)
        onEvent?(event)
    }

    private func lastErrorTextLocked() -> String? {
        journal.recent.last(where: { $0.name == "save-failed" })?.errorText
    }

    private func publish(_ problem: SaveProblem?) {
        lock.lock()
        let changed = problem != lastProblem
        lastProblem = problem
        let onChange = onChange
        lock.unlock()
        if changed { onChange?(problem) }
    }
}
