import Foundation

/// The R36S card image of a Gizlet OS release, with the size and SHA-256 its
/// signed manifest gives: the only digest the image is checked against.
public struct OSImageRelease: Equatable, Sendable {
    public var tag: String
    public var image: URL
    public var sha256: String
    public var bytes: UInt64
    public var fileName: String { image.lastPathComponent }

    public init(tag: String, image: URL, sha256: String, bytes: UInt64) {
        self.tag = tag
        self.image = image
        self.sha256 = sha256
        self.bytes = bytes
    }
}

/// Finds the newest Gizlet OS release through `gizlet.io/api/v1/os/releases/latest`
/// and checks that its manifest, under `gizlet.io/assets/releases/<tag>/`, is
/// signed with the Gizlet OS release key, as the handheld does.
public struct OSReleaseFeed: Sendable {
    public static let latestURL = URL(string: "https://gizlet.io/api/v1/os/releases/latest")!
    public var latestURL: URL
    var verifier: SSHSignatureVerifier
    var session: URLSession

    public init(latestURL: URL = OSReleaseFeed.latestURL, key: String = TrustedKeys.osRelease, session: URLSession = .shared) throws {
        self.latestURL = latestURL
        verifier = try SSHSignatureVerifier(key: key, namespace: TrustedKeys.osReleaseNamespace)
        self.session = session
    }

    public func latest() async throws -> OSImageRelease {
        struct Latest: Decodable {
            var tag: String
            var manifest_url: URL
            var signature_url: URL
        }
        let request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let (body, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let latest = try? JSONDecoder().decode(Latest.self, from: body) else {
            throw FlashError.release("the latest release cannot be found")
        }
        // The files must come from the same site as the API, beside each other.
        let base = latest.manifest_url.deletingLastPathComponent()
        guard latest.manifest_url.scheme == latestURL.scheme, latest.manifest_url.host == latestURL.host,
              latest.signature_url == latest.manifest_url.appendingPathExtension("sig") else {
            throw FlashError.release("the release is not on \(latestURL.host ?? "the Gizlet site")")
        }
        let (manifest, manifestResponse) = try await session.data(for: URLRequest(url: latest.manifest_url, cachePolicy: .reloadIgnoringLocalCacheData))
        guard (manifestResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw FlashError.release("the release manifest cannot be downloaded")
        }
        let (signature, signatureResponse) = try await session.data(for: URLRequest(url: latest.signature_url, cachePolicy: .reloadIgnoringLocalCacheData))
        guard (signatureResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw FlashError.release("the release manifest's signature cannot be downloaded")
        }
        return try parse(manifest: manifest, signature: String(decoding: signature, as: UTF8.self), base: base)
    }

    /// Checks the signature, the tag against the version folder, the image path,
    /// and that the signed manifest gives the image's size and SHA-256.
    public func parse(manifest: Data, signature: String, base: URL) throws -> OSImageRelease {
        do {
            try verifier.verify(manifest, armored: signature)
        } catch {
            throw FlashError.release("the release manifest is not signed by Gizlet (\(error.localizedDescription))")
        }
        struct Manifest: Decodable {
            struct Image: Decodable { var path: String; var sha256: String?; var bytes: UInt64? }
            struct Board: Decodable { var image: Image }
            var schema_version: Int
            var tag: String
            var boards: [String: [String: Board]]
        }
        guard let decoded = try? JSONDecoder().decode(Manifest.self, from: manifest), decoded.schema_version == 1,
              ReleaseVersion(decoded.tag)?.tag == decoded.tag else {
            throw FlashError.release("the release manifest cannot be read")
        }
        guard base.lastPathComponent == decoded.tag else { throw FlashError.release("the manifest is for \(decoded.tag), not \(base.lastPathComponent)") }
        guard let image = decoded.boards["gameconsole"]?["r36s"]?.image else { throw FlashError.release("the release has no R36S image") }
        if relativePathProblem(image.path) != nil || !image.path.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) }) {
            throw FlashError.release("the release manifest names an invalid file")
        }
        // SHA256SUMS beside the image is not signed, so only a digest in the manifest counts.
        guard let sha256 = image.sha256, isSHA256Hex(sha256), let bytes = image.bytes, bytes > 0 else {
            throw FlashError.release("\(decoded.tag) does not sign its image's checksum; a newer Gizlet OS release is needed, or choose a local image")
        }
        return OSImageRelease(tag: decoded.tag, image: base.appendingPathComponent(image.path), sha256: sha256, bytes: bytes)
    }
}

public enum FlashError: Error, LocalizedError, Equatable {
    case release(String)
    case image(String)
    case disk(String)
    case cardChanged
    case cancelled
    case authorization(String)
    case write(String)
    case verify(String)

    public var errorDescription: String? {
        switch self {
        case .release(let message): "Cannot use the Gizlet OS release: \(message)"
        case .image(let message): message
        case .disk(let message): message
        case .cardChanged: "The card changed since it was confirmed; nothing was written. Choose the card and confirm again."
        case .cancelled: "Cancelled"
        case .authorization(let message): message
        case .write(let message): message
        case .verify(let message): message
        }
    }
}
