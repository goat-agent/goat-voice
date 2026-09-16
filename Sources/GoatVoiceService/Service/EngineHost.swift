import Dispatch
import Foundation

actor EngineHost {
    struct ModelSelection: Sendable {
        var modelID: String
        var directory: URL
    }

    private final class EngineSlot: @unchecked Sendable {
        enum Phase {
            case loading
            case loaded
            case retiring
        }

        let id = UUID()
        let selection: ModelSelection
        let backend: any LocalASRBackend
        let producer: Task<any LocalASRBackend, Error>
        let deadline: Date
        var watchdog: Task<Void, Never>?
        var watcher: Task<Void, Never>?
        var retireTask: Task<Void, Never>?
        var phase: Phase = .loading
        var timedOut = false

        init(selection: ModelSelection, backend: any LocalASRBackend,
             producer: Task<any LocalASRBackend, Error>, deadline: Date) {
            self.selection = selection
            self.backend = backend
            self.producer = producer
            self.deadline = deadline
        }
    }

    private var slot: EngineSlot?
    private var lastError: NSError?
    private var selected: ModelSelection?
    private var liveSessions = 0
    private let watchdog: TimeInterval
    private let pressureSource: DispatchSourceMemoryPressure
    private let provider: any LocalBackendProviding

    var selectedModelID: String? { selected?.modelID }

    var modelStateName: String {
        guard let slot else {
            return lastError == nil ? "unloaded" : "failed"
        }
        switch slot.phase {
        case .loading: return "loading"
        case .loaded: return "loaded"
        case .retiring: return "unloaded"
        }
    }

    func availability() -> [String: Bool] { provider.availability() }

    init(provider: any LocalBackendProviding,
         watchdog: TimeInterval = ServiceBounds.loadWatchdogSeconds) {
        self.provider = provider
        self.watchdog = watchdog
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        pressureSource = source
        source.setEventHandler { [weak self] in
            let raw = source.data.rawValue
            Task { await self?.handleMemoryPressure(rawValue: raw) }
        }
        source.resume()
    }

    func sessionOpened() { liveSessions += 1 }
    func sessionClosed() { liveSessions = max(0, liveSessions - 1) }

    func ensureSessionStartable() throws {
        if let slot {
            switch slot.phase {
            case .loaded, .loading:
                return
            case .retiring:
                throw GoatVoiceServiceError.busyLoading
            }
        }
        if let lastError {
            throw lastError
        }
        guard let selection = selected else {
            throw GoatVoiceServiceError.modelNotSelected
        }
        slot = try makeSlot(selection)
    }

    func load(modelID: String, directory: URL) async throws {
        if let slot {
            switch slot.phase {
            case .loaded:
                if slot.selection.modelID == modelID { return }
                if liveSessions > 0 {
                    throw GoatVoiceServiceError.busyLoading
                }
                guard await retireSlot() else {
                    throw GoatVoiceServiceError.busyLoading
                }
            case .loading:
                if slot.selection.modelID == modelID {
                    try await awaitReady(slot)
                    return
                }
                throw GoatVoiceServiceError.busyLoading
            case .retiring:
                throw GoatVoiceServiceError.busyLoading
            }
        }
        let selection = ModelSelection(modelID: modelID, directory: directory)
        let newSlot = try makeSlot(selection)
        selected = selection
        lastError = nil
        slot = newSlot
        try await awaitReady(newSlot)
    }

    func readyBackend() async throws -> any LocalASRBackend {
        guard let slot else {
            if let lastError {
                throw lastError
            }
            guard let selection = selected else {
                throw GoatVoiceServiceError.modelNotSelected
            }
            let newSlot = try makeSlot(selection)
            self.slot = newSlot
            try await awaitReady(newSlot)
            return newSlot.backend
        }
        switch slot.phase {
        case .loaded:
            return slot.backend
        case .loading:
            try await awaitReady(slot)
            return slot.backend
        case .retiring:
            throw GoatVoiceServiceError.busyLoading
        }
    }

    func unload() async {
        _ = await retireSlot()
        selected = nil
    }

    func handleMemoryPressure(rawValue: UInt) async {
        let event = DispatchSource.MemoryPressureEvent(rawValue: rawValue)
        if event.contains(.warning), let slot, slot.phase == .loaded,
           let trimming = slot.backend as? any LocalASRCacheTrimming {
            await trimming.trimCache()
        }
        if event.contains(.critical), liveSessions == 0 {
            ServiceLog.lifecycle.notice("critical memory pressure, unloading model")
            _ = await retireSlot()
        }
    }

    private func makeSlot(_ selection: ModelSelection) throws -> EngineSlot {
        let backend = try provider.makeBackend(modelID: selection.modelID)
        let directory = selection.directory
        let producer = Task {
            try await backend.load(directory: directory)
            return backend
        }
        let slot = EngineSlot(
            selection: selection,
            backend: backend,
            producer: producer,
            deadline: Date().addingTimeInterval(watchdog)
        )
        let slotID = slot.id
        let nanos = UInt64(max(0, watchdog) * 1_000_000_000)
        slot.watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            await self?.loadDeadlineFired(slotID: slotID)
        }
        slot.watcher = Task { [weak self] in
            let result = await producer.result
            await self?.producerSettled(slotID: slotID, result: result)
        }
        return slot
    }

    private func awaitReady(_ slot: EngineSlot) async throws {
        do {
            _ = try await Deadline.race(until: slot.deadline) {
                try await slot.producer.value
            }
            producerSettled(slotID: slot.id, result: .success(slot.backend))
        } catch let error as GoatVoiceServiceError {
            if error == .deadlineExceeded {
                throw GoatVoiceServiceError.modelLoadTimedOut
            }
            throw error
        } catch {
            if error is CancellationError {
                throw GoatVoiceServiceError.cancelled
            }
            throw Self.mapLoadError(error)
        }
    }

    private func loadDeadlineFired(slotID: UUID) {
        guard let slot, slot.id == slotID, slot.phase == .loading, !slot.timedOut else {
            return
        }
        slot.timedOut = true
        slot.producer.cancel()
        ServiceLog.lifecycle.error("model load watchdog expired")
    }

    private func producerSettled(slotID: UUID,
                                 result: Result<any LocalASRBackend, Error>) {
        guard let slot, slot.id == slotID, slot.phase == .loading else { return }
        slot.watchdog?.cancel()
        switch result {
        case .success:
            slot.phase = .loaded
            ServiceLog.lifecycle.info("model loaded")
        case .failure(let error):
            self.slot = nil
            if slot.timedOut {
                lastError = GoatVoiceServiceError.modelLoadTimedOut.nsError()
            } else if error is CancellationError {
                lastError = nil
            } else {
                let mapped = error.goatVoiceServiceNSError
                ServiceLog.lifecycle.error("model load failed code=\(mapped.code)")
                lastError = mapped
            }
        }
    }

    private func retireSlot() async -> Bool {
        guard let slot else { return true }
        if slot.phase != .retiring {
            slot.phase = .retiring
            slot.watchdog?.cancel()
            slot.producer.cancel()
            let producer = slot.producer
            let backend = slot.backend
            let slotID = slot.id
            slot.retireTask = Task { [weak self] in
                _ = await producer.result
                await backend.unload()
                await self?.retireSettled(slotID: slotID)
            }
        }
        let bound = Date().addingTimeInterval(watchdog)
        _ = try? await Deadline.race(until: bound) { [weak self] in
            while await self?.hasSlot == true {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        return self.slot == nil
    }

    private var hasSlot: Bool { slot != nil }

    private func retireSettled(slotID: UUID) {
        guard let slot, slot.id == slotID, slot.phase == .retiring else { return }
        self.slot = nil
        ServiceLog.lifecycle.info("model unloaded")
    }

    private static func mapLoadError(_ error: Error) -> NSError {
        if let serviceError = error as? GoatVoiceServiceError {
            return serviceError.nsError()
        }
        if error is CancellationError {
            return GoatVoiceServiceError.cancelled.nsError()
        }
        let bridged = error as NSError
        if bridged.domain == GoatVoiceServiceError.domain {
            return bridged
        }
        return GoatVoiceServiceError.modelLoadFailed.nsError(extraUserInfo: [
            "underlyingDomain": bridged.domain,
            "underlyingCode": bridged.code,
        ])
    }
}
