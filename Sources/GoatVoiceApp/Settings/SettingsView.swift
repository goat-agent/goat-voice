import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.setupRequired {
                HStack {
                    Spacer()
                    Text("Setup Required")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                        .padding(.trailing, 16)
                        .padding(.top, 10)
                }
                .accessibilityElement(children: .combine)
            }
            Form {
                if viewModel.setupRequired {
                    Section("Setup") {
                        permissionRow(
                            title: "Microphone",
                            state: viewModel.microphonePermission,
                            notDeterminedAction: ("Allow", viewModel.allowMicrophone),
                            deniedAction: ("Open Settings", viewModel.openMicrophoneSettings)
                        )
                        permissionRow(
                            title: "Accessibility",
                            state: viewModel.accessibilityPermission,
                            notDeterminedAction: ("Open Settings", viewModel.openAccessibilitySettings),
                            deniedAction: ("Open Settings", viewModel.openAccessibilitySettings)
                        )
                    }
                }
                Section("Voice Input") {
                    shortcutRow
                    modelRow
                    microphoneRow
                    launchAtLoginRow
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Text("Local transcription · Audio is not uploaded")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
        ) { _ in
            viewModel.cancelShortcutRecording()
        }
    }

    private func permissionRow(
        title: String,
        state: PermissionState,
        notDeterminedAction: (String, () -> Void),
        deniedAction: (String, () -> Void)
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Text(permissionText(for: state))
                    .foregroundStyle(.secondary)
                switch state {
                case .notDetermined:
                    Button(notDeterminedAction.0, action: notDeterminedAction.1)
                case .denied:
                    Button(deniedAction.0, action: deniedAction.1)
                case .allowed:
                    EmptyView()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func permissionText(for state: PermissionState) -> String {
        switch state {
        case .notDetermined: return "Not Allowed"
        case .allowed: return "Allowed"
        case .denied: return "Access Required"
        }
    }

    private var shortcutRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent("Shortcut") {
                Button(shortcutButtonTitle) {
                    if viewModel.isRecordingShortcut {
                        viewModel.cancelShortcutRecording()
                    } else {
                        viewModel.beginShortcutRecording()
                    }
                }
                .accessibilityLabel("Shortcut")
                .accessibilityValue(
                    viewModel.isRecordingShortcut
                        ? "Editing. Press a new shortcut, or Escape to cancel."
                        : viewModel.shortcut.displayName
                )
                .accessibilityHint("Activates shortcut editing")
            }
            Text(viewModel.shortcutCaption)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutButtonTitle: String {
        if viewModel.isRecordingShortcut {
            return viewModel.shortcutPreview.map { $0.isEmpty ? "Press a new shortcut" : $0 }
                ?? "Press a new shortcut"
        }
        return viewModel.shortcut.displayName
    }

    private var modelRow: some View {
        HStack(spacing: 10) {
            Text("Model")
            Spacer()
            Picker("Model", selection: modelSelection) {
                ForEach(viewModel.models) { model in
                    Text(modelTitle(for: model)).tag(Optional(model.id))
                }
            }
            .labelsHidden()
            .accessibilityLabel("Model")
            .accessibilityValue(viewModel.effectiveModel?.title ?? "Not selected")
            .fixedSize()
            .disabled(viewModel.sessionInProgress)
            modelStateView
        }
        .accessibilityElement(children: .contain)
    }

    private var modelSelection: Binding<String?> {
        Binding(
            get: { viewModel.effectiveModel?.id },
            set: { viewModel.selectModel($0) }
        )
    }

    private func modelTitle(for model: ModelItem) -> String {
        model.isRecommended ? "\(model.title) (Recommended)" : model.title
    }

    @ViewBuilder
    private var modelStateView: some View {
        switch viewModel.effectiveModel?.state {
        case .none:
            EmptyView()
        case .notInstalled:
            Button("Download", action: viewModel.downloadSelectedModel)
        case .downloading(let progress):
            DownloadStateLabel(progress: progress)
        case .verifying:
            Text("Verifying…").foregroundStyle(.secondary)
        case .loading:
            Text("Loading…").foregroundStyle(.secondary)
        case .ready:
            Text("Ready").foregroundStyle(.secondary)
        case .downloadFailed:
            HStack(spacing: 8) {
                Text("Download failed").foregroundStyle(.secondary)
                Button("Retry", action: viewModel.downloadSelectedModel)
            }
        case .checksumFailed:
            HStack(spacing: 8) {
                Text("Corrupted download").foregroundStyle(.secondary)
                Button("Retry", action: viewModel.downloadSelectedModel)
            }
        case .loadFailed:
            HStack(spacing: 8) {
                Text("Failed to load").foregroundStyle(.secondary)
                Button("Retry", action: viewModel.loadSelectedModel)
            }
        }
    }

    private var microphoneRow: some View {
        LabeledContent("Microphone") {
            Picker("Microphone", selection: microphoneSelection) {
                Text("System Default").tag(String?.none)
                ForEach(viewModel.microphones) { microphone in
                    Text(microphone.name).tag(Optional(microphone.id))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var microphoneSelection: Binding<String?> {
        Binding(
            get: { viewModel.selectedMicrophoneID },
            set: { viewModel.selectMicrophone($0) }
        )
    }

    private var launchAtLoginRow: some View {
        LabeledContent("Launch at Login") {
            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.setLaunchAtLogin($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }
}

private struct DownloadStateLabel: View {
    let progress: ModelState.DownloadProgress

    var body: some View {
        HStack(spacing: 8) {
            if let fraction = progress.fraction {
                Text("\(Int((fraction * 100).rounded()))%")
            }
            if let received = progress.receivedBytes {
                Text(byteText(received: received, total: progress.totalBytes))
            }
            if progress.fraction == nil && progress.receivedBytes == nil {
                ProgressView().controlSize(.small)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func byteText(received: Int64, total: Int64?) -> String {
        let receivedText = ByteCountFormatter.string(
            fromByteCount: received, countStyle: .file)
        if let total {
            let totalText = ByteCountFormatter.string(
                fromByteCount: total, countStyle: .file)
            return "\(receivedText) / \(totalText)"
        }
        return receivedText
    }
}
