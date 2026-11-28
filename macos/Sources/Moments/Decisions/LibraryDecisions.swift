import Foundation
import os
import SwiftData

/// One choice someone made about their library, kept in the store so it
/// travels with backups and survives a new app identifier: a trip's cover,
/// the photos placed in a trip by hand, the People answers and groups, the
/// event days already suggested and the rule versions the library was
/// organized with. The value is a property list, exactly what user defaults
/// held under the same key. Local only: this entity is never synced (face
/// and People data stay on this Mac).
@Model
public final class LocalDecision {
    @Attribute(.unique) public var key: String
    public var value: Data
    public var updatedAt: Date

    public init(key: String, value: Data, updatedAt: Date = .now) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
    }
}

/// The few calls the decision code makes, met by both `UserDefaults` (tests
/// pass a throwaway suite) and `LibraryDecisions` (the app).
protocol DecisionStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension DecisionStore {
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    func integer(forKey key: String) -> Int {
        if let number = object(forKey: key) as? NSNumber { return number.intValue }
        if let text = object(forKey: key) as? String { return Int(text) ?? 0 }
        return 0
    }
}

extension UserDefaults: DecisionStore {}

extension Notification.Name {
    /// Posted on the main thread after a decision changed; `object` is the key.
    static let libraryDecisionChanged = Notification.Name("moments.libraryDecisionChanged")
}

/// The library's decisions, read from memory and written through to the
/// store. Reads and writes work from any thread (People scans read rule
/// versions off the main thread). Changed keys are collected and written on
/// the main thread in one save, with the value each key holds at that moment,
/// so a bulk edit that locks thousands of photos costs one write, and the
/// store always ends up matching memory. The writes go through a context of
/// its own so a decision never saves someone's half-finished edit.
///
/// Until `configure` runs (unit tests without a store) it keeps values in
/// memory only.
final class LibraryDecisions: DecisionStore, @unchecked Sendable {
    static let shared = LibraryDecisions()

    /// Marks a store whose user-default values were copied in, so the copy
    /// happens once per store (a restored older backup is copied again).
    static let importedMarkerKey = "moments.decisions.importedFromDefaults"

    /// The keys that moved from user defaults into the store.
    static var movedKeys: [String] {
        LibraryDecisionKeys.all.filter { $0 != TripCorrectionLog.editorKey }
    }


    private let lock = NSLock()
    private var values: [String: Any] = [:]
    /// Keys changed in memory and not yet written to the store.
    private var dirty: Set<String> = []
    private var writeScheduled = false
    @MainActor private var context: ModelContext?

    init() {}

    /// Loads the store's decisions; on the first open of a store that has
    /// none, copies them from `defaults` (which keep their values, as a way
    /// back). Pass nil for test stores, which start empty. Anything set
    /// before this ran wins over the store and is written to it.
    @MainActor
    func configure(container: ModelContainer, importingFrom defaults: UserDefaults?) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        self.context = context
        var loaded: [String: Any] = [:]
        let rows: [LocalDecision] = (try? context.fetch(FetchDescriptor<LocalDecision>())) ?? []
        for row in rows {
            if let value = Self.decode(row.value) { loaded[row.key] = value }
        }
        if let defaults, loaded[Self.importedMarkerKey] == nil {
            for key in Self.movedKeys where loaded[key] == nil {
                guard let value = defaults.object(forKey: key), let data = Self.encode(value) else { continue }
                context.insert(LocalDecision(key: key, value: data))
                loaded[key] = value
            }
            if let marker = Self.encode(true) {
                context.insert(LocalDecision(key: Self.importedMarkerKey, value: marker))
                loaded[Self.importedMarkerKey] = true
            }
            context.saveOrReport()
        }
        lock.lock()
        for key in dirty {
            if let value = values[key] {
                loaded[key] = value
            } else {
                loaded.removeValue(forKey: key)
            }
        }
        values = loaded
        let pending = !dirty.isEmpty
        lock.unlock()
        if pending { scheduleWrite() }
    }

    func object(forKey key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: Any?, forKey key: String) {
        guard let value else {
            removeObject(forKey: key)
            return
        }
        lock.lock()
        values[key] = value
        dirty.insert(key)
        lock.unlock()
        scheduleWrite()
    }

    func removeObject(forKey key: String) {
        lock.lock()
        let existed = values.removeValue(forKey: key) != nil
        if existed { dirty.insert(key) }
        lock.unlock()
        if existed { scheduleWrite() }
    }

    /// Queues one write on the main thread for everything changed until it runs.
    private func scheduleWrite() {
        lock.lock()
        let alreadyScheduled = writeScheduled
        writeScheduled = true
        lock.unlock()
        guard !alreadyScheduled else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.writeDirty() }
        }
    }

    /// Waits for queued writes; tests call it before reading the store.
    @MainActor
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    private func writeDirty() {
        lock.lock()
        writeScheduled = false
        guard context != nil else {
            // No store yet: `configure` writes these when it runs.
            lock.unlock()
            return
        }
        let keys = dirty
        dirty = []
        var current: [String: Any] = [:]
        for key in keys {
            if let value = values[key] { current[key] = value }
        }
        lock.unlock()
        guard !keys.isEmpty else { return }
        for key in keys.sorted() {
            write(key: key, value: current[key])
        }
        context?.saveOrReport()
        for key in keys.sorted() {
            NotificationCenter.default.post(name: .libraryDecisionChanged, object: key)
        }
    }

    @MainActor
    private func write(key: String, value: Any?) {
        guard let context else { return }
        let descriptor = FetchDescriptor<LocalDecision>(predicate: #Predicate { $0.key == key })
        let existing: LocalDecision? = (try? context.fetch(descriptor))?.first
        guard let value else {
            if let existing { context.delete(existing) }
            return
        }
        guard let data = Self.encode(value) else {
            // Not a property list: keep what the store had rather than lose it.
            assertionFailure("A library decision must be a property list: \(key)")
            MomentsLog.error(.decisions, "decision-encode-failed")
            return
        }
        if let existing {
            existing.value = data
            existing.updatedAt = .now
        } else {
            context.insert(LocalDecision(key: key, value: data))
        }
    }

    static func encode(_ value: Any) -> Data? {
        // A single value is wrapped, since a property list's root is more
        // reliable as a container.
        try? PropertyListSerialization.data(fromPropertyList: ["v": value], format: .binary, options: 0)
    }

    static func decode(_ data: Data) -> Any? {
        let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
        return (root as? [String: Any])?["v"]
    }
}
