import CryptoKit
import Foundation

/// Verifies `ssh-keygen -Y sign` signatures (OpenSSH's SSHSIG format) made
/// with an Ed25519 key, as Gizlet releases sign their manifests.
public struct SSHSignatureVerifier: Sendable {
    public let publicKey: Data
    public let namespace: String

    /// `key` is an `ssh-ed25519 AAAA...` public key line, as in `allowed_signers`.
    public init(key: String, namespace: String) throws {
        let fields = key.split(separator: " ")
        guard let type = fields.firstIndex(of: "ssh-ed25519"), fields.count > type + 1,
              let blob = Data(base64Encoded: String(fields[type + 1])) else {
            throw SignatureError.badKey
        }
        var reader = SSHReader(blob)
        guard try reader.string() == Data("ssh-ed25519".utf8) else { throw SignatureError.badKey }
        let raw = try reader.string()
        guard raw.count == 32, reader.atEnd else { throw SignatureError.badKey }
        publicKey = raw
        self.namespace = namespace
    }

    /// Succeeds when `armored` is a signature of `message` by this key in this namespace.
    public func verify(_ message: Data, armored: String) throws {
        let lines = armored.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let begin = lines.firstIndex(of: "-----BEGIN SSH SIGNATURE-----"),
              let end = lines.firstIndex(of: "-----END SSH SIGNATURE-----"), begin < end,
              let blob = Data(base64Encoded: lines[(begin + 1)..<end].joined()) else {
            throw SignatureError.malformed
        }
        var reader = SSHReader(blob)
        guard try reader.bytes(6) == Data("SSHSIG".utf8), try reader.uint32() == 1 else { throw SignatureError.malformed }
        let signer = try reader.string()
        let namespace = try reader.string()
        let reserved = try reader.string()
        let hashAlgorithm = try reader.string()
        let signature = try reader.string()
        guard reader.atEnd else { throw SignatureError.malformed }

        var signerReader = SSHReader(signer)
        guard try signerReader.string() == Data("ssh-ed25519".utf8), try signerReader.string() == publicKey else {
            throw SignatureError.untrustedSigner
        }
        guard namespace == Data(self.namespace.utf8) else { throw SignatureError.wrongNamespace }
        let digest: Data
        switch String(decoding: hashAlgorithm, as: UTF8.self) {
        case "sha512": digest = Data(SHA512.hash(data: message))
        case "sha256": digest = Data(SHA256.hash(data: message))
        default: throw SignatureError.malformed
        }
        var signatureReader = SSHReader(signature)
        guard try signatureReader.string() == Data("ssh-ed25519".utf8) else { throw SignatureError.malformed }
        let raw = try signatureReader.string()

        var signed = Data("SSHSIG".utf8)
        for field in [namespace, reserved, hashAlgorithm, digest] {
            signed.append(sshString: field)
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(raw, for: signed) else { throw SignatureError.invalid }
    }
}

public enum SignatureError: Error, LocalizedError, Equatable {
    case badKey, malformed, untrustedSigner, wrongNamespace, invalid

    public var errorDescription: String? {
        switch self {
        case .badKey: "The trusted signing key cannot be read"
        case .malformed: "The signature cannot be read"
        case .untrustedSigner: "The signature is not from the Gizlet release key"
        case .wrongNamespace: "The signature is for another purpose"
        case .invalid: "The signature does not match"
        }
    }
}

struct SSHReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = Data(data)
    }

    var atEnd: Bool { offset == data.count }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw SignatureError.malformed }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func uint32() throws -> UInt32 {
        try bytes(4).u32BE(0)
    }

    mutating func string() throws -> Data {
        try bytes(Int(uint32()))
    }
}

extension Data {
    mutating func append(sshString value: Data) {
        var length = UInt32(value.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(value)
    }
}
