import Foundation

public struct PasteboardSnapshot: Sendable {
    public var items: [[String: Data]]
    public var changeCount: Int
    public var materializedBytes: Int
    fileprivate var ownsTranscript = false
}

public struct ClipboardFence: Sendable, Equatable {
    public var changeCount: Int

    public init(changeCount: Int) {
        self.changeCount = changeCount
    }
}

public enum ClipboardError: Error, Equatable {
    case snapshotExceedsLimit(limit: Int)
    case snapshotUnavailable
    case promisedContentUnavailable
    case transientResidue
    case writeFailed
    case boundaryMismatch
    case preconditionRejected
}

public enum RestoreOutcome: Sendable, Equatable {
    case restored
    case ownershipPreserved
    case restoreFailed
}

public enum PasteGateOutcome: Sendable, Equatable {
    case posted
    case postFailed
    case alreadyAttempted
    case clipboardOwnershipLost
    case preconditionRejected
}

public actor ClipboardCoordinator {
    private let backend: PasteboardBackend
    private let snapshotLimit: Int
    private let transientTypeIdentifiers: [String]
    private let unrestorableTypeIdentifiers: Set<String>
    private var pendingTemporaryCount: Int?
    private var ownedTranscriptCount: Int?

    public init(backend: PasteboardBackend,
                snapshotLimit: Int = ClipboardDefaults.snapshotByteLimit,
                transientTypeIdentifiers: [String] = ClipboardDefaults.transientMarkers,
                unrestorableTypeIdentifiers: Set<String> = ClipboardDefaults.unrestorableTypes) {
        self.backend = backend
        self.snapshotLimit = snapshotLimit
        self.transientTypeIdentifiers = transientTypeIdentifiers
        self.unrestorableTypeIdentifiers = unrestorableTypeIdentifiers
    }

    public func snapshot() throws -> PasteboardSnapshot {
        let boundaryCount = backend.changeCount
        purgeResidue()
        guard boundaryCount != pendingTemporaryCount else {
            throw ClipboardError.transientResidue
        }
        let count = backend.itemCount
        var items: [[String: Data]] = []
        var materializedBytes = 0
        for index in 0..<count {
            var item: [String: Data] = [:]
            for typeIdentifier in backend.typeIdentifiers(ofItemAt: index) {
                if unrestorableTypeIdentifiers.contains(typeIdentifier) {
                    guard boundaryCount == ownedTranscriptCount,
                          transientTypeIdentifiers.contains(typeIdentifier) else {
                        if ClipboardDefaults.transientMarkers.contains(typeIdentifier)
                            || typeIdentifier == "com.stairways.keyboardmaestro.concealed" {
                            throw ClipboardError.snapshotUnavailable
                        }
                        throw ClipboardError.promisedContentUnavailable
                    }
                }
                guard let data = backend.materializeData(itemAt: index, typeIdentifier: typeIdentifier)
                else {
                    throw ClipboardError.snapshotUnavailable
                }
                materializedBytes += data.count
                if materializedBytes > snapshotLimit {
                    throw ClipboardError.snapshotExceedsLimit(limit: snapshotLimit)
                }
                item[typeIdentifier] = data
            }
            items.append(item)
        }
        guard backend.changeCount == boundaryCount else {
            throw ClipboardError.snapshotUnavailable
        }
        return PasteboardSnapshot(
            items: items,
            changeCount: boundaryCount,
            materializedBytes: materializedBytes,
            ownsTranscript: boundaryCount == ownedTranscriptCount
        )
    }

    public func writeTemporaryTranscript(
        _ text: String,
        expectedChangeCount: Int? = nil,
        validatedBy gate: (@Sendable () -> Bool)? = nil
    ) throws -> ClipboardFence {
        try writeTranscript(text, markingTransient: true, tracksResidue: true,
                            expectedChangeCount: expectedChangeCount, gate: gate)
    }

    public func writeRecoveryCopy(
        _ text: String,
        expectedChangeCount: Int? = nil,
        validatedBy gate: (@Sendable () -> Bool)? = nil
    ) throws -> ClipboardFence {
        try writeTranscript(text, markingTransient: true, tracksResidue: false,
                            expectedChangeCount: expectedChangeCount, gate: gate)
    }

    public func fenceIntact(_ fence: ClipboardFence) -> Bool {
        backend.changeCount == fence.changeCount
    }

    public func restore(_ snapshot: PasteboardSnapshot,
                        guardedBy fence: ClipboardFence,
                        validatedBy gate: (@Sendable () -> Bool)? = nil) -> RestoreOutcome {
        defer { releaseResidue(matching: fence) }
        if let gate, !gate() { return .ownershipPreserved }
        guard backend.changeCount == fence.changeCount else { return .ownershipPreserved }
        guard case .success(let restoredCount) = backend.replaceItems(snapshot.items) else { return .restoreFailed }
        ownedTranscriptCount = snapshot.ownsTranscript ? restoredCount : nil
        return .restored
    }

    public func leaveTemporaryAsClipboard(_ fence: ClipboardFence) {
        releaseResidue(matching: fence)
    }

    public func hasTransientResidue() -> Bool {
        purgeResidue()
        return pendingTemporaryCount != nil
    }

    public func awaitTransientResidueSettled(
        timeout: Duration = .milliseconds(700)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            guard !Task.isCancelled else { return false }
            purgeResidue()
            guard pendingTemporaryCount != nil else { return true }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    public func postPasteIfFenced(_ fence: ClipboardFence,
                                  to pid: pid_t,
                                  using inserter: TextInserter,
                                  validatedBy gate: (@Sendable () -> Bool)? = nil,
                                  onPosted: (@Sendable () -> Void)? = nil
    ) -> PasteGateOutcome {
        guard backend.changeCount == fence.changeCount else { return .clipboardOwnershipLost }
        if let gate, !gate() { return .preconditionRejected }
        guard backend.changeCount == fence.changeCount else { return .clipboardOwnershipLost }
        switch inserter.pasteOnce(to: pid) {
        case .posted:
            onPosted?()
            return .posted
        case .alreadyAttempted: return .alreadyAttempted
        case .postFailed: return .postFailed
        }
    }

    public func currentChangeCount() -> Int {
        backend.changeCount
    }

    private func writeTranscript(_ text: String, markingTransient: Bool,
                                 tracksResidue: Bool,
                                 expectedChangeCount: Int?,
                                 gate: (@Sendable () -> Bool)?) throws -> ClipboardFence {
        let payload = Data(text.utf8)
        var item: [String: Data] = [ClipboardCoordinator.plainTextTypeIdentifier: payload]
        if markingTransient {
            for marker in transientTypeIdentifiers { item[marker] = Data() }
        }
        let previousCount = backend.changeCount
        if let expectedChangeCount, previousCount != expectedChangeCount {
            throw ClipboardError.boundaryMismatch
        }
        if let gate, !gate() { throw ClipboardError.preconditionRejected }
        guard backend.changeCount == previousCount else { throw ClipboardError.boundaryMismatch }
        if let gate, !gate() { throw ClipboardError.preconditionRejected }
        guard case .success(let newCount) = backend.replaceItems([item]),
              newCount != previousCount
        else { throw ClipboardError.writeFailed }
        if tracksResidue { pendingTemporaryCount = newCount }
        let written = backend.materializeData(itemAt: 0, typeIdentifier: ClipboardCoordinator.plainTextTypeIdentifier)
        guard written == payload else { throw ClipboardError.writeFailed }
        ownedTranscriptCount = newCount
        return ClipboardFence(changeCount: newCount)
    }

    private func purgeResidue() {
        if ownedTranscriptCount != backend.changeCount { ownedTranscriptCount = nil }
        if let pending = pendingTemporaryCount, pending != backend.changeCount {
            pendingTemporaryCount = nil
        }
    }

    private func releaseResidue(matching fence: ClipboardFence) {
        if pendingTemporaryCount == fence.changeCount {
            pendingTemporaryCount = nil
        }
    }

    private static let plainTextTypeIdentifier = "public.utf8-plain-text"
}
