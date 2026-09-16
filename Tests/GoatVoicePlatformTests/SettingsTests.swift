import XCTest
@testable import GoatVoicePlatform

private final class ReceivedSettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AppSettings?

    var value: AppSettings? {
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

final class SettingsStoreTests: XCTestCase {
    private var backing: InMemorySettingsBacking!
    private var store: SettingsStore!

    override func setUp() {
        backing = InMemorySettingsBacking()
        store = SettingsStore(backing: backing)
    }

    private func decodedBacking() throws -> AppSettings {
        let data = try XCTUnwrap(backing.data(forKey: SettingsStore.storageKey))
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }

    func testEmptyBackingYieldsDefaults() async {
        let settings = await store.settings
        XCTAssertEqual(settings, AppSettings())
        XCTAssertEqual(settings.shortcut, .modifier(.rightOption))
        XCTAssertNil(settings.selectedModelID)
        XCTAssertEqual(settings.microphone, .systemDefault)
        XCTAssertFalse(settings.launchAtLogin)
    }

    func testUpdatePersistsValueAndNotifies() async throws {
        let changed = expectation(description: "onChange")
        let box = ReceivedSettingsBox()
        store.onChange = { value in
            box.value = value
            changed.fulfill()
        }
        await store.update { $0.launchAtLogin = true }
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(box.value?.launchAtLogin, true)
        let settings = await store.settings
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertTrue(try decodedBacking().launchAtLogin)
    }

    func testNoOpUpdateDoesNotPersistOrNotify() async {
        let forbidden = expectation(description: "onChange")
        forbidden.isInverted = true
        store.onChange = { _ in forbidden.fulfill() }
        await store.update { _ in }
        await fulfillment(of: [forbidden], timeout: 0.4)
        XCTAssertNil(backing.data(forKey: SettingsStore.storageKey))
    }

    func testNewStoreLoadsPersistedSettings() async {
        await store.update { settings in
            settings.shortcut = .chord(keyCode: 0x31, modifiers: [.command, .shift])
            settings.selectedModelID = "model-a"
            settings.microphone = .pinned(deviceUID: "mic-uid", label: "Desk Mic")
            settings.launchAtLogin = true
        }
        let reloaded = SettingsStore(backing: backing)
        let settings = await reloaded.settings
        XCTAssertEqual(settings.shortcut, .chord(keyCode: 0x31, modifiers: [.command, .shift]))
        XCTAssertEqual(settings.selectedModelID, "model-a")
        XCTAssertEqual(settings.microphone, .pinned(deviceUID: "mic-uid", label: "Desk Mic"))
        XCTAssertTrue(settings.launchAtLogin)
    }

    func testEncodedPayloadContainsExactlyTheFourFields() async throws {
        await store.update { settings in
            settings.selectedModelID = "model-b"
            settings.launchAtLogin = true
        }
        let data = try XCTUnwrap(backing.data(forKey: SettingsStore.storageKey))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["shortcut", "selectedModelID", "microphone", "launchAtLogin"])
    }

    func testNilModelIDOmitsKeyAndDecodesToNil() async throws {
        await store.update { $0.launchAtLogin = true }
        let data = try XCTUnwrap(backing.data(forKey: SettingsStore.storageKey))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["selectedModelID"])
        let persisted = try decodedBacking()
        XCTAssertNil(persisted.selectedModelID)
    }

    func testCorruptPayloadFallsBackToDefaults() async {
        backing.set(Data("not json".utf8), forKey: SettingsStore.storageKey)
        let corrupted = SettingsStore(backing: backing)
        let settings = await corrupted.settings
        XCTAssertEqual(settings, AppSettings())
    }

    func testReloadPicksUpExternalWrite() async throws {
        var external = AppSettings()
        external.selectedModelID = "external-model"
        external.microphone = .pinned(deviceUID: "uid-2", label: "Boom Mic")
        backing.set(try JSONEncoder().encode(external), forKey: SettingsStore.storageKey)
        await store.reload()
        let settings = await store.settings
        XCTAssertEqual(settings, external)
    }

    func testReloadAfterCorruptionResetsToDefaults() async throws {
        await store.update { $0.launchAtLogin = true }
        backing.set(Data([0xFF, 0x01]), forKey: SettingsStore.storageKey)
        await store.reload()
        let settings = await store.settings
        XCTAssertEqual(settings, AppSettings())
    }

    func testReloadWithoutChangesDoesNotNotify() async throws {
        await store.update { $0.launchAtLogin = true }
        let forbidden = expectation(description: "onChange")
        forbidden.isInverted = true
        store.onChange = { _ in forbidden.fulfill() }
        await store.reload()
        await fulfillment(of: [forbidden], timeout: 0.4)
    }

    func testConcurrentUpdatesLeavePersistedValueConsistent() async throws {
        let store = self.store!
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<60 {
                group.addTask {
                    await store.update { $0.launchAtLogin = index.isMultiple(of: 2) }
                    await store.update { $0.selectedModelID = "model-\(index)" }
                }
            }
        }
        let persisted = try decodedBacking()
        let settings = await store.settings
        XCTAssertEqual(persisted, settings)
    }
}
