import Foundation
import GoatVoicePlatform

private struct DictReply: @unchecked Sendable {
    let block: (NSDictionary) -> Void
    func call(_ payload: NSDictionary) { block(payload) }
}

private struct ErrorReply: @unchecked Sendable {
    let block: (NSError?) -> Void
    func success() { block(nil) }
    func fail(_ error: Error) { block(error.goatVoiceServiceNSError) }
}

private struct VoidReply: @unchecked Sendable {
    let block: () -> Void
    func call() { block() }
}

private struct TextReply: @unchecked Sendable {
    let block: (NSString?, NSError?) -> Void
    func success(_ text: String) { block(text as NSString, nil) }
    func fail(_ error: Error) { block(nil, error.goatVoiceServiceNSError) }
}

final class GoatVoiceSTTService: NSObject, GoatVoiceServiceXPCProtocol, @unchecked Sendable {
    private let core: ServiceCore
    private let connectionID: UUID
    private let chainLock = NSLock()
    private var chainTail: Task<Void, Never>?

    init(core: ServiceCore, connectionID: UUID) {
        self.core = core
        self.connectionID = connectionID
    }

    private func enqueueOrdered(_ body: @escaping @Sendable () async -> Void) {
        chainLock.lock()
        let previous = chainTail
        let task = Task {
            await previous?.value
            await body()
        }
        chainTail = task
        chainLock.unlock()
    }

    func handshake(reply: @escaping (NSDictionary) -> Void) {
        let reply = DictReply(block: reply)
        Task {
            reply.call(await core.handshakePayload())
        }
    }

    func loadModel(_ modelID: NSString, modelDirectory: NSURL,
                   reply: @escaping (NSError?) -> Void) {
        let reply = ErrorReply(block: reply)
        Task {
            do {
                try await core.loadModel(modelID as String, directory: modelDirectory as URL)
                reply.success()
            } catch {
                reply.fail(error)
            }
        }
    }

    func unloadModel(reply: @escaping () -> Void) {
        let reply = VoidReply(block: reply)
        Task {
            await core.unloadModel()
            reply.call()
        }
    }

    func beginSession(_ sessionID: NSString, reply: @escaping (NSError?) -> Void) {
        let reply = ErrorReply(block: reply)
        let id = sessionID as String
        enqueueOrdered { [core, connectionID] in
            do {
                try await core.beginSession(id, connectionID: connectionID)
                reply.success()
            } catch {
                reply.fail(error)
            }
        }
    }

    func pushAudio(_ chunk: NSData, sessionID: NSString, offset: UInt64,
                   reply: @escaping (NSError?) -> Void) {
        let reply = ErrorReply(block: reply)
        let data = chunk as Data
        let id = sessionID as String
        enqueueOrdered { [core, connectionID] in
            do {
                try await core.pushAudio(id, connectionID: connectionID,
                                       chunk: data, offset: offset)
                reply.success()
            } catch {
                reply.fail(error)
            }
        }
    }

    func previewSession(_ sessionID: NSString,
                        reply: @escaping (NSString?, NSError?) -> Void) {
        let reply = TextReply(block: reply)
        let id = sessionID as String
        Task { [core, connectionID] in
            do {
                reply.success(try await core.previewSession(id, connectionID: connectionID))
            } catch {
                reply.fail(error)
            }
        }
    }

    func finishSession(_ sessionID: NSString, canonicalAudio: NSData?,
                       deadline: NSDate,
                       reply: @escaping (NSString?, NSError?) -> Void) {
        let reply = TextReply(block: reply)
        let id = sessionID as String
        let canonical = canonicalAudio as Data?
        let wallDeadline = deadline as Date
        enqueueOrdered { [core, connectionID] in
            do {
                let context = try await core.prepareFinish(
                    id,
                    connectionID: connectionID,
                    canonicalAudio: canonical,
                    deadline: wallDeadline
                )
                Task {
                    do {
                        reply.success(try await core.completeFinish(context))
                    } catch {
                        reply.fail(error)
                    }
                }
            } catch {
                reply.fail(error)
            }
        }
    }

    func cancelSession(_ sessionID: NSString) {
        let id = sessionID as String
        enqueueOrdered { [core, connectionID] in
            await core.cancelSession(id, connectionID: connectionID)
        }
    }
}

enum ServiceInterface {
    static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: GoatVoiceServiceXPCProtocol.self)
        let classes = NSSet(objects:
            NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSNull.self
        ) as! Set<AnyHashable>
        interface.setClasses(
            classes,
            for: #selector(GoatVoiceServiceXPCProtocol.handshake(reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        return interface
    }
}

private struct ResumableConnection: @unchecked Sendable {
    let connection: NSXPCConnection
}

final class ServiceListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let core: ServiceCore

    init(core: ServiceCore) {
        self.core = core
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let connectionID = UUID()
        connection.exportedInterface = ServiceInterface.make()
        connection.exportedObject = GoatVoiceSTTService(core: core, connectionID: connectionID)
        connection.invalidationHandler = { [core] in
            ServiceLog.sessions.info("connection invalidated")
            Task { await core.cancelConnection(connectionID) }
        }
        let resumable = ResumableConnection(connection: connection)
        ServiceLog.sessions.info("connection accepted")
        Task {
            await core.retireForeignSessions(keeping: connectionID)
            resumable.connection.resume()
        }
        return true
    }
}
