import Foundation
import Sparkle

@MainActor
final class SessionAwareUserDriver: NSObject, SPUUserDriver {
    private struct SendableCancellation: @unchecked Sendable {
        let invoke: () -> Void
    }

    private let standard: any SPUUserDriver
    private var updateCheckCancellation: (() -> Void)?
    private var downloadCancellation: (() -> Void)?

    var sessionIsActive = false {
        didSet {
            if sessionIsActive && !oldValue {
                cancelInFlightWork()
            }
        }
    }

    init(hostBundle: Bundle = .main, standard: (any SPUUserDriver)? = nil) {
        self.standard = standard ?? SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
    }

    private func cancelInFlightWork() {
        let check = updateCheckCancellation
        let download = downloadCancellation
        updateCheckCancellation = nil
        downloadCancellation = nil
        guard check != nil || download != nil else { return }
        let checkBox = check.map(SendableCancellation.init)
        let downloadBox = download.map(SendableCancellation.init)
        DispatchQueue.main.async {
            checkBox?.invoke()
            downloadBox?.invoke()
        }
    }

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        standard.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        if sessionIsActive {
            let box = SendableCancellation(invoke: cancellation)
            DispatchQueue.main.async { box.invoke() }
            return
        }
        updateCheckCancellation = cancellation
        standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        updateCheckCancellation = nil
        if sessionIsActive {
            reply(.dismiss)
            return
        }
        standard.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
            reply(self?.sessionIsActive == false ? choice : .dismiss)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        standard.showUpdateReleaseNotes(with: downloadData)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        standard.showUpdateReleaseNotesFailedToDownloadWithError(error)
    }

    func showUpdateNotFoundWithError(_ error: Error) async {
        updateCheckCancellation = nil
        await standard.showUpdateNotFoundWithError(error)
    }

    func showUpdaterError(_ error: Error) async {
        updateCheckCancellation = nil
        downloadCancellation = nil
        await standard.showUpdaterError(error)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        if sessionIsActive {
            let box = SendableCancellation(invoke: cancellation)
            DispatchQueue.main.async { box.invoke() }
            return
        }
        downloadCancellation = cancellation
        standard.showDownloadInitiated(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        standard.showDownloadDidReceiveData(ofLength: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        downloadCancellation = nil
        standard.showDownloadDidStartExtractingUpdate()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        standard.showExtractionReceivedProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        downloadCancellation = nil
        if sessionIsActive {
            reply(.dismiss)
            return
        }
        standard.showReady { [weak self] choice in
            reply(self?.sessionIsActive == false ? choice : .dismiss)
        }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        standard.showInstallingUpdate(
            withApplicationTerminated: applicationTerminated,
            retryTerminatingApplication: retryTerminatingApplication
        )
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {
        await standard.showUpdateInstalledAndRelaunched(relaunched)
    }

    func dismissUpdateInstallation() {
        updateCheckCancellation = nil
        downloadCancellation = nil
        standard.dismissUpdateInstallation()
    }

    func showUpdateInFocus() {
        standard.showUpdateInFocus?()
    }
}
