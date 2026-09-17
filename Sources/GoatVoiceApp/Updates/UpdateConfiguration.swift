import Foundation

enum UpdateConfiguration: Equatable, Sendable {
    enum Issue: String, Equatable, Sendable, Error {
        case missingFeedURL
        case malformedFeedURL
        case insecureFeedURL
        case missingPublicKey
        case malformedPublicKey
    }

    case notConfigured
    case configured(feedURL: URL)
    case misconfigured([Issue])

    private static let feedURLInfoKey = "SUFeedURL"
    private static let publicKeyInfoKey = "SUPublicEDKey"
    private static let ed25519PublicKeyByteCount = 32
    private static let feedQuoteCharacters = CharacterSet(charactersIn: "\"'")

    var isUsable: Bool {
        if case .configured = self { return true }
        return false
    }

    init(feedURLValue: Any?, publicKeyValue: Any?) {
        guard feedURLValue != nil || publicKeyValue != nil else {
            self = .notConfigured
            return
        }
        var issues: [Issue] = []
        var feedURL: URL?
        switch Self.validateFeedURL(feedURLValue) {
        case .success(let url):
            feedURL = url
        case .failure(let issue):
            issues.append(issue)
        }
        if let issue = Self.validatePublicKey(publicKeyValue) {
            issues.append(issue)
        }
        if issues.isEmpty, let feedURL {
            self = .configured(feedURL: feedURL)
        } else {
            self = .misconfigured(issues)
        }
    }

    init(bundle: Bundle) {
        self.init(
            feedURLValue: bundle.object(forInfoDictionaryKey: Self.feedURLInfoKey),
            publicKeyValue: bundle.object(forInfoDictionaryKey: Self.publicKeyInfoKey)
        )
    }

    private static func validateFeedURL(_ value: Any?) -> Result<URL, Issue> {
        guard let string = value as? String else {
            return .failure(value == nil ? .missingFeedURL : .malformedFeedURL)
        }
        let trimmed = string.trimmingCharacters(in: feedQuoteCharacters)
        guard !trimmed.isEmpty else {
            return .failure(.missingFeedURL)
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty else {
            return .failure(.malformedFeedURL)
        }
        guard scheme.lowercased() == "https" else {
            return .failure(.insecureFeedURL)
        }
        guard let host = url.host, !host.isEmpty else {
            return .failure(.malformedFeedURL)
        }
        return .success(url)
    }

    private static func validatePublicKey(_ value: Any?) -> Issue? {
        guard let string = value as? String else {
            return value == nil ? .missingPublicKey : .malformedPublicKey
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .missingPublicKey
        }
        guard let data = Data(base64Encoded: trimmed), data.count == ed25519PublicKeyByteCount else {
            return .malformedPublicKey
        }
        return nil
    }
}
