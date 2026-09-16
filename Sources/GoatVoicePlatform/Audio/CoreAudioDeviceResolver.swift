import Foundation

public struct CoreAudioDeviceResolver: AudioDeviceResolving {
    public let hardware: any AudioHardwareBackend

    public init(hardware: any AudioHardwareBackend = CoreAudioHardware()) {
        self.hardware = hardware
    }

    public func inputDevices() throws -> [AudioInputDevice] {
        try mapErrors { try hardware.inputDevices() }
    }

    public func resolve(_ selection: MicrophoneSelection) throws -> AudioInputDevice {
        switch selection {
        case .systemDefault:
            guard let device = try mapErrors({ try hardware.defaultInputDevice() }) else {
                throw AudioDeviceError.noInputDevices
            }
            return device
        case .pinned(let deviceUID, _):
            let devices = try inputDevices()
            guard let device = devices.first(where: { $0.uid == deviceUID }) else {
                throw AudioDeviceError.pinnedDeviceMissing(uid: deviceUID)
            }
            return device
        }
    }

    private func mapErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as AudioDeviceError {
            throw error
        } catch let error as AudioHardwareFailure {
            throw AudioDeviceError.deviceQueryFailed(code: error.code)
        } catch {
            throw AudioDeviceError.deviceQueryFailed(code: -1)
        }
    }
}
