import Foundation

#if canImport(WhisperKit)
import WhisperKit

actor WhisperKitBackend: LocalASRBackend {
    nonisolated static var isAvailable: Bool { true }

    private var whisper: OfflineWhisperKit?
    private var inference: BackendInferenceOperation?
    private var unloading = false

    func load(directory: URL) async throws {
        guard inference == nil, !unloading else {
            throw GoatVoiceServiceError.busyLoading
        }
        try Self.preflight(directory: directory)
        let config = WhisperKitConfig(
            modelFolder: directory.path,
            tokenizerFolder: directory,
            verbose: false,
            logLevel: .none,
            load: true,
            download: false
        )
        let kit: OfflineWhisperKit
        do {
            kit = try await OfflineWhisperKit(config: config, tokenizerDirectory: directory)
        } catch let error as GoatVoiceServiceError {
            throw error
        } catch is CancellationError {
            throw GoatVoiceServiceError.cancelled
        } catch {
            throw GoatVoiceServiceError.modelLoadFailed
        }
        guard kit.tokenizer != nil else {
            throw GoatVoiceServiceError.modelCorrupt
        }
        whisper = kit
    }

    func transcribe(samples: [Float]) async throws -> String {
        while let pending = inference {
            try await pending.waitForCompletion()
            releaseInference(pending.id)
        }
        try Task.checkCancellation()
        guard !unloading, let whisper, whisper.tokenizer != nil else {
            throw GoatVoiceServiceError.modelNotSelected
        }
        guard inference == nil else {
            throw GoatVoiceServiceError.inferenceFailed
        }
        let box = UncheckedSendableBox(whisper)
        let latch = TranscriptionLatch()
        let work = Task {
            let options = DecodingOptions(
                detectLanguage: true,
                skipSpecialTokens: true,
                withoutTimestamps: true
            )
            let results = try await box.value.transcribe(
                audioArray: samples,
                decodeOptions: options
            )
            return results.map(\.text).joined()
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
            work.cancel()
            latch.resume(with: .failure(GoatVoiceServiceError.cancelled))
        }
    }

    func unload() async {
        unloading = true
        defer { unloading = false }
        if let operation = inference {
            operation.task.cancel()
            _ = await operation.task.result
        }
        inference = nil
        if let whisper {
            await whisper.unloadModels()
        }
        whisper = nil
    }

    func preview(samples: [Float]) async throws -> String {
        guard !unloading, let whisper, whisper.tokenizer != nil else {
            throw GoatVoiceServiceError.modelNotSelected
        }
        guard inference == nil else { throw GoatVoiceServiceError.busyLoading }
        let box = UncheckedSendableBox(whisper)
        let work = Task {
            try Task.checkCancellation()
            let results = try await box.value.transcribe(
                audioArray: samples,
                decodeOptions: DecodingOptions(
                    temperatureFallbackCount: 0,
                    sampleLength: ServiceBounds.previewMaximumTokens,
                    detectLanguage: true,
                    skipSpecialTokens: true,
                    withoutTimestamps: true
                )
            )
            try Task.checkCancellation()
            return results.map(\.text).joined()
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
            "AudioEncoder.mlmodelc",
            "MelSpectrogram.mlmodelc",
            "TextDecoder.mlmodelc",
            "config.json",
            "generation_config.json",
            "tokenizer.json",
        ]
        for entry in requiredEntries {
            let path = directory.appendingPathComponent(entry).path
            guard fileManager.fileExists(atPath: path) else {
                throw GoatVoiceServiceError.modelNotInstalled
            }
        }
    }
}

extension WhisperKitBackend: LocalASRPreviewing {}

final class OfflineWhisperKit: WhisperKit {
    private let tokenizerDirectory: URL

    init(config: WhisperKitConfig, tokenizerDirectory: URL) async throws {
        self.tokenizerDirectory = tokenizerDirectory
        try await super.init(config)
    }

    override func loadTokenizerIfNeeded() async throws {
        guard tokenizer == nil else { return }
        guard let logitsDim = textDecoder.logitsSize else {
            throw WhisperError.tokenizerUnavailable()
        }
        textDecoder.isModelMultilingual = logitsDim != 51864
        let wrapper: TokenizerWrapper
        do {
            wrapper = try await AutoTokenizerWrapper.from(modelFolder: tokenizerDirectory)
        } catch let error as GoatVoiceServiceError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GoatVoiceServiceError.modelCorrupt
        }
        tokenizer = try LocalWhisperTokenizer(wrapper: wrapper)
    }
}

final class LocalWhisperTokenizer: WhisperTokenizer {
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    private let impl: TokenizerWrapper

    init(wrapper: TokenizerWrapper) throws {
        impl = wrapper
        func requiredId(_ token: String) throws -> Int {
            guard let id = wrapper.convertTokenToId(token) else {
                throw GoatVoiceServiceError.modelCorrupt
            }
            return id
        }
        let endToken = try requiredId("<|endoftext|>")
        specialTokens = SpecialTokens(
            endToken: endToken,
            englishToken: try requiredId("<|en|>"),
            noSpeechToken: try requiredId("<|nospeech|>"),
            noTimestampsToken: try requiredId("<|notimestamps|>"),
            specialTokenBegin: endToken,
            startOfPreviousToken: try requiredId("<|startofprev|>"),
            startOfTranscriptToken: try requiredId("<|startoftranscript|>"),
            timeTokenBegin: try requiredId("<|0.00|>"),
            transcribeToken: try requiredId("<|transcribe|>"),
            translateToken: try requiredId("<|translate|>"),
            whitespaceToken: try requiredId(" ")
        )
        allLanguageTokens = Set(
            Constants.languages.values
                .compactMap { wrapper.convertTokenToId("<|\($0)|>") }
                .filter { $0 > endToken }
        )
    }

    func encode(text: String) -> [Int] {
        impl.encode(text: text)
    }

    func decode(tokens: [Int]) -> String {
        impl.decode(tokens: tokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        impl.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        impl.convertIdToToken(id)
    }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        var words: [String] = []
        var wordTokens: [[Int]] = []
        for id in tokenIds where id < specialTokens.specialTokenBegin {
            let piece = impl.decode(tokens: [id])
            if piece.hasPrefix(" ") || words.isEmpty {
                words.append(piece)
                wordTokens.append([id])
            } else {
                words[words.count - 1] += piece
                wordTokens[words.count - 1].append(id)
            }
        }
        return (words, wordTokens)
    }
}

#else

actor WhisperKitBackend: LocalASRBackend {
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
