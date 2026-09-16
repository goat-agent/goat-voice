import AppKit
import CoreGraphics
import Foundation
import GoatVoiceCore
import GoatVoicePlatform

@MainActor
final class SessionDriver {
    struct Dependencies {
        let settings: any SessionSettingsPort
        let sink: any SessionPresenting
        let capture: any AudioCapturing
        let devices: any AudioDeviceResolving
        let monitor: InputTriggerMonitor
        let latch: InterruptibilityLatch
        let clipboard: ClipboardCoordinator
        let pasteboard: any PasteboardBackend
        let accessibility: any AccessibilityBackend
        let targetResolver: TargetResolver
        let intentGuard: UserIntentGuard
        let permissions: PermissionCenter
        let client: TranscriptionXPCClient
        let network: NetworkActivityCoordinator
        let updater: any UpdateChecking
        let recovery: RecoveryController
        let clock: MonotonicClock
        let makeInserter: @Sendable () -> TextInserter
        let isAppActive: () -> Bool
    }

    var onSessionActivityChanged: ((Bool) -> Void)?

    private let deps: Dependencies
    private let pipeline: CapturePipeline
    private let preview: LiveTranscriptionPreview
    private nonisolated let cancelFlag = CancellationFlag()
    private nonisolated let latch: InterruptibilityLatch
    private let levelRelay = ValueCoalescer<Double>()
    private var machine = SessionMachine()

    private var started = false
    private var monitorRunning = false
    private var monitorStartAttempts = 0
    private var nextMonitorStart = ContinuousClock.now
    private var observerID: UUID?
    private var appStateTokens: [NotificationToken] = []
    private var suspendedSpec: TriggerSpec?

    private var sessionEpoch: UInt64 = 0
    private var serviceSessionBegan = false
    private var releaseContext: ReleaseContext?
    private var delivery: DeliveryTransaction?
    private var deliveryPermit: CancellationFlag?
    private var inferenceTask: Task<Void, Never>?
    private var serviceBeginTask: Task<Void, Never>?
    private var drainTask: Task<Bool, Never>?
    private var tickTask: Task<Void, Never>?
    private var rearmTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var deferredEvent: SessionMachine.Event?
    private var preparedRecovery: [SessionID: PreparedRecovery] = [:]
    private var forcedCaptureFinish = false

    private var sessionDisplayID: CGDirectDisplayID?
    private var activeNotice: Notice?
    private var sessionWasActive = false
    private var didDeliver = false
    private var lastPresentation: SessionPresentation?
    private var presentationEpoch: UInt64 = 0

    init(deps: Dependencies) {
        self.deps = deps
        latch = deps.latch
        pipeline = CapturePipeline(client: deps.client)
        deps.recovery.onDiagnostic = { DeliveryLog.recovery($0) }
        preview = LiveTranscriptionPreview(
            request: { try await deps.client.preview(sessionID: $0) },
            publish: { deps.sink.apply(previewText: $0) })
    }

    var sessionIsActive: Bool {
        machine.state != .idle
    }

    func start() {
        guard !started else { return }
        started = true
        monitor.onEffect = { [weak self] effect in
            MainHop.async { self?.handleTriggerEffect(effect) }
        }
        let cancelFlag = self.cancelFlag
        let intentGuard = deps.intentGuard
        let recovery = deps.recovery
        let observedMonitor = deps.monitor
        observerID = monitor.addSynchronousObserver { [weak self] observation in
            if observation.effects.contains(.cancelledByEscape)
                || observation.effects.contains(.cancelledByExtraKey) {
                cancelFlag.note()
                recovery.invalidateSynchronously()
            }
            if !observation.consumed {
                intentGuard.observe(observation.event)
            }
            if observedMonitor.triggerIsFullyReleased() {
                MainHop.async { self?.noteFullyReleased() }
            }
        }
        capture.onChunk = { [pipeline] chunk in
            pipeline.append(chunk)
        }
        capture.onLevel = { [weak self, levelRelay] level in
            guard levelRelay.push(level.rms) else { return }
            MainHop.async {
                guard let self, let rms = levelRelay.take(),
                      case .recording = self.machine.state else { return }
                self.deps.sink.apply(audioLevel: rms)
            }
        }
        capture.onEvent = { [weak self] event in
            MainHop.async { self?.handleCaptureEvent(event) }
        }
        pipeline.onFull = { [weak self] in
            MainHop.async { self?.advanceMachine() }
        }
        observeAppActivation()
        applySpec()
        ensureMonitorRunning()
    }

    func stop() {
        guard started else { return }
        started = false
        cancelFlag.note()
        latch.setInterruptible(false)
        if let observerID {
            monitor.removeSynchronousObserver(observerID)
            self.observerID = nil
        }
        monitor.onEffect = nil
        monitor.stop()
        monitorRunning = false
        for token in appStateTokens { token.cancel() }
        appStateTokens = []
        tickTask?.cancel()
        tickTask = nil
        rearmTask?.cancel()
        rearmTask = nil
        hideTask?.cancel()
        hideTask = nil
        serviceBeginTask?.cancel()
        serviceBeginTask = nil
        inferenceTask?.cancel()
        inferenceTask = nil
        preview.stop(clear: true)
        feed(.invalidate(.quit))
        deps.capture.stop()
        sessionEpoch &+= 1
        pipeline.discard()
        deps.intentGuard.end()
        deps.recovery.shutdown()
        let client = deps.client
        Task { await client.invalidate() }
    }

    func triggerSpecChanged() {
        applySpec()
    }

    func presentExternalNotice(_ notice: Notice, displayID: CGDirectDisplayID?) {
        presentNotice(notice, displayID: displayID)
    }

    func noticeResolved(_ notice: Notice) {
        if notice == activeNotice {
            activeNotice = nil
            refreshInterruptibility()
        }
        refreshPresentation(concluded: false)
    }

    nonisolated func noteSystemInterruption(_ event: SystemLifecycleEvent) {
        switch event {
        case .willSleep, .screenLocked, .willTerminate:
            cancelFlag.note()
            latch.setInterruptible(false)
        case .screenUnlocked, .didWake:
            break
        }
    }

    func handleLifecycle(_ event: SystemLifecycleEvent) {
        switch event {
        case .willSleep:
            invalidate(.sleep)
        case .screenLocked:
            invalidate(.lock)
        case .willTerminate:
            invalidate(.quit)
        case .screenUnlocked:
            deps.settings.refreshPermissionsAndDevices()
            ensureMonitorRunning()
        case .didWake:
            deps.settings.refreshPermissionsAndDevices()
            ensureMonitorRunning()
            rewarmService()
        }
    }

    func permissionsDidChange() {
        guard started else { return }
        deps.settings.refreshPermissions()
        let accessibility = deps.permissions.accessibility()
        let microphone = deps.permissions.microphone()
        if accessibility != .trusted {
            monitor.stop()
            monitorRunning = false
        }
        if sessionIsActive, accessibility != .trusted || microphone != .granted {
            invalidate(.captureFailure)
            presentNotice(Notice(
                message: accessibility != .trusted ? .accessibilityRequired : .microphoneAccessRequired,
                action: .openSettings))
        }
        if accessibility == .trusted { ensureMonitorRunning() }
    }

    private var monitor: InputTriggerMonitor { deps.monitor }
    private var capture: any AudioCapturing { deps.capture }

    func reconcileInputMonitor() {
        ensureMonitorRunning(retrying: true)
    }

    private func ensureMonitorRunning(retrying: Bool = false) {
        guard started, !monitorRunning, deps.permissions.accessibility() == .trusted else { return }
        if retrying {
            guard monitorStartAttempts < 3, ContinuousClock.now >= nextMonitorStart else { return }
        } else {
            monitorStartAttempts = 0
        }
        monitorStartAttempts += 1
        nextMonitorStart = .now + .seconds(1)
        do {
            try monitor.start()
            monitorRunning = true
        } catch {
            monitor.stop()
            AppLog.session.error(
                "Input monitor failed to start: \(error.localizedDescription, privacy: .public)")
            if monitorStartAttempts >= 3 {
                presentNotice(Notice(message: .shortcutUnavailable, action: .openSettings))
            }
        }
    }

    private func noteFullyReleased() {
        guard machine.triggerGate == .disarmed,
              deps.monitor.triggerIsFullyReleased() else { return }
        feed(.triggerFullyReleased)
    }

    private func advanceMachine() {
        applyBatch(machine.advance(to: deps.clock.now()))
    }

    private func handleTriggerEffect(_ effect: TriggerEffect) {
        switch effect {
        case .began:
            handleBegan()
        case .ended:
            feed(.triggerReleased)
        case .cancelledByExtraKey:
            feed(.extraKeyPressed)
        case .cancelledByEscape:
            if machine.state == .idle, activeNotice != nil {
                dismissActiveNotice()
            } else {
                invalidate(.escape)
            }
        case .tapDisabled:
            let wasActive = sessionIsActive
            invalidate(.captureFailure)
            if wasActive {
                presentNotice(Notice(message: .shortcutUnavailable, action: nil))
            }
        }
    }

    private func handleBegan() {
        AppLog.session.debug("Configured trigger pressed")
        guard machine.state == .idle else {
            feed(.triggerComplete(SessionID()))
            return
        }
        cancelFlag.reset()
        guard !deps.isAppActive() else {
            monitor.disarmUntilTriggerFullyReleased()
            return
        }
        guard let notice = preflightBlocker() else {
            feed(.triggerComplete(SessionID()))
            return
        }
        monitor.disarmUntilTriggerFullyReleased()
        presentNotice(notice)
    }

    private func preflightBlocker() -> Notice? {
        guard deps.permissions.microphone() == .granted else {
            return Notice(message: .microphoneAccessRequired, action: .openSettings)
        }
        guard deps.settings.selectedModelLocation != nil else {
            return modelBlockNotice()
        }
        return nil
    }

    private func modelBlockNotice() -> Notice {
        switch effectiveModel()?.state {
        case .downloading, .verifying:
            return Notice(message: .modelDownloading, action: nil)
        case .loadFailed:
            return Notice(message: .modelFailedToLoad, action: .openSettings)
        default:
            return Notice(message: .modelNotReady, action: .openSettings)
        }
    }

    private func effectiveModel() -> ModelItem? {
        let models = deps.settings.models
        if let selected = deps.settings.selectedModelID,
           let item = models.first(where: { $0.id == selected }) {
            return item
        }
        return models.first(where: \.isRecommended) ?? models.first
    }

    private func handleCaptureEvent(_ event: AudioCaptureEvent) {
        switch event {
        case .inputDeviceLost:
            feed(.microphoneDisconnected)
        case .engineInterrupted:
            feed(.invalidate(.captureFailure))
        case .captureLimitReached:
            forcedCaptureFinish = true
            feed(.microphoneDisconnected)
        }
    }

    private func invalidate(_ reason: InvalidationReason) {
        cancelFlag.note()
        feed(.invalidate(reason))
        deps.recovery.discardPending()
    }

    private func rewarmService() {
        Task { [weak self] in
            guard let self,
                  let location = self.deps.settings.selectedModelLocation else { return }
            _ = try? await self.deps.client.handshake()
            _ = try? await self.deps.client.loadModel(id: location.id, directory: location.directory)
        }
    }

    private func feed(_ event: SessionMachine.Event) {
        applyBatch(machine.handle(event, at: deps.clock.now()))
    }

    private func applyBatch(_ effects: [SessionMachine.Effect]) {
        var pending = effects
        while !pending.isEmpty {
            let effect = pending.removeFirst()
            apply(effect)
            if let deferred = deferredEvent {
                deferredEvent = nil
                pending.append(contentsOf: machine.handle(deferred, at: deps.clock.now()))
            }
        }
        afterBatch()
    }

    private func apply(_ effect: SessionMachine.Effect) {
        switch effect {
        case .startCapture(let id):
            startCapture(id)
        case .stopCapture(let id):
            stopCapture(id)
        case .discardAudio(let id):
            discardAudio(id)
        case .runInference(let token):
            runInference(token)
        case .cancelInference(let token):
            cancelInference(token)
        case .deliverTranscript(let token, let transcript):
            deliverTranscript(token, transcript: transcript)
        case .recoverTranscript(let token, let transcript):
            recoverTranscript(token, transcript: transcript)
        case .abortDelivery:
            delivery?.abort()
        case .presentNotice(let notice):
            presentNotice(mapNotice(notice))
        case .blockNetwork:
            sessionDidBecomeActive()
        case .unblockNetwork:
            sessionDidBecomeIdle()
        case .disarmTrigger:
            monitor.disarmUntilTriggerFullyReleased()
        }
    }

    private func startCapture(_ id: SessionID) {
        deps.network.beginDictationSession()
        sessionEpoch &+= 1
        releaseContext = nil
        delivery = nil
        didDeliver = false
        serviceSessionBegan = false
        forcedCaptureFinish = false
        preparedRecovery.removeAll()
        pipeline.begin(session: id)
        preview.stop(clear: true)
        sessionDisplayID = nil
        activeNotice = nil
        deps.recovery.discardPending()
        do {
            let device = try deps.devices.resolve(deps.settings.microphoneSelection)
            try deps.capture.start(device: device)
            AppLog.session.info("Audio capture started")
            sessionDisplayID = (try? deps.targetResolver.captureTarget())?.displayID
        } catch {
            if let failure = error as? AudioCaptureStartupFailure {
                AppLog.session.error(
                    "Audio capture startup failed stage=\(failure.stage.rawValue, privacy: .public) code=\(failure.code)")
            } else {
                let failure = error as NSError
                AppLog.session.error(
                    "Audio capture startup failed domain=\(failure.domain, privacy: .public) code=\(failure.code)")
            }
            deferredEvent = .invalidate(.captureFailure)
            return
        }
        let sid = id.rawValue.uuidString
        let epoch = sessionEpoch
        serviceBeginTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.deps.client.beginSession(id: sid)
                guard self.sessionEpoch == epoch, !Task.isCancelled else {
                    await self.deps.client.cancel(sessionID: sid)
                    return
                }
                self.serviceSessionBegan = true
                self.pipeline.serviceSessionReady()
                if case .recording = self.machine.state {
                    self.preview.start(sessionID: sid)
                }
            } catch {
                guard self.sessionEpoch == epoch else { return }
                self.pipeline.serviceSessionFailed()
            }
        }
    }

    private func stopCapture(_ id: SessionID) {
        preview.stop(clear: false)
        deps.capture.stop()
        AppLog.session.debug("Audio capture stopped")
        let capture = deps.capture
        drainTask = Task.detached {
            await capture.stopAndDrain(until: .now + .milliseconds(750))
        }
        deps.sink.apply(audioLevel: 0)
        guard case .finishing(let finishing) = machine.state,
              finishing.sessionID == id else { return }
        let boundary = deps.pasteboard.changeCount
        var descriptor: TargetDescriptor?
        if finishing.finishReason == .normalRelease {
            descriptor = try? deps.targetResolver.captureTarget()
            if let descriptor {
                deps.intentGuard.begin(target: descriptor)
            }
        }
        releaseContext = ReleaseContext(
            finishReason: finishing.finishReason,
            boundaryChangeCount: boundary,
            target: descriptor)
    }

    private func runInference(_ token: AttemptToken) {
        guard case .finishing(let finishing) = machine.state,
              finishing.sessionID == token.sessionID,
              finishing.attempt == token.attempt else { return }
        let sid = token.sessionID.rawValue.uuidString
        let deadline = deps.clock.instant(for: finishing.deadline)
        let drain = drainTask
        let capture = deps.capture
        let epoch = sessionEpoch
        inferenceTask = Task { [weak self] in
            guard let self else { return }
            let drained: Bool
            if token.attempt == 0 {
                drained = await drain?.value ?? true
            } else {
                drained = await capture.stopAndDrain(
                    until: min(.now + .milliseconds(750), deadline))
            }
            self.pipeline.stopAccepting()
            guard self.sessionEpoch == epoch, !Task.isCancelled else { return }
            guard drained else {
                self.feed(.inferenceFailed(token, .deterministic))
                return
            }
            do {
                try await self.ensureServiceSession(
                    sid, token: token, epoch: epoch, deadline: deadline)
                let audio = self.pipeline.canonicalPCM16()
                let transcript = try await self.deps.client.finish(
                    sessionID: sid, canonicalAudio: audio, deadline: deadline)
                guard self.sessionEpoch == epoch, !Task.isCancelled else { return }
                self.feed(.inferenceSucceeded(token, transcript: transcript))
            } catch is CancellationError {
            } catch let error as XPCClientError {
                guard self.sessionEpoch == epoch else { return }
                self.feedInferenceFailure(token, error: error)
            } catch {
                guard self.sessionEpoch == epoch else { return }
                self.feed(.inferenceFailed(token, .transient))
            }
        }
    }

    private func ensureServiceSession(_ sid: String, token: AttemptToken,
                                      epoch: UInt64,
                                      deadline: ContinuousClock.Instant) async throws {
        if token.attempt == 0, serviceSessionBegan {
            try requireContinuation(token, epoch: epoch, deadline: deadline)
            return
        }
        await deps.client.cancel(sessionID: sid)
        do {
            try requireContinuation(token, epoch: epoch, deadline: deadline)
            try await deps.client.beginSession(id: sid)
        } catch {
            try requireContinuation(token, epoch: epoch, deadline: deadline)
            guard let location = deps.settings.selectedModelLocation else { throw error }
            try await deps.client.loadModel(
                id: location.id, directory: location.directory, deadline: deadline)
            try requireContinuation(token, epoch: epoch, deadline: deadline)
            try await deps.client.beginSession(id: sid)
        }
        try requireContinuation(token, epoch: epoch, deadline: deadline)
        serviceSessionBegan = true
    }

    private func requireContinuation(_ token: AttemptToken, epoch: UInt64,
                                     deadline: ContinuousClock.Instant) throws {
        guard sessionEpoch == epoch else { throw CancellationError() }
        try Task<Never, Never>.checkCancellation()
        guard case .finishing(let finishing) = machine.state,
              finishing.sessionID == token.sessionID,
              finishing.attempt == token.attempt else { throw CancellationError() }
        guard ContinuousClock.now < deadline else {
            throw XPCClientError.deadlineExceeded
        }
    }

    private func feedInferenceFailure(_ token: AttemptToken, error: XPCClientError) {
        switch error {
        case .cancelled, .staleResult:
            break
        case .interrupted, .connectionInvalidated, .transportError,
             .backpressureLimit, .sessionUnknown, .sessionExists,
             .sessionLimitExceeded:
            feed(.inferenceFailed(token, .transient))
        case .serviceError(_, let retryable, _):
            feed(.inferenceFailed(token, retryable ? .transient : .deterministic))
        case .deadlineExceeded, .chunkTooLarge, .audioLimitExceeded,
             .canonicalReplayRequired, .malformedReply, .unsupportedProtocolVersion,
             .invalidRequest, .sessionClosed:
            feed(.inferenceFailed(token, .deterministic))
        }
    }

    private func cancelInference(_ token: AttemptToken) {
        inferenceTask?.cancel()
        inferenceTask = nil
        let sid = token.sessionID.rawValue.uuidString
        Task { await deps.client.cancel(sessionID: sid) }
    }

    private func deliverTranscript(_ token: AttemptToken, transcript: String) {
        guard case .delivering(let context) = machine.state, context.token == token else { return }
        let clock = deps.clock
        let deadline = context.deadline
        let permit = CancellationFlag()
        deliveryPermit?.note()
        deliveryPermit = permit
        let transaction = DeliveryTransaction(
            token: token, transcript: transcript, release: releaseContext,
            deps: DeliveryTransaction.Dependencies(
                clipboard: deps.clipboard,
                accessibility: deps.accessibility,
                targetResolver: deps.targetResolver,
                intentGuard: deps.intentGuard,
                latch: deps.latch,
                cancelFlag: cancelFlag,
                makeInserter: deps.makeInserter,
                sessionIsValid: { !permit.isObserved && clock.now() < deadline },
                onDiagnostic: { DeliveryLog.delivery($0) }))
        delivery = transaction
        let epoch = sessionEpoch
        transaction.onPosted = { [weak self] in
            guard let self, self.sessionEpoch == epoch else { return }
            self.didDeliver = true
            self.feed(.pastePosted(token))
        }
        transaction.onAborted = { [weak self] prepared in
            guard let self, self.sessionEpoch == epoch else { return }
            self.preparedRecovery[token.sessionID] = prepared
            self.feed(.deliveryAborted(token))
        }
        Task { await transaction.run() }
    }

    private func recoverTranscript(_ token: AttemptToken, transcript: String) {
        let prepared = preparedRecovery.removeValue(forKey: token.sessionID)
        deps.recovery.present(
            prepared: prepared, transcript: transcript,
            release: releaseContext, displayID: sessionDisplayID)
    }

    private func discardAudio(_ id: SessionID) {
        preview.stop(clear: true)
        deliveryPermit?.note()
        deliveryPermit = nil
        sessionEpoch &+= 1
        serviceBeginTask = nil
        inferenceTask?.cancel()
        inferenceTask = nil
        pipeline.discard()
        deps.intentGuard.end()
        releaseContext = nil
        delivery = nil
        serviceSessionBegan = false
        drainTask = nil
        let sid = id.rawValue.uuidString
        Task { await deps.client.cancel(sessionID: sid) }
    }

    private func sessionDidBecomeActive() {
        deps.network.beginDictationSession()
        deps.updater.sessionIsActive = true
        deps.settings.setSessionActive(true)
        refreshInterruptibility()
        onSessionActivityChanged?(true)
        startTick()
    }

    private func sessionDidBecomeIdle() {
        deps.network.endDictationSession()
        deps.updater.sessionIsActive = false
        deps.settings.setSessionActive(false)
        refreshInterruptibility()
        onSessionActivityChanged?(false)
        tickTask?.cancel()
        tickTask = nil
    }

    private func refreshInterruptibility() {
        latch.setInterruptible(machine.state != .idle || activeNotice != nil)
    }

    private func startTick() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.applyBatch(self.machine.advance(to: self.deps.clock.now()))
            }
        }
    }

    private func afterBatch() {
        let active = machine.state != .idle
        let concluded = sessionWasActive && !active
        sessionWasActive = active
        if concluded { sessionEpoch &+= 1 }
        if machine.triggerGate == .disarmed { scheduleRearmPoll() }
        refreshPresentation(concluded: concluded)
    }

    private func scheduleRearmPoll() {
        guard rearmTask == nil else { return }
        rearmTask = Task { [weak self] in
            guard let self else { return }
            while self.machine.triggerGate == .disarmed, !Task.isCancelled {
                if self.monitor.triggerIsFullyReleased() {
                    self.feed(.triggerFullyReleased)
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            self.rearmTask = nil
        }
    }

    private func observeAppActivation() {
        let center = NotificationCenterObserver(.default)
        appStateTokens = [
            center.observe(NSApplication.didBecomeActiveNotification) { [weak self] in
                MainHop.async {
                    self?.setTriggerSuspended(true)
                    self?.ensureMonitorRunning()
                }
            },
            center.observe(NSApplication.didResignActiveNotification) { [weak self] in
                MainHop.async { self?.setTriggerSuspended(false) }
            },
        ]
        if deps.isAppActive() { setTriggerSuspended(true) }
    }

    private func setTriggerSuspended(_ suspended: Bool) {
        if suspended {
            guard suspendedSpec == nil else { return }
            suspendedSpec = deps.settings.configuredTrigger
            monitor.setSpec(.chord(keyCode: 0xFFFF, modifiers: [.control, .option, .command, .shift]))
        } else if let spec = suspendedSpec {
            suspendedSpec = nil
            monitor.setSpec(spec)
        }
    }

    private func applySpec() {
        guard suspendedSpec == nil else {
            suspendedSpec = deps.settings.configuredTrigger
            return
        }
        monitor.setSpec(deps.settings.configuredTrigger)
    }

    private func presentNotice(_ notice: Notice, displayID: CGDirectDisplayID? = nil) {
        activeNotice = notice
        refreshInterruptibility()
        emit(SessionPresentation(
            content: .notice(notice), displayID: sessionDisplayID ?? displayID))
    }

    private func dismissActiveNotice() {
        deps.recovery.discardPending()
        activeNotice = nil
        refreshInterruptibility()
        refreshPresentation(concluded: false)
    }

    private func refreshPresentation(concluded: Bool) {
        if let notice = activeNotice {
            emit(SessionPresentation(content: .notice(notice), displayID: sessionDisplayID))
            return
        }
        switch machine.state {
        case .idle:
            if case .notice = lastPresentation?.content {
                emit(.idle)
            }
            if concluded {
                emit(SessionPresentation(
                    content: .exiting(didDeliver ? .delivered : .cancelled),
                    displayID: sessionDisplayID))
                scheduleHidden()
            }
        case .recording:
            emit(SessionPresentation(content: .strip(.listening), displayID: sessionDisplayID))
        case .finishing, .delivering:
            emit(SessionPresentation(content: .strip(.processing), displayID: sessionDisplayID))
        }
    }

    private func scheduleHidden() {
        hideTask?.cancel()
        let epoch = presentationEpoch
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            guard self.presentationEpoch == epoch,
                  self.machine.state == .idle,
                  self.activeNotice == nil else { return }
            self.sessionDisplayID = nil
            self.emit(.idle)
        }
    }

    private func emit(_ presentation: SessionPresentation) {
        guard presentation != lastPresentation else { return }
        lastPresentation = presentation
        presentationEpoch &+= 1
        deps.sink.apply(presentation: presentation)
    }

    private func mapNotice(_ notice: SessionMachine.Notice) -> Notice {
        if notice == .microphoneDisconnected, forcedCaptureFinish {
            return Notice(message: .microphoneUnavailable, action: nil)
        }
        switch notice {
        case .recordingLimitWarning:
            return Notice(message: .oneMinuteRemaining, action: nil)
        case .microphoneDisconnected:
            return Notice(message: .microphoneDisconnected, action: nil)
        case .microphoneUnavailable:
            return Notice(message: .microphoneUnavailable, action: nil)
        case .transcriptionFailed:
            return Notice(message: .transcriptionFailed, action: nil)
        }
    }
}
