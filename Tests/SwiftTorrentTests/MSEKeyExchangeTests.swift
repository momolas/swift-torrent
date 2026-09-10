import XCTest
@testable import SwiftTorrent

final class MSEKeyExchangeTests: XCTestCase {
    func testBigUIntBasicOps() {
        let a = BigUInt(15)
        let b = BigUInt(4)
        XCTAssertEqual(a + b, BigUInt(19))
        XCTAssertEqual(a - b, BigUInt(11))
        XCTAssertEqual(a * b, BigUInt(60))

        let (div, rem) = a.quotientAndRemainder(dividingBy: b)
        XCTAssertEqual(div, BigUInt(3))
        XCTAssertEqual(rem, BigUInt(3))
    }

    func testBigUIntPowerMod() {
        // 3^5 mod 7 = 243 mod 7 = 5
        let base = BigUInt(3)
        let exp = BigUInt(5)
        let mod = BigUInt(7)
        let result = base.power(exp, modulus: mod)
        XCTAssertEqual(result, BigUInt(5))

        // 2^10 mod 1000 = 1024 mod 1000 = 24
        let res2 = BigUInt(2).power(BigUInt(10), modulus: BigUInt(1000))
        XCTAssertEqual(res2, BigUInt(24))
    }

    func testDiffieHellmanKeyAgreement() throws {
        let alice = MSEKeyExchange()
        let bob = MSEKeyExchange()

        let alicePub = alice.publicKeyData
        let bobPub = bob.publicKeyData

        XCTAssertEqual(alicePub.count, 96)
        XCTAssertEqual(bobPub.count, 96)
        XCTAssertNotEqual(alicePub, bobPub)

        let secretAlice = alice.sharedSecret(remotePublicKeyData: bobPub)
        let secretBob = bob.sharedSecret(remotePublicKeyData: alicePub)

        XCTAssertEqual(secretAlice.count, 96)
        XCTAssertEqual(secretBob.count, 96)
        XCTAssertEqual(secretAlice, secretBob)
    }

    func testKeyDerivationSymmetry() throws {
        let initiator = MSEKeyExchange()
        let receiver = MSEKeyExchange()

        let s1 = initiator.sharedSecret(remotePublicKeyData: receiver.publicKeyData)
        let s2 = receiver.sharedSecret(remotePublicKeyData: initiator.publicKeyData)
        XCTAssertEqual(s1, s2)

        let skey = Data((0..<20).map { UInt8($0 + 0x42) }) // Torrent infohash as SKEY

        let keyA1 = MSEKeyExchange.deriveKeyA(sharedSecret: s1, skey: skey)
        let keyA2 = MSEKeyExchange.deriveKeyA(sharedSecret: s2, skey: skey)
        XCTAssertEqual(keyA1, keyA2)

        let keyB1 = MSEKeyExchange.deriveKeyB(sharedSecret: s1, skey: skey)
        let keyB2 = MSEKeyExchange.deriveKeyB(sharedSecret: s2, skey: skey)
        XCTAssertEqual(keyB1, keyB2)

        let req1_1 = MSEKeyExchange.req1Hash(sharedSecret: s1)
        let req1_2 = MSEKeyExchange.req1Hash(sharedSecret: s2)
        XCTAssertEqual(req1_1, req1_2)

        let req2_1 = MSEKeyExchange.req2Hash(skey: skey)
        let req2_2 = MSEKeyExchange.req2Hash(skey: skey)
        XCTAssertEqual(req2_1, req2_2)

        let req3_1 = MSEKeyExchange.req3Hash(sharedSecret: s1)
        let req3_2 = MSEKeyExchange.req3Hash(sharedSecret: s2)
        XCTAssertEqual(req3_1, req3_2)

        let id1 = MSEKeyExchange.skeyIdentifier(skey: skey, sharedSecret: s1)
        let id2 = MSEKeyExchange.skeyIdentifier(skey: skey, sharedSecret: s2)
        XCTAssertEqual(id1, id2)
    }

    func testEncryptionPolicyValues() {
        let disabled = EncryptionPolicy.disabled
        let preferred = EncryptionPolicy.preferred
        let required = EncryptionPolicy.required

        XCTAssertEqual(disabled.rawValue, 0)
        XCTAssertEqual(preferred.rawValue, 1)
        XCTAssertEqual(required.rawValue, 2)
        XCTAssertEqual(EncryptionPolicy.allCases.count, 3)
    }
}
