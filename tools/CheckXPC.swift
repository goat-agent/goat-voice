import Foundation

@main
struct Check {
    static func main() async {
        let client = TranscriptionXPCClient(backend: NSXPCServiceBackend())
        do {
            let info = try await client.handshake()
            guard info.protocolVersion == GoatVoiceServiceWire.protocolVersion,
                  info.engines["qwen3-asr-1.7b"] == true,
                  info.engines["whisper-large-v3-turbo"] == true else {
                print("XPC handshake returned unexpected capabilities")
                exit(2)
            }
            print("Embedded XPC handshake passed; both real ASR adapters available")
            await client.invalidate()
            exit(0)
        } catch {
            print("Embedded XPC handshake failed: \(error)")
            exit(1)
        }
    }
}
