import AppKit
import Foundation
import GoatVoicePlatform

struct LiveModelLocation: Equatable, Sendable {
    let id: String
    let directory: URL
}

@MainActor
final class LiveSettingsBackend: SettingsBackend {
    private let model: AppModel
    private let transcription: TranscriptionXPCClient
    private let network: NetworkActivityCoordinator
    private let modelStore: ModelStore
    private let transport: URLSessionDownloadTransport
    private let settingsStore: SettingsStore
    private let permissions: PermissionCenter
    private let loginItems: LoginItemController
    private let devices: CoreAudioDeviceResolver

    private var snapshot = AppSettings()
    private var catalog: [CatalogModel] = []
    private var installStates: [String: ModelInstallState] = [:]
    private var transientStates: [String: ModelState] = [:]
    private var loadTracks: [String: LoadTrack] = [:]
    private var microphoneItems: [MicrophoneItem] = []
    private var verifiedLocation: LiveModelLocation?
    private var verifyingSelections: Set<String> = []

    private var started = false
    private var sessionActive = false
    private var installGeneration: UInt64 = 0
    private var activeDownloadID: String?
    private var installTask: Task<Void, Never>?
    private var persistChain: Task<Void, Never>?
    private var pendingWrites: [AppSettings] = []
    private var deviceObservation: AudioObservationToken?

    var onChange: (() -> Void)?
    var onTriggerChanged: (() -> Void)?

    init(model: AppModel,
         transcription: TranscriptionXPCClient,
         network: NetworkActivityCoordinator,
         permissions: PermissionCenter = PermissionCenter(probe: SystemPermissionProbe())) {
        self.model = model
        self.transcription = transcription
        self.network = network
        transport = URLSessionDownloadTransport(gate: network.sessionGate)
        modelStore = ModelStore(
            rootDirectory: Self.modelRootDirectory(),
            transport: transport,
            gate: network,
            bundleResourceRoot: Self.modelResourceRoot())
        let backing = UserDefaultsSettingsBacking()
        if let legacy = UserDefaults(suiteName: LegacyInstallationMigration.legacyBundleIdentifier) {
            LegacyInstallationMigration.migrateSettings(
                from: UserDefaultsSettingsBacking(defaults: legacy), to: backing)
        }
        settingsStore = SettingsStore(backing: backing)
        self.permissions = permissions
        loginItems = LoginItemController()
        devices = CoreAudioDeviceResolver()
    }

    var configuredTrigger: TriggerSpec {
        snapshot.shortcut
    }

    var microphoneSelection: MicrophoneSelection {
        snapshot.microphone
    }

    var selectedModelLocation: LiveModelLocation? {
        guard let location = verifiedLocation, location.id == snapshot.selectedModelID else {
            return nil
        }
        return location
    }

    func start() async {
        guard !started else { return }
        started = true
        let previousTrigger = snapshot.shortcut
        snapshot = await settingsStore.settings
        settingsStore.onChange = { [weak self] value in
            MainHop.async { self?.adoptPersisted(value) }
        }
        network.register(modelStore)
        catalog = Self.loadCatalog()
        refreshDevices()
        deviceObservation = devices.hardware.observeInputDeviceChanges { [weak self] in
            MainHop.async { self?.handleDeviceChange() }
        }
        await refreshInstallStates()
        if let id = snapshot.selectedModelID, isInstalled(id) {
            verifyThenWarm(id)
        }
        if snapshot.shortcut != previousTrigger { onTriggerChanged?() }
        emitChange()
    }

    func stop() {
        guard started else { return }
        started = false
        installGeneration &+= 1
        settingsStore.onChange = nil
        network.unregister(modelStore)
        deviceObservation?.cancel()
        deviceObservation = nil
        installTask?.cancel()
        installTask = nil
        activeDownloadID = nil
        transport.invalidate()
        Task { await modelStore.cancelDownload() }
    }

    func setSessionActive(_ active: Bool) {
        guard sessionActive != active else { return }
        sessionActive = active
        if !active, let id = snapshot.selectedModelID, isInstalled(id) {
            verifyThenWarm(id)
        }
        emitChange()
    }

    func refreshPermissions() {
        emitChange()
    }

    func refreshPermissionsAndDevices() {
        refreshDevices()
        emitChange()
    }

    var shortcut: TriggerShortcut {
        get { TriggerShortcut(spec: snapshot.shortcut) }
        set {
            let spec = TriggerSpec(shortcut: newValue)
            guard spec != snapshot.shortcut else { return }
            snapshot.shortcut = spec
            persistSnapshot()
            onTriggerChanged?()
            emitChange()
        }
    }

    var selectedModelID: String? {
        get { snapshot.selectedModelID }
        set { updateSelection(newValue) }
    }

    var selectedMicrophoneID: String? {
        get { snapshot.microphone.selectedUID }
        set {
            let label = newValue.flatMap { uid in
                microphoneItems.first { $0.id == uid }?.name
            }
            let next = MicrophoneSelection(pinnedUID: newValue, label: label)
            guard next != snapshot.microphone else { return }
            snapshot.microphone = next
            persistSnapshot()
            emitChange()
        }
    }

    var launchAtLogin: Bool {
        get { loginItems.isEnabled }
        set {
            do {
                try loginItems.setEnabled(newValue)
            } catch {
                emitChange()
                return
            }
            guard snapshot.launchAtLogin != newValue else {
                emitChange()
                return
            }
            snapshot.launchAtLogin = newValue
            persistSnapshot()
            emitChange()
        }
    }

    var models: [ModelItem] {
        catalog.map { entry in
            ModelItem(id: entry.manifest.modelID,
                      title: entry.title,
                      isRecommended: entry.isRecommended,
                      state: displayState(for: entry.manifest.modelID))
        }
    }

    var microphones: [MicrophoneItem] {
        microphoneItems
    }

    var microphonePermission: PermissionState {
        PermissionState(microphonePermission: permissions.microphone())
    }

    var accessibilityPermission: PermissionState {
        PermissionState(accessibilityPermission: permissions.accessibility())
    }

    func requestMicrophonePermission() async -> Bool {
        let granted = await permissions.requestMicrophone()
        emitChange()
        return granted
    }

    func openMicrophoneSettings() {
        openPrivacyPane("Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        _ = permissions.requestAccessibilityPrompt()
        openPrivacyPane("Privacy_Accessibility")
    }

    func downloadModel(id: String) {
        guard !sessionActive, let entry = catalogEntry(id) else { return }
        updateSelection(id)
        guard activeDownloadID == nil, !isInstalled(id) else { return }
        switch displayState(for: id) {
        case .notInstalled, .downloadFailed, .checksumFailed:
            break
        default:
            return
        }
        installGeneration &+= 1
        let generation = installGeneration
        activeDownloadID = id
        transientStates[id] = .downloading(ModelState.DownloadProgress(
            fraction: entry.totalBytes > 0 ? 0 : nil,
            receivedBytes: 0,
            totalBytes: entry.totalBytes))
        emitChange()
        let box = ProgressBox()
        installTask = Task { [weak self] in
            guard let self else { return }
            let outcome: Result<Void, Error>
            do {
                try await self.modelStore.install(entry.manifest) { [weak self] progress in
                    guard box.record(progress) else { return }
                    MainHop.async {
                        self?.applyDownloadProgress(id: id, box: box, generation: generation)
                    }
                }
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            guard self.started,
                  generation == self.installGeneration,
                  self.activeDownloadID == id else { return }
            self.activeDownloadID = nil
            self.installTask = nil
            switch outcome {
            case .success:
                self.transientStates[id] = nil
            case .failure(let error):
                if let storeError = error as? ModelStoreError {
                    self.transientStates[id] = self.installFailure(storeError)
                } else {
                    self.transientStates[id] = .downloadFailed
                }
            }
            self.installStates[id] = await self.currentInstallState(entry)
            if case .success = outcome,
               self.snapshot.selectedModelID == id,
               let directory = await self.modelStore.installedModelDirectory(for: id) {
                self.verifiedLocation = LiveModelLocation(id: id, directory: directory)
                self.warm(id)
            }
            self.emitChange()
        }
    }

    func loadModel(id: String) {
        guard !sessionActive else { return }
        updateSelection(id)
        guard isInstalled(id) else { return }
        verifyThenWarm(id)
    }

    private func updateSelection(_ id: String?) {
        guard !sessionActive, id != snapshot.selectedModelID else { return }
        snapshot.selectedModelID = id
        persistSnapshot()
        if let id, isInstalled(id) {
            verifyThenWarm(id)
        }
        emitChange()
    }

    private func verifyThenWarm(_ id: String) {
        guard started, let entry = catalogEntry(id) else { return }
        if verifiedLocation?.id == id {
            warm(id)
            return
        }
        guard !verifyingSelections.contains(id) else { return }
        verifyingSelections.insert(id)
        transientStates[id] = .verifying
        emitChange()
        Task { [weak self] in
            guard let self else { return }
            let verified = await self.modelStore.verifyInstalled(entry.manifest)
            guard self.started else { return }
            self.verifyingSelections.remove(id)
            self.transientStates[id] = nil
            self.installStates[id] = await self.currentInstallState(entry)
            defer { self.emitChange() }
            guard verified else {
                self.installStates[id] = .corrupt
                self.transientStates[id] = .checksumFailed
                if self.verifiedLocation?.id == id { self.verifiedLocation = nil }
                return
            }
            guard self.started, self.snapshot.selectedModelID == id,
                  case .installed = self.installStates[id] ?? .notInstalled,
                  let directory = await self.modelStore.installedModelDirectory(for: id)
            else { return }
            self.verifiedLocation = LiveModelLocation(id: id, directory: directory)
            self.warm(id)
        }
    }

    private func warm(_ id: String) {
        guard started, !sessionActive,
              verifiedLocation?.id == id,
              let directory = verifiedLocation?.directory
        else { return }
        if let track = loadTracks[id], track.outcome != .failed { return }
        var track = loadTracks[id] ?? LoadTrack(generation: 0, outcome: .loading)
        track.generation &+= 1
        track.outcome = .loading
        loadTracks[id] = track
        let generation = track.generation
        emitChange()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transcription.loadModel(id: id, directory: directory)
                self.completeLoad(id, generation: generation, succeeded: true)
            } catch {
                self.completeLoad(id, generation: generation, succeeded: false)
            }
        }
    }

    private func completeLoad(_ id: String, generation: UInt64, succeeded: Bool) {
        guard started,
              loadTracks[id]?.generation == generation,
              loadTracks[id]?.outcome == .loading
        else { return }
        if !succeeded {
            loadTracks[id] = LoadTrack(generation: generation, outcome: .failed)
        } else if snapshot.selectedModelID == id {
            loadTracks[id] = LoadTrack(generation: generation, outcome: .ready)
            let stale = loadTracks.filter { $0.key != id && $0.value.outcome == .ready }.map(\.key)
            for other in stale {
                loadTracks.removeValue(forKey: other)
            }
        } else {
            loadTracks.removeValue(forKey: id)
        }
        emitChange()
    }

    private func applyDownloadProgress(id: String, box: ProgressBox, generation: UInt64) {
        guard started,
              generation == installGeneration,
              activeDownloadID == id,
              let progress = box.take()
        else { return }
        transientStates[id] = Self.mapProgress(progress)
        emitChange()
    }

    private func installFailure(_ error: ModelStoreError) -> ModelState? {
        switch error {
        case .hashMismatch, .sizeMismatch:
            return .checksumFailed
        case .cancelled, .blockedByActiveSession, .busy:
            return nil
        case .downloadFailed, .stalled, .installFailed, .invalidManifest:
            return .downloadFailed
        }
    }

    private func displayState(for id: String) -> ModelState {
        if let transient = transientStates[id] { return transient }
        switch installStates[id] ?? .notInstalled {
        case .notInstalled:
            return .notInstalled
        case .verifying:
            return .verifying
        case .corrupt:
            return .checksumFailed
        case .installed:
            guard id == snapshot.selectedModelID else { return .ready }
            switch loadTracks[id]?.outcome {
            case .ready: return .ready
            case .failed: return .loadFailed
            case .loading, nil: return .loading
            }
        }
    }

    private func adoptPersisted(_ value: AppSettings) {
        guard started else { return }
        if pendingWrites.first == value {
            pendingWrites.removeFirst()
            return
        }
        pendingWrites.removeAll()
        let triggerChanged = value.shortcut != snapshot.shortcut
        let selectionChanged = value.selectedModelID != snapshot.selectedModelID
        snapshot = value
        if selectionChanged, let id = value.selectedModelID, isInstalled(id) {
            verifyThenWarm(id)
        }
        if triggerChanged { onTriggerChanged?() }
        emitChange()
    }

    private func persistSnapshot() {
        let next = snapshot
        let previous = persistChain
        pendingWrites.append(next)
        persistChain = Task { [settingsStore] in
            _ = await previous?.value
            await settingsStore.update { $0 = next }
        }
    }

    private func refreshInstallStates() async {
        var next: [String: ModelInstallState] = [:]
        for entry in catalog {
            next[entry.manifest.modelID] = await currentInstallState(entry)
        }
        installStates = next
    }

    private func currentInstallState(_ entry: CatalogModel) async -> ModelInstallState {
        let state = await modelStore.state(for: entry.manifest)
        if case .installed(let version) = state, version != entry.manifest.version {
            return .notInstalled
        }
        return state
    }

    private func refreshDevices() {
        microphoneItems = ((try? devices.inputDevices()) ?? [])
            .map { MicrophoneItem(id: $0.uid, name: $0.name) }
    }

    private func handleDeviceChange() {
        guard started else { return }
        refreshDevices()
        emitChange()
    }

    private func catalogEntry(_ id: String) -> CatalogModel? {
        catalog.first { $0.manifest.modelID == id }
    }

    private func isInstalled(_ id: String) -> Bool {
        if case .installed = installStates[id] { return true }
        return false
    }

    private func emitChange() {
        model.apply(shortcut: TriggerShortcut(spec: snapshot.shortcut))
        model.applyReadiness(
            microphone: microphonePermission,
            accessibility: accessibilityPermission,
            selectedModel: models.first { $0.id == snapshot.selectedModelID })
        onChange?()
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private static func mapProgress(_ progress: ModelDownloadProgress) -> ModelState {
        switch progress.phase {
        case .verifying:
            return .verifying
        case .downloading:
            let fraction = progress.expectedBytes.flatMap { expected in
                expected > 0
                    ? min(max(Double(progress.completedBytes) / Double(expected), 0), 1)
                    : nil
            }
            return .downloading(ModelState.DownloadProgress(
                fraction: fraction,
                receivedBytes: progress.completedBytes,
                totalBytes: progress.expectedBytes))
        }
    }

    private static func loadCatalog() -> [CatalogModel] {
        let url = modelResourceRoot().appending(path: "Models/catalog.json")
        guard let data = try? Data(contentsOf: url),
              let manifests = try? JSONDecoder().decode([ModelManifest].self, from: data)
        else { return [] }
        var seen = Set<String>()
        return manifests.compactMap { manifest in
            guard seen.insert(manifest.modelID).inserted, !manifest.artifacts.isEmpty else {
                return nil
            }
            return CatalogModel(
                manifest: manifest,
                title: ModelDisplayMetadata.title(for: manifest.modelID),
                isRecommended: false)
        }
    }

    private static func modelResourceRoot() -> URL {
        if let resources = Bundle.main.resourceURL {
            let candidate = resources.appending(path: "Models/catalog.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return resources
            }
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources", directoryHint: .isDirectory)
    }

    private static func modelRootDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let current = base
            .appending(path: LegacyInstallationMigration.bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
        let legacy = base
            .appending(path: LegacyInstallationMigration.legacyBundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
        do {
            try LegacyInstallationMigration.migrateModels(from: legacy, to: current)
        } catch {
            AppLog.settings.error("Legacy model directory migration failed code=\((error as NSError).code)")
            if !FileManager.default.fileExists(atPath: current.path) { return legacy }
        }
        return current
    }

    private struct LoadTrack {
        enum Outcome: Equatable {
            case loading
            case ready
            case failed
        }

        var generation: UInt64
        var outcome: Outcome
    }

    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: ModelDownloadProgress?
        private var flushQueued = false

        func record(_ progress: ModelDownloadProgress) -> Bool {
            lock.withLock {
                latest = progress
                if flushQueued { return false }
                flushQueued = true
                return true
            }
        }

        func take() -> ModelDownloadProgress? {
            lock.withLock {
                flushQueued = false
                return latest
            }
        }
    }
}

private extension CatalogModel {
    var totalBytes: Int64 {
        manifest.artifacts.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
    }
}
