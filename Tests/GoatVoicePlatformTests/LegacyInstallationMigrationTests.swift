import Foundation
import XCTest
@testable import GoatVoicePlatform

final class LegacyInstallationMigrationTests: XCTestCase {
    func testExistingPreferencesMigrateWithoutChangingTheirValues() throws {
        let legacy = InMemorySettingsBacking()
        let current = InMemorySettingsBacking()
        let data = try JSONEncoder().encode(AppSettings(selectedModelID: "qwen3-asr-1.7b"))
        legacy.set(data, forKey: SettingsStore.storageKey)
        XCTAssertTrue(LegacyInstallationMigration.migrateSettings(from: legacy, to: current))
        XCTAssertEqual(current.data(forKey: SettingsStore.storageKey), data)
        XCTAssertEqual(legacy.data(forKey: SettingsStore.storageKey), data)
        XCTAssertFalse(LegacyInstallationMigration.migrateSettings(from: legacy, to: current))
    }

    func testCurrentPreferencesAreNeverOverwritten() throws {
        let legacy = InMemorySettingsBacking()
        let current = InMemorySettingsBacking()
        let currentData = try JSONEncoder().encode(AppSettings(selectedModelID: "whisper-large-v3-turbo"))
        legacy.set(try JSONEncoder().encode(AppSettings()), forKey: SettingsStore.storageKey)
        current.set(currentData, forKey: SettingsStore.storageKey)
        XCTAssertFalse(LegacyInstallationMigration.migrateSettings(from: legacy, to: current))
        XCTAssertEqual(current.data(forKey: SettingsStore.storageKey), currentData)
    }

    func testInvalidLegacyPreferencesAreIgnored() {
        let legacy = InMemorySettingsBacking()
        let current = InMemorySettingsBacking()
        legacy.set(Data("invalid".utf8), forKey: SettingsStore.storageKey)
        XCTAssertFalse(LegacyInstallationMigration.migrateSettings(from: legacy, to: current))
        XCTAssertNil(current.data(forKey: SettingsStore.storageKey))
    }

    func testModelDirectoryMovesWithoutRedownloadingAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy/Models")
        let current = root.appendingPathComponent("current/Models")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: legacy.appendingPathComponent("manifest.json"))
        XCTAssertEqual(try LegacyInstallationMigration.migrateModels(from: legacy, to: current), 1)
        XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("manifest.json")), Data("fixture".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try LegacyInstallationMigration.migrateModels(from: legacy, to: current), 0)
    }

    func testExistingModelEntriesArePreservedWhileMissingEntriesAreAdopted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy")
        let current = root.appendingPathComponent("current")
        for directory in [legacy, current] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("old".utf8).write(to: legacy.appendingPathComponent("existing"))
        try Data("new".utf8).write(to: current.appendingPathComponent("existing"))
        try Data("missing".utf8).write(to: legacy.appendingPathComponent("missing"))
        XCTAssertEqual(try LegacyInstallationMigration.migrateModels(from: legacy, to: current), 1)
        XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("existing")), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("existing")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("missing")), Data("missing".utf8))
    }
}
