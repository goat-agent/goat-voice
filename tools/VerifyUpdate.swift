import CryptoKit
import Foundation

@main
struct VerifyUpdate {
    static func main() {
        do {
            try verify()
            print("Update signature verified")
        } catch {
            FileHandle.standardError.write(Data("Update signature verification failed\n".utf8))
            exit(1)
        }
    }

    private static func verify() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4,
              let key = Data(base64Encoded: arguments[1]),
              let signature = Data(base64Encoded: arguments[2]) else {
            throw VerificationError.invalidArguments
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
        let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: .mappedIfSafe)
        guard publicKey.isValidSignature(signature, for: archive) else {
            throw VerificationError.invalidSignature
        }
    }

    enum VerificationError: Error {
        case invalidArguments
        case invalidSignature
    }
}
