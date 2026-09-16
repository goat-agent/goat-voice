import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var shortcut: TriggerSpec
    public var selectedModelID: String?
    public var microphone: MicrophoneSelection
    public var launchAtLogin: Bool

    public init(shortcut: TriggerSpec = .default,
                selectedModelID: String? = nil,
                microphone: MicrophoneSelection = .systemDefault,
                launchAtLogin: Bool = false) {
        self.shortcut = shortcut
        self.selectedModelID = selectedModelID
        self.microphone = microphone
        self.launchAtLogin = launchAtLogin
    }
}

public protocol SettingsBacking: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

public final class UserDefaultsSettingsBacking: SettingsBacking, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    public func set(_ data: Data?, forKey key: String) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

public final class InMemorySettingsBacking: SettingsBacking, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func set(_ data: Data?, forKey key: String) {
        lock.lock()
        storage[key] = data
        lock.unlock()
    }
}
