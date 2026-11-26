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
/// versions off the main thread); the store is written on the main thread,
/// in the order the writes happened, through a context of its own so a
/// decision never saves someone's half-finished edit.
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

    private static let logger = Logger(subsystem: "org.example.Moments", category: "LibraryDecisions")

    private let lock = NSLock()
    private var values: [String: Any] = [:]
    @MainActor private var context: ModelContext?

    init() {}

    /// Loads the store's decisions; on the first open of a store that has
    /// none, copies them from `defaults` (which keep their values, as a way
    /// back). Pass nil for test stores, which start empty.
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
            do {
                try context.save()
            } catch {
                Self.logger.error("Could not save imported decisions: \(error.localizedDescription, privacy: .public)")
            }
        }
        lock.lock()
        values = loaded
        lock.unlock()
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
        lock.unlock()
        persist(key: key, data: Self.encode(value))
    }

    func removeObject(forKey key: String) {
        lock.lock()
        let existed = values.removeValue(forKey: key) != nil
        lock.unlock()
        if existed { persist(key: key, data: nil) }
    }

    /// Writes one key on the main thread, after every write queued before it.
    private func persist(key: String, data: Data?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.write(key: key, data: data)
                NotificationCenter.default.post(name: .libraryDecisionChanged, object: key)
            }
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
    private func write(key: String, data: Data?) {
        guard let context else { return }
        let descriptor = FetchDescriptor<LocalDecision>(predicate: #Predicate { $0.key == key })
        let existing: LocalDecision? = (try? context.fetch(descriptor))?.first
        if let data {
            if let existing {
                existing.value = data
                existing.updatedAt = .now
            } else {
                context.insert(LocalDecision(key: key, value: data))
            }
        } else if let existing {
            context.delete(existing)
        }
        do {
            try context.save()
        } catch {
            Self.logger.error("Could not save a decision: \(error.localizedDescription, privacy: .public)")
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
