import Foundation

@MainActor
final class LiveTranscriptionPreview {
    private let interval: Duration
    private let request: @Sendable (String) async throws -> String
    private let publish: @MainActor (String?) -> Void
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(interval: Duration = .milliseconds(1500),
         request: @escaping @Sendable (String) async throws -> String,
         publish: @escaping @MainActor (String?) -> Void) {
        self.interval = interval
        self.request = request
        self.publish = publish
    }

    func start(sessionID: String) {
        stop(clear: true)
        let generation = generation
        let interval = interval
        let request = request
        task = Task { [weak self] in
            var reportedFailure = false
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                    let text = try await request(sessionID)
                    guard let self, self.generation == generation, !Task.isCancelled else { return }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { self.publish(String(trimmed.suffix(600))) }
                } catch is CancellationError {
                    return
                } catch {
                    guard self?.generation == generation, !Task.isCancelled else { return }
                    if !reportedFailure {
                        AppLog.session.notice("Live preview request failed; final transcription remains available")
                        reportedFailure = true
                    }
                }
            }
        }
    }

    func stop(clear: Bool) {
        generation &+= 1
        task?.cancel()
        task = nil
        if clear { publish(nil) }
    }
}
