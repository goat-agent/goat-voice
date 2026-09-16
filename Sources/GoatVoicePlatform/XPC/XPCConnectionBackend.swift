import Foundation

public protocol XPCConnectionBackend: Sendable {
    func remoteObjectProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) throws -> any GoatVoiceServiceXPCProtocol
    func onInterruption(_ handler: @escaping @Sendable () -> Void)
    func onInvalidation(_ handler: @escaping @Sendable () -> Void)
    func resume()
    func invalidate()
}

private enum XPCConnectionEvent {
    case interrupted
    case invalidated
}

public final class NSXPCServiceBackend: XPCConnectionBackend, @unchecked Sendable {
    private let serviceName: String
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var interruptionHandler: (@Sendable () -> Void)?
    private var invalidationHandler: (@Sendable () -> Void)?

    public init(serviceName: String = GoatVoiceServiceWire.serviceName) {
        self.serviceName = serviceName
    }

    public func onInterruption(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { interruptionHandler = handler }
    }

    public func onInvalidation(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { invalidationHandler = handler }
    }

    public func resume() {
        _ = activeConnection()
    }

    public func invalidate() {
        let stale = lock.withLock { () -> NSXPCConnection? in
            let current = connection
            connection = nil
            return current
        }
        stale?.invalidate()
    }

    public func remoteObjectProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) throws -> any GoatVoiceServiceXPCProtocol {
        let conn = activeConnection()
        let object = conn.remoteObjectProxyWithErrorHandler { errorHandler($0) }
        guard let proxy = object as? any GoatVoiceServiceXPCProtocol else {
            throw XPCClientError.transportError("remote object proxy does not conform to GoatVoiceServiceXPCProtocol")
        }
        return proxy
    }

    private func activeConnection() -> NSXPCConnection {
        lock.lock()
        if let connection {
            lock.unlock()
            return connection
        }
        let conn = NSXPCConnection(serviceName: serviceName)
        conn.remoteObjectInterface = GoatVoiceServiceXPCInterface.make()
        conn.interruptionHandler = { [weak self, weak conn] in
            self?.connectionEvent(.interrupted, from: conn)
        }
        conn.invalidationHandler = { [weak self, weak conn] in
            self?.connectionEvent(.invalidated, from: conn)
        }
        connection = conn
        lock.unlock()
        conn.resume()
        return conn
    }

    private func connectionEvent(_ event: XPCConnectionEvent, from conn: NSXPCConnection?) {
        lock.lock()
        let isCurrent = conn != nil && connection === conn
        if isCurrent { connection = nil }
        let handler = isCurrent
            ? (event == .interrupted ? interruptionHandler : invalidationHandler)
            : nil
        lock.unlock()
        if event == .interrupted { conn?.invalidate() }
        handler?()
    }
}
