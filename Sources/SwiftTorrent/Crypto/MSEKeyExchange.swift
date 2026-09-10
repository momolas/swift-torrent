import Foundation
import CryptoKit

/// Diffie-Hellman 768-bit key exchange for BitTorrent Message Stream Encryption (MSE/PE).
public struct MSEKeyExchange: Sendable {

    // MARK: - Constants

    /// BitTorrent MSE standard 768-bit prime P.
    public static let prime: BigUInt = BigUInt(hex:
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1" +
        "29024E088A67CC74020BBEA63B139B22514A08798E3404DD" +
        "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245" +
        "E485B576625E7EC6F44C42E9A63A36210000000000090563"
    )!

    /// Generator g = 2.
    public static let generator = BigUInt(2)

    // MARK: - Key Material

    /// Our private key X (160-bit random).
    public let privateKey: BigUInt
    /// Our public key Y = g^X mod P (96 bytes).
    public let publicKey: BigUInt
    /// Our public key as 96-byte big-endian Data.
    public let publicKeyData: Data

    // MARK: - Initialization

    /// Generate a new key pair with a random 160-bit private key.
    public init() {
        var randomBytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, 20, &randomBytes)
        let x = BigUInt(bigEndian: Data(randomBytes))
        self.privateKey = x
        self.publicKey = Self.generator.power(x, modulus: Self.prime)
        self.publicKeyData = self.publicKey.toData(paddedToLength: 96)
    }

    /// Initialize with a known private key (for testing).
    public init(privateKey: BigUInt) {
        self.privateKey = privateKey
        self.publicKey = Self.generator.power(privateKey, modulus: Self.prime)
        self.publicKeyData = self.publicKey.toData(paddedToLength: 96)
    }

    // MARK: - Shared Secret

    /// Compute the shared secret S = remotePublicKey^privateKey mod P.
    public func sharedSecret(remotePublicKeyData: Data) -> Data {
        let remotePubKey = BigUInt(bigEndian: remotePublicKeyData)
        let s = remotePubKey.power(privateKey, modulus: Self.prime)
        return s.toData(paddedToLength: 96)
    }

    // MARK: - Key Derivation (for ARC4 ciphers)

    /// Derive the encryption key for the initiator -> receiver direction.
    /// keyA = SHA1("keyA" + S + SKEY)
    public static func deriveKeyA(sharedSecret: Data, skey: Data) -> Data {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("keyA".utf8))
        hasher.update(data: sharedSecret)
        hasher.update(data: skey)
        return Data(hasher.finalize())
    }

    /// Derive the encryption key for the receiver -> initiator direction.
    /// keyB = SHA1("keyB" + S + SKEY)
    public static func deriveKeyB(sharedSecret: Data, skey: Data) -> Data {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("keyB".utf8))
        hasher.update(data: sharedSecret)
        hasher.update(data: skey)
        return Data(hasher.finalize())
    }

    // MARK: - Verification Hashes

    /// HASH('req1' + S) — used by initiator to prove knowledge of S.
    public static func req1Hash(sharedSecret: Data) -> Data {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("req1".utf8))
        hasher.update(data: sharedSecret)
        return Data(hasher.finalize())
    }

    /// HASH('req2' + SKEY) — used for SKEY identification.
    public static func req2Hash(skey: Data) -> Data {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("req2".utf8))
        hasher.update(data: skey)
        return Data(hasher.finalize())
    }

    /// HASH('req3' + S) — XORed with req2Hash for obfuscation.
    public static func req3Hash(sharedSecret: Data) -> Data {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("req3".utf8))
        hasher.update(data: sharedSecret)
        return Data(hasher.finalize())
    }

    /// Compute req2Hash(skey) XOR req3Hash(S) — the obfuscated SKEY identifier sent by initiator.
    public static func skeyIdentifier(skey: Data, sharedSecret: Data) -> Data {
        let r2 = req2Hash(skey: skey)
        let r3 = req3Hash(sharedSecret: sharedSecret)
        var result = Data(count: 20)
        for i in 0..<20 {
            result[i] = r2[i] ^ r3[i]
        }
        return result
    }
}

// MARK: - Encryption Policy

/// Encryption preferences for peer connections.
public enum EncryptionPolicy: Int, Sendable, Codable, CaseIterable {
    /// Plaintext only — no encryption attempted.
    case disabled = 0
    /// Prefer encrypted connections, fall back to plaintext.
    case preferred = 1
    /// Require encryption — reject plaintext connections.
    case required = 2
}

/// MSE crypto method flags (negotiated during handshake).
public struct CryptoProvide: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Plaintext (no encryption after handshake).
    public static let plaintext = CryptoProvide(rawValue: 0x01)
    /// RC4 stream encryption.
    public static let rc4 = CryptoProvide(rawValue: 0x02)
}
