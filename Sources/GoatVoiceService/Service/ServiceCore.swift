import Foundation

actor ServiceCore {
    struct SessionKey: Hashable {
        var connectionID: UUID
        var sessionID: String
    }

    struct FinishContext: Sendable {
        fileprivate(set) var key: SessionKey
        fileprivate(set) var generation: UInt64
        fileprivate(set) var audioData: Data
        fileprivate(set) var deadline: Date
    }

    private struct SessionState {
        var generation: UInt64
        var audio: AudioAccumulator
        var accepting: Bool
        var inference: Task<String, Error>?
        var preview: Task<String, Error>?
        var previewedBytes = 0
    }

    private let host: EngineHost
    private let instanceID = UUID().uuidString
    private var sessions: [SessionKey: SessionState] = [:]
    private var nextGeneration: UInt64 = 0

    init(provider: any LocalBackendProviding) {
        host = EngineHost(provider: provider)
    }

    func handshakePayload() async -> NSDictionary {
        [
            "protocolVersion": ServiceBounds.protocolVersion,
            "serviceInstanceID": instanceID,
            "modelID": await host.selectedModelID ?? NSNull(),
            "modelState": await host.modelStateName,
            "engines": await host.availability().mapValues { $0 ? "available" : "unavailable" },
        ]
    }

    func loadModel(_ modelID: String, directory: URL) async throws {
        try await host.load(modelID: modelID, directory: directory)
    }

    func unloadModel() async {
        for key in sessions.keys {
            await cancelSession(key.sessionID, connectionID: key.connectionID)
        }
        await host.unload()
    }

    func retireForeignSessions(keeping connectionID: UUID) async {
        for key in sessions.keys where key.connectionID != connectionID {
            dropSession(key)
            await host.sessionClosed()
        }
    }

    func beginSession(_ sessionID: String, connectionID: UUID) async throws {
        try await host.ensureSessionStartable()
        let key = SessionKey(connectionID: connectionID, sessionID: sessionID)
        if var existing = sessions[key] {
            existing.inference?.cancel()
            existing.preview?.cancel()
            existing.inference = nil
            existing.preview = nil
            existing.previewedBytes = 0
            existing.audio.drop()
            existing.generation = nextGeneration
            nextGeneration &+= 1
            existing.accepting = true
            sessions[key] = existing
            return
        }
        guard sessions.count < ServiceBounds.maxSessions else {
            throw GoatVoiceServiceError.sessionLimitExceeded
        }
        sessions[key] = SessionState(
            generation: nextGeneration,
            audio: AudioAccumulator(),
            accepting: true
        )
        nextGeneration &+= 1
        await host.sessionOpened()
    }

    func pushAudio(_ sessionID: String, connectionID: UUID,
                   chunk: Data, offset: UInt64) throws {
        let key = SessionKey(connectionID: connectionID, sessionID: sessionID)
        guard var session = sessions[key] else {
            throw GoatVoiceServiceError.sessionUnknown
        }
        guard session.accepting else {
            throw GoatVoiceServiceError.sessionClosed
        }
        defer { sessions[key] = session }
        try session.audio.append(chunk, atOffset: offset)
    }

    func previewSession(_ sessionID: String, connectionID: UUID) async throws -> String {
        let key = SessionKey(connectionID: connectionID, sessionID: sessionID)
        guard let session = sessions[key] else { throw GoatVoiceServiceError.sessionUnknown }
        guard session.accepting else { throw GoatVoiceServiceError.sessionClosed }
        guard session.preview == nil, session.inference == nil else {
            throw GoatVoiceServiceError.busyLoading
        }
        guard !session.audio.hasDrops,
              session.audio.byteCount >= ServiceBounds.previewMinimumBytes,
              session.audio.byteCount - session.previewedBytes >= ServiceBounds.previewIncrementBytes else { return "" }
        let audio = session.audio.data.withUnsafeBytes { raw in
            Data(raw.suffix(ServiceBounds.previewWindowBytes))
        }
        let byteCount = session.audio.byteCount
        let generation = session.generation
        let work = Task { [host] in
            let backend = try await host.readyBackend()
            try Task.checkCancellation()
            guard let previewing = backend as? any LocalASRPreviewing else {
                throw GoatVoiceServiceError.backendUnavailable
            }
            let samples = await Task.detached {
                AudioAccumulator.floatSamples(from: audio)
            }.value
            guard PreviewAudioPolicy.containsSignal(samples) else { return "" }
            return try await previewing.preview(samples: samples)
        }
        sessions[key]?.preview = work
        defer {
            if sessions[key]?.generation == generation {
                sessions[key]?.preview = nil
            }
        }
        let text = try await work.value
        guard let current = sessions[key], current.generation == generation,
              current.accepting else { throw GoatVoiceServiceError.cancelled }
        sessions[key]?.previewedBytes = byteCount
        return String(text.suffix(ServiceBounds.previewMaximumCharacters))
    }

    func prepareFinish(_ sessionID: String, connectionID: UUID,
                       canonicalAudio: Data?, deadline: Date) async throws -> FinishContext {
        let key = SessionKey(connectionID: connectionID, sessionID: sessionID)
        guard let session = sessions[key] else {
            throw GoatVoiceServiceError.sessionUnknown
        }
        guard session.accepting else {
            throw GoatVoiceServiceError.sessionClosed
        }
        sessions[key]?.accepting = false
        let audioData: Data
        if let canonicalAudio {
            guard canonicalAudio.count <= ServiceBounds.maxSessionAudioBytes else {
                dropSession(key)
                await host.sessionClosed()
                throw GoatVoiceServiceError.sessionAudioLimitExceeded
            }
            audioData = canonicalAudio
        } else {
            guard !session.audio.hasDrops else {
                dropSession(key)
                await host.sessionClosed()
                throw GoatVoiceServiceError.invalidArgument
            }
            audioData = session.audio.data
        }
        let ceiling = Date().addingTimeInterval(
            ServiceBounds.postReleaseBudgetSeconds(audioBytes: audioData.count)
        )
        return FinishContext(
            key: key,
            generation: session.generation,
            audioData: audioData,
            deadline: min(deadline, ceiling)
        )
    }

    func completeFinish(_ context: FinishContext) async throws -> String {
        guard let session = sessions[context.key],
              session.generation == context.generation,
              !session.accepting,
              session.inference == nil else {
            throw GoatVoiceServiceError.cancelled
        }
        let audioData = context.audioData
        let preview = session.preview
        let inference = Task { [host] in
            if let preview {
                try await Deadline.race(until: context.deadline) { _ = await preview.result }
            }
            try Task.checkCancellation()
            let backend = try await host.readyBackend()
            let samples = await Task.detached {
                AudioAccumulator.floatSamples(from: audioData)
            }.value
            return try await backend.transcribe(samples: samples)
        }
        sessions[context.key]?.inference = inference
        defer {
            if sessions[context.key]?.generation == context.generation {
                sessions[context.key]?.inference = nil
            }
        }
        do {
            let text = try await Deadline.race(until: context.deadline) {
                try await inference.value
            }
            try await resolveFinish(key: context.key, generation: context.generation)
            return text
        } catch {
            inference.cancel()
            do {
                try await resolveFinish(key: context.key, generation: context.generation)
            } catch {
                throw GoatVoiceServiceError.cancelled
            }
            throw error
        }
    }

    func cancelSession(_ sessionID: String, connectionID: UUID) async {
        let key = SessionKey(connectionID: connectionID, sessionID: sessionID)
        guard sessions[key] != nil else { return }
        dropSession(key)
        await host.sessionClosed()
    }

    func cancelConnection(_ connectionID: UUID) async {
        for (key, _) in sessions where key.connectionID == connectionID {
            dropSession(key)
            await host.sessionClosed()
        }
    }

    private func dropSession(_ key: SessionKey) {
        guard var session = sessions.removeValue(forKey: key) else { return }
        session.inference?.cancel()
        session.preview?.cancel()
        session.inference = nil
        session.preview = nil
        session.audio.drop()
    }

    private func resolveFinish(key: SessionKey, generation: UInt64) async throws {
        guard let session = sessions[key],
              session.generation == generation,
              !session.accepting else {
            throw GoatVoiceServiceError.cancelled
        }
        dropSession(key)
        await host.sessionClosed()
    }
}
