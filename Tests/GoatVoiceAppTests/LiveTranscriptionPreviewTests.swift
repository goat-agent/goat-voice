import XCTest
@testable import GoatVoiceApp

private actor PreviewRequests {
    private var pending: CheckedContinuation<String, Never>?
    private(set) var count = 0

    func request(_ session: String) async throws -> String {
        count += 1
        return await withCheckedContinuation { pending = $0 }
    }

    func resolve(_ text: String) {
        pending?.resume(returning: text)
        pending = nil
    }
}

@MainActor
final class LiveTranscriptionPreviewTests: XCTestCase {
    private func awaitRequest(_ requests: PreviewRequests) async throws {
        for _ in 0..<200 {
            if await requests.count > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Preview request did not start")
    }

    func testStoppedPreviewCannotPublishLateResult() async throws {
        let requests = PreviewRequests()
        var published: [String?] = []
        let preview = LiveTranscriptionPreview(interval: .milliseconds(5),
                                               request: { try await requests.request($0) },
                                               publish: { published.append($0) })
        preview.start(sessionID: "first")
        try await awaitRequest(requests)
        preview.stop(clear: true)
        await requests.resolve("stale result")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(published.contains { $0 != nil })
    }

    func testActualPreviewIsPublishedAndClearedAtNextSession() async throws {
        let requests = PreviewRequests()
        var published: String?
        let preview = LiveTranscriptionPreview(interval: .milliseconds(5),
                                               request: { try await requests.request($0) },
                                               publish: { published = $0 })
        preview.start(sessionID: "first")
        try await awaitRequest(requests)
        await requests.resolve("  provisional words  ")
        for _ in 0..<100 {
            if published != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(published, "provisional words")
        preview.stop(clear: false)
        XCTAssertEqual(published, "provisional words")
        preview.start(sessionID: "second")
        XCTAssertNil(published)
        preview.stop(clear: true)
        await requests.resolve("ignored")
    }
}
