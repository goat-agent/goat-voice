import Foundation

#if canImport(MLXAudioSTT) && canImport(MLX)
import MLX
import MLXAudioSTT

actor Qwen3ASRBackend: LocalASRBackend {
    nonisolated static var isAvailable: Bool { true }

    private var model: Qwen3ASRModel?
    private var inference: BackendInferenceOperation?
    private var unloading = false

    func load(directory: URL) async throws {
        guard inference == nil, !unloading else {
            throw GoatVoiceServiceError.busyLoading
        }
        try Self.preflight(directory: directory)
        do {
            model = try await Qwen3ASRModel.fromModelDirectory(directory)
        } catch is CancellationError {
            throw GoatVoiceServiceError.cancelled
        } catch {
            throw GoatVoiceServiceError.modelLoadFailed
        }
    }

    func transcribe(samples: [Float]) async throws -> String {
        while let pending = inference {
            try await pending.waitForCompletion()
            releaseInference(pending.id)
        }
        try Task.checkCancellation()
        guard !unloading, let model else {
            throw GoatVoiceServiceError.modelNotSelected
        }
        guard inference == nil else {
            throw GoatVoiceServiceError.inferenceFailed
        }
        let box = UncheckedSendableBox(model)
        let latch = TranscriptionLatch()
        let work = Task {
            var finalText: String?
            let stream = box.value.generateStream(
                audio: MLXArray(samples),
                generationParameters: STTGenerateParameters()
            )
            for try await event in stream {
                if case .result(let output) = event {
                    finalText = output.text
                }
            }
            guard let finalText else {
                throw CancellationError()
            }
            return finalText
        }
        let operation = BackendInferenceOperation(purpose: .final, task: work)
        inference = operation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                latch.arm(continuation)
                Task { [weak self] in
                    let result = await work.result
                    await self?.releaseInference(operation.id)
                    switch result {
                    case .success(let text):
                        latch.resume(with: .success(text))
                    case .failure(is CancellationError):
                        latch.resume(with: .failure(GoatVoiceServiceError.cancelled))
                    case .failure(let error):
                        latch.resume(with: .failure(error))
                    }
                }
            }
        } onCancel: {
            latch.resume(with: .failure(GoatVoiceServiceError.cancelled))
        }
    }

    func unload() async {
        unloading = true
        defer { unloading = false }
        if let operation = inference {
            if operation.purpose == .preview { operation.task.cancel() }
            _ = await operation.task.result
        }
        inference = nil
        model = nil
        Memory.clearCache()
    }

    func preview(samples: [Float]) async throws -> String {
        guard !unloading, let model else { throw GoatVoiceServiceError.modelNotSelected }
        guard inference == nil else { throw GoatVoiceServiceError.busyLoading }
        let box = UncheckedSendableBox(model)
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = box.value.generate(
                audio: MLXArray(samples),
                generationParameters: STTGenerateParameters(maxTokens: ServiceBounds.previewMaximumTokens)
            )
            try Task.checkCancellation()
            return result.text
        }
        let operation = BackendInferenceOperation(purpose: .preview, task: work)
        inference = operation
        defer { releaseInference(operation.id) }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func releaseInference(_ id: UUID) {
        if inference?.id == id { inference = nil }
    }

    private static func preflight(directory: URL) throws {
        let fileManager = FileManager.default
        let requiredEntries = [
            "config.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "vocab.json",
            "merges.txt",
        ]
        for entry in requiredEntries {
            let path = directory.appendingPathComponent(entry).path
            guard fileManager.fileExists(atPath: path) else {
                throw GoatVoiceServiceError.modelNotInstalled
            }
        }
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let hasWeights = contents.contains { url in
            guard url.pathExtension == "safetensors" else { return false }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return size > 0
        }
        guard hasWeights else {
            throw GoatVoiceServiceError.modelNotInstalled
        }
        let configPath = directory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configPath),
              (try? JSONSerialization.jsonObject(with: data)) != nil
        else {
            throw GoatVoiceServiceError.modelCorrupt
        }
    }
}

extension Qwen3ASRBackend: LocalASRCacheTrimming {
    func trimCache() async {
        if inference == nil {
            Memory.clearCache()
        }
    }
}

extension Qwen3ASRBackend: LocalASRPreviewing {}

#else

actor Qwen3ASRBackend: LocalASRBackend {
    nonisolated static var isAvailable: Bool { false }

    func load(directory: URL) async throws {
        throw GoatVoiceServiceError.backendUnavailable
    }

    func transcribe(samples: [Float]) async throws -> String {
        throw GoatVoiceServiceError.backendUnavailable
    }

    func unload() async {}
}

#endif
