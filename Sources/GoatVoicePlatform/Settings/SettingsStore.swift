import Foundation

public actor SettingsStore {
    public static let storageKey = "goatvoice.settings"

    private let backing: SettingsBacking
    private let encoder = JSONEncoder()
    private let callbackQueue = DispatchQueue(label: "goat.voice.platform.settings.callback")
    private let onChangeBox = OnChangeBox()

    public private(set) var settings: AppSettings

    public nonisolated var onChange: (@Sendable (AppSettings) -> Void)? {
        get { onChangeBox.handler }
        set { onChangeBox.handler = newValue }
    }

    public init(backing: SettingsBacking) {
        self.backing = backing
        self.settings = SettingsStore.decode(backing.data(forKey: SettingsStore.storageKey))
            ?? AppSettings()
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        var next = settings
        mutate(&next)
        guard next != settings else { return }
        settings = next
        persist(next)
        notify(next)
    }

    public func reload() {
        let loaded = SettingsStore.decode(backing.data(forKey: SettingsStore.storageKey))
            ?? AppSettings()
        guard loaded != settings else { return }
        settings = loaded
        notify(loaded)
    }

    private func persist(_ value: AppSettings) {
        guard let data = try? encoder.encode(value) else { return }
        backing.set(data, forKey: SettingsStore.storageKey)
    }

    private func notify(_ value: AppSettings) {
        guard let handler = onChangeBox.handler else { return }
        callbackQueue.async { handler(value) }
    }

    private static func decode(_ data: Data?) -> AppSettings? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }
}

private final class OnChangeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (@Sendable (AppSettings) -> Void)?

    var handler: (@Sendable (AppSettings) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
