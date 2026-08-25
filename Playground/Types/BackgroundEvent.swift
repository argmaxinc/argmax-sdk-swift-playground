import Foundation

/// A single persisted entry in the background-download event log.
///
/// Read by the developer-tools settings sections and appended by both the running app and the
/// AppDelegate's `handleEventsForBackgroundURLSession` relaunch hook -- the OS can relaunch
/// the app straight into that wake path, so the log must exist independently of the harness.
/// Persisted in `UserDefaults` under a single key, capped at `cap` entries.
public struct BackgroundEvent: Codable, Identifiable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let message: String

    static let cap = 200
    private static let storageKey = "ArgmaxSDKCoordinator.backgroundEvents"

    /// Decode the persisted log from UserDefaults. Returns an empty array if missing or unreadable.
    static func load() -> [BackgroundEvent] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([BackgroundEvent].self, from: data)
        else { return [] }
        return decoded
    }

    /// Persist the log; called from the main thread alongside the @Published update.
    static func save(_ events: [BackgroundEvent]) {
        if let data = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// Append a single event to the persisted log without going through a Coordinator
    /// instance. Used by the AppDelegate when it's woken into a context that may not yet have
    /// the Coordinator.
    static func append(_ message: String) {
        var current = load()
        current.insert(BackgroundEvent(id: UUID(), timestamp: Date(), message: message), at: 0)
        if current.count > cap {
            current.removeLast(current.count - cap)
        }
        save(current)
    }
}
