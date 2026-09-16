import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct AXElementToken: @unchecked Sendable, Equatable {
    public let element: AnyObject
    public let pid: pid_t

    public init(element: AnyObject, pid: pid_t) {
        self.element = element
        self.pid = pid
    }

    public static func == (lhs: AXElementToken, rhs: AXElementToken) -> Bool {
        guard lhs.pid == rhs.pid else { return false }
        if lhs.element === rhs.element { return true }
        return CFEqual(lhs.element as CFTypeRef, rhs.element as CFTypeRef)
    }
}

public struct AXObservation: Sendable {
    private let invalidateBody: @Sendable () -> Void

    public init(_ invalidate: @escaping @Sendable () -> Void) {
        invalidateBody = invalidate
    }

    public func invalidate() {
        invalidateBody()
    }
}

public enum AXMutationEvent: Sendable {
    case valueChanged
    case selectionChanged
}

public struct AXMutationFingerprint: Sendable, Equatable {
    public var selectionLocation: Int
    public var selectionLength: Int
    public var characterCount: Int

    public init(selectionLocation: Int, selectionLength: Int, characterCount: Int) {
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
        self.characterCount = characterCount
    }
}

public protocol AccessibilityBackend: Sendable {
    func isProcessTrusted() -> Bool
    func focusedEditableElement() throws -> AXElementToken
    func element(_ token: AXElementToken, isSameAs other: AXElementToken) -> Bool
    func windowID(of token: AXElementToken) -> CGWindowID?
    func windowBounds(of token: AXElementToken) -> CGRect?
    func windowToken(of token: AXElementToken) -> AXElementToken?
    func bundleIdentifier(of token: AXElementToken) -> String?
    func observeMutations(of token: AXElementToken,
                          onMutation: @escaping @Sendable (AXMutationEvent) -> Void) throws -> AXObservation
    func mutationFingerprint(of token: AXElementToken) -> AXMutationFingerprint?
    func adjacentContext(of token: AXElementToken,
                         radius: Int) -> (before: String, after: String)?
}

public extension AccessibilityBackend {
    func windowToken(of token: AXElementToken) -> AXElementToken? { nil }
    func mutationFingerprint(of token: AXElementToken) -> AXMutationFingerprint? { nil }
}

public enum TargetResolutionError: Error {
    case accessibilityUnavailable
    case noFocusedElement
    case focusedElementNotEditable
    case windowIdentityUnavailable
}

public final class ApplicationServicesBackend: AccessibilityBackend, @unchecked Sendable {
    private static let editableRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXComboBox", "AXSearchField",
    ]

    private let observerRunner = AXObserverRunner()

    public init() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
    }

    public func isProcessTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    public func focusedEditableElement() throws -> AXElementToken {
        guard isProcessTrusted() else { throw TargetResolutionError.accessibilityUnavailable }
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw TargetResolutionError.noFocusedElement
        }
        let element = value as! AXUIElement
        var pid = pid_t(0)
        guard AXUIElementGetPid(element, &pid) == .success else {
            throw TargetResolutionError.noFocusedElement
        }
        var visited = 0
        guard let editable = isEditable(element)
                ? element
                : editableDescendant(of: element, depth: 0, visited: &visited)
        else {
            throw TargetResolutionError.focusedElementNotEditable
        }
        return AXElementToken(element: editable, pid: pid)
    }

    public func element(_ token: AXElementToken, isSameAs other: AXElementToken) -> Bool {
        token == other
    }

    public func windowID(of token: AXElementToken) -> CGWindowID? {
        guard let element = try? axElement(from: token),
              let windowElement = windowElement(of: element),
              let bounds = bounds(of: windowElement)
        else { return nil }
        return matchWindowID(pid: token.pid, bounds: bounds)
    }

    public func windowToken(of token: AXElementToken) -> AXElementToken? {
        guard let element = try? axElement(from: token),
              let windowElement = windowElement(of: element)
        else { return nil }
        return AXElementToken(element: windowElement, pid: token.pid)
    }

    public func mutationFingerprint(of token: AXElementToken) -> AXMutationFingerprint? {
        guard let element = try? axElement(from: token) else { return nil }
        var selectionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &selectionValue) == .success,
            let selectionValue, CFGetTypeID(selectionValue) == AXValueGetTypeID()
        else { return nil }
        var selection = CFRange(location: 0, length: 0)
        guard AXValueGetValue(selectionValue as! AXValue, .cfRange, &selection) else { return nil }
        var countValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &countValue) == .success,
            let count = countValue as? Int
        else { return nil }
        return AXMutationFingerprint(
            selectionLocation: selection.location,
            selectionLength: selection.length,
            characterCount: count)
    }

    public func windowBounds(of token: AXElementToken) -> CGRect? {
        guard let element = try? axElement(from: token),
              let windowElement = windowElement(of: element)
        else { return nil }
        return bounds(of: windowElement)
    }

    public func bundleIdentifier(of token: AXElementToken) -> String? {
        NSRunningApplication(processIdentifier: token.pid)?.bundleIdentifier
    }

    public func observeMutations(of token: AXElementToken,
                                 onMutation: @escaping @Sendable (AXMutationEvent) -> Void) throws -> AXObservation {
        let element = try axElement(from: token)
        return try observerRunner.observe(pid: token.pid, element: element, onMutation: onMutation)
    }

    public func adjacentContext(of token: AXElementToken,
                                radius: Int) -> (before: String, after: String)? {
        guard let element = try? axElement(from: token) else { return nil }
        var selectionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &selectionValue) == .success,
            let selectionValue, CFGetTypeID(selectionValue) == AXValueGetTypeID()
        else { return nil }
        var selection = CFRange(location: 0, length: 0)
        guard AXValueGetValue(selectionValue as! AXValue, .cfRange, &selection) else { return nil }
        var countValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &countValue) == .success,
            let count = countValue as? Int
        else { return nil }
        let caret = selection.location + selection.length
        let beforeStart = max(0, selection.location - radius)
        let before = string(in: element, range: CFRange(
            location: beforeStart, length: selection.location - beforeStart))
        let afterEnd = min(count, caret + radius)
        let after = string(in: element, range: CFRange(
            location: caret, length: afterEnd - caret))
        return (before ?? "", after ?? "")
    }

    private func axElement(from token: AXElementToken) throws -> AXUIElement {
        let object = token.element as CFTypeRef
        guard CFGetTypeID(object) == AXUIElementGetTypeID() else {
            throw TargetResolutionError.noFocusedElement
        }
        return token.element as! AXUIElement
    }

    private func string(in element: AXUIElement, range: CFRange) -> String? {
        guard range.length > 0 else { return nil }
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var stringValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue, &stringValue) == .success,
            let string = stringValue as? String
        else { return nil }
        return string
    }

    private func editableDescendant(of element: AXUIElement,
                                    depth: Int,
                                    visited: inout Int) -> AXUIElement? {
        guard depth < 8 else { return nil }
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
            let children = childrenValue as? [AXUIElement], !children.isEmpty
        else { return nil }
        let ordered = children.sorted { isFocused($0) && !isFocused($1) }
        for child in ordered {
            visited += 1
            guard visited <= 64 else { return nil }
            if isFocused(child), isEditable(child) { return child }
            if let found = editableDescendant(of: child, depth: depth + 1, visited: &visited) {
                return found
            }
        }
        return nil
    }

    private func isFocused(_ element: AXUIElement) -> Bool {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXFocusedAttribute as CFString, &focusedValue) == .success,
            let focused = focusedValue as? Bool
        else { return false }
        return focused
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleValue) == .success
            ? roleValue as? String
            : nil
        var subroleValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        if role == "AXSecureTextField" || subroleValue as? String == "AXSecureTextField" { return false }
        if let role, ApplicationServicesBackend.editableRoles.contains(role) { return true }
        guard exposesTextEditing(element) else { return false }
        var editableValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableValue) == .success,
           let editable = editableValue as? Bool, editable {
            return true
        }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        return false
    }

    private func exposesTextEditing(_ element: AXUIElement) -> Bool {
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
            let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            return true
        }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private func windowElement(of element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<10 {
            var windowValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXWindowAttribute as CFString, &windowValue) == .success,
               let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
                return (windowValue as! AXUIElement)
            }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID()
            else { return nil }
            let parent = parentValue as! AXUIElement
            var roleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(parent, kAXRoleAttribute as CFString, &roleValue) == .success,
               let role = roleValue as? String, role == "AXWindow" {
                return parent
            }
            current = parent
        }
        return nil
    }

    private func bounds(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func matchWindowID(pid: pid_t, bounds: CGRect) -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        var bestID: CGWindowID?
        var bestDelta = CGFloat.infinity
        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowNumber = info[kCGWindowNumber as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let windowBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            let delta = abs(windowBounds.minX - bounds.minX)
                + abs(windowBounds.minY - bounds.minY)
                + abs(windowBounds.width - bounds.width)
                + abs(windowBounds.height - bounds.height)
            if delta < bestDelta {
                bestDelta = delta
                bestID = CGWindowID(windowNumber)
            }
        }
        return bestDelta <= 4 ? bestID : nil
    }
}

final class AXObserverRunner: @unchecked Sendable {
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var keepAlivePort: Port?
    private var activeCallbacks: [ObjectIdentifier: CallbackBox] = [:]
    private let readySemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()

    func observe(pid: pid_t, element: AXUIElement,
                 onMutation: @escaping @Sendable (AXMutationEvent) -> Void) throws -> AXObservation {
        try ensureRunning()
        let box = CallbackBox(onMutation)
        let boxID = ObjectIdentifier(box)
        lock.lock()
        activeCallbacks[boxID] = box
        lock.unlock()
        let context = Unmanaged.passUnretained(box).toOpaque()
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let event: AXMutationEvent = notification as String == kAXSelectedTextChangedNotification
                ? .selectionChanged : .valueChanged
            Unmanaged<CallbackBox>.fromOpaque(refcon).takeUnretainedValue().fire(event)
        }
        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else {
            dropCallback(boxID)
            throw TargetResolutionError.noFocusedElement
        }
        let notifications = [kAXValueChangedNotification, kAXSelectedTextChangedNotification]
        var added = 0
        for notification in notifications {
            let result = AXObserverAddNotification(observer, element, notification as CFString, context)
            guard result == .success else {
                for notification in notifications.prefix(added) {
                    AXObserverRemoveNotification(observer, element, notification as CFString)
                }
                dropCallback(boxID)
                throw TargetResolutionError.noFocusedElement
            }
            added += 1
        }
        schedule { [weak self] in
            guard let runLoop = self?.currentRunLoop() else { return }
            CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        return AXObservation { [weak self] in
            self?.schedule {
                for notification in notifications {
                    AXObserverRemoveNotification(observer, element, notification as CFString)
                }
                if let runLoop = self?.currentRunLoop() {
                    CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
                }
                self?.dropCallback(boxID)
            }
        }
    }

    private func ensureRunning() throws {
        lock.lock()
        let justStarted = thread == nil
        if justStarted {
            let runner = Thread { [weak self] in self?.loop() }
            thread = runner
            runner.start()
        }
        lock.unlock()
        if justStarted, readySemaphore.wait(timeout: .now() + 5) == .timedOut {
            throw TargetResolutionError.noFocusedElement
        }
    }

    private func loop() {
        runLoop = CFRunLoopGetCurrent()
        let port = NSMachPort()
        keepAlivePort = port
        RunLoop.current.add(port, forMode: .default)
        readySemaphore.signal()
        CFRunLoopRun()
    }

    private func schedule(_ body: @escaping () -> Void) {
        guard let target = currentRunLoop() else { return }
        CFRunLoopPerformBlock(target, CFRunLoopMode.defaultMode.rawValue, body)
        CFRunLoopWakeUp(target)
    }

    private func currentRunLoop() -> CFRunLoop? {
        lock.lock()
        defer { lock.unlock() }
        return runLoop
    }

    private func dropCallback(_ boxID: ObjectIdentifier) {
        lock.lock()
        activeCallbacks.removeValue(forKey: boxID)
        lock.unlock()
    }

    private final class CallbackBox {
        let fire: @Sendable (AXMutationEvent) -> Void
        init(_ fire: @escaping @Sendable (AXMutationEvent) -> Void) { self.fire = fire }
    }
}
