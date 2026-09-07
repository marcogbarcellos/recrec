import Foundation

/// Persists RecordingSettings as one JSON blob in UserDefaults; any decode problem yields the defaults.
public final class SettingsStore {
    public static let key = "recordingSettings"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> RecordingSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(RecordingSettings.self, from: data) else {
            return .defaults
        }
        return settings
    }

    public func save(_ settings: RecordingSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
