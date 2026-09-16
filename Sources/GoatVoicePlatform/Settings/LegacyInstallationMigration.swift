import Foundation

public enum LegacyInstallationMigration {
    public static let legacyBundleIdentifier = "ai.goat.voicetyping"
    public static let bundleIdentifier = "ai.goat.voice"

    @discardableResult
    public static func migrateSettings(from legacy: any SettingsBacking,
                                       to current: any SettingsBacking) -> Bool {
        guard current.data(forKey: SettingsStore.storageKey) == nil,
              let data = legacy.data(forKey: SettingsStore.storageKey),
              (try? JSONDecoder().decode(AppSettings.self, from: data)) != nil else {
            return false
        }
        current.set(data, forKey: SettingsStore.storageKey)
        return true
    }

    @discardableResult
    public static func migrateModels(from legacy: URL, to current: URL,
                                     fileManager: FileManager = .default) throws -> Int {
        guard fileManager.fileExists(atPath: legacy.path) else { return 0 }
        if !fileManager.fileExists(atPath: current.path) {
            try fileManager.createDirectory(at: current.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try fileManager.moveItem(at: legacy, to: current)
            return 1
        }
        var moved = 0
        for source in try fileManager.contentsOfDirectory(at: legacy,
                                                         includingPropertiesForKeys: nil) {
            let destination = current.appendingPathComponent(source.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try fileManager.moveItem(at: source, to: destination)
            moved += 1
        }
        return moved
    }
}
