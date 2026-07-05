import Foundation
import ProtonCoreCryptoGoInterface

/// An address private key together with the identity Proton expects in `SignatureEmail` /
/// `NameSignatureEmail` fields. Write operations must sign with an address key AND name its email.
struct DriveCryptoSigner: Sendable {
    let addressID: String
    let email: String
    let key: UnlockableKey
}

enum DriveCryptoWriteError: Error {
    case randomFailed
    case keyGenerationFailed
    case armorFailed
    case encryptFailed
}

/// The minimum WRITE crypto needed for Proton album operations, mirroring the reference clients'
/// node-creation semantics (verified against the web client's drive key helpers and the photos
/// album API):
///  • a node key is a locked PGP key (x25519) whose passphrase is PGP-encrypted to the PARENT
///    node key, with a DETACHED address-key signature (`NodePassphrase` + `NodePassphraseSignature`),
///  • a folder/album hash key is a random token encrypted to the node's OWN key with an embedded
///    address-key signature (`NodeHashKey`),
///  • names are encrypted to the parent node key with an embedded address-key signature,
///  • lookup hashes are HMAC-SHA256 keyed with the parent's decrypted hash key (`ProtonPhotoHMAC`).
///
/// Nothing here logs or persists plaintext key material; callers hold results in memory only.
extension DriveCrypto {

    /// The signer for a share: the address that owns the share when known, else the primary
    /// (first-listed) address. `nil` only when the account has no usable address key at all.
    func signer(preferredAddressID: String?) -> DriveCryptoSigner? {
        if let preferredAddressID,
           let match = signers.first(where: { $0.addressID == preferredAddressID }) {
            return match
        }
        return signers.first
    }

    /// 32 random bytes, base64 - the reference clients' passphrase/hash-key token format.
    func randomBase64Token() throws -> String {
        var error: NSError?
        guard let data = CryptoGo.CryptoRandomToken(32, &error), error == nil else {
            throw DriveCryptoWriteError.randomFailed
        }
        return data.base64EncodedString()
    }

    /// Generates a fresh x25519 node key locked with `passphrase`, returned armored.
    func generateLockedNodeKey(passphrase: String) throws -> String {
        var error: NSError?
        guard let key = CryptoGo.CryptoGenerateKey("Drive key", "noreply@proton.me", "x25519", 0, &error),
              error == nil else {
            throw DriveCryptoWriteError.keyGenerationFailed
        }
        let locked = try key.lock(passphrase.data(using: .utf8))
        _ = key.clearPrivateParams()
        let armored = locked.armor(&error)
        guard error == nil, !armored.isEmpty else { throw DriveCryptoWriteError.armorFailed }
        return armored
    }

    /// Encrypts `text` to `recipient`'s key with an EMBEDDED signature by `signer` (names, hash keys).
    func encryptAndSign(text: String, to recipient: UnlockableKey, signer: DriveCryptoSigner) throws -> String {
        let recipientRing = try ring([recipient])
        let signerRing = try ring([signer.key])
        defer {
            recipientRing.clearPrivateParams()
            signerRing.clearPrivateParams()
        }
        let plain = CryptoGo.CryptoNewPlainMessageFromString(text)
        let message = try recipientRing.encrypt(plain, privateKey: signerRing)
        var error: NSError?
        let armored = message.getArmored(&error)
        guard error == nil, !armored.isEmpty else { throw DriveCryptoWriteError.encryptFailed }
        return armored
    }

    /// Encrypts `text` to `recipient`'s key WITHOUT a signature. Used to re-encrypt an existing
    /// photo passphrase to an album key: the passphrase plaintext is unchanged, so the link's
    /// original detached passphrase signature stays valid and is kept server-side (the reference
    /// clients omit the signature fields for the owner's own photos too).
    func encrypt(text: String, to recipient: UnlockableKey) throws -> String {
        let recipientRing = try ring([recipient])
        defer { recipientRing.clearPrivateParams() }
        let plain = CryptoGo.CryptoNewPlainMessageFromString(text)
        let message = try recipientRing.encrypt(plain, privateKey: nil)
        var error: NSError?
        let armored = message.getArmored(&error)
        guard error == nil, !armored.isEmpty else { throw DriveCryptoWriteError.encryptFailed }
        return armored
    }

    /// Encrypts `text` to `recipient`'s key and produces a DETACHED armored signature by `signer`
    /// (the `NodePassphrase` + `NodePassphraseSignature` pair).
    func encryptWithDetachedSignature(
        text: String,
        to recipient: UnlockableKey,
        signer: DriveCryptoSigner
    ) throws -> (message: String, signature: String) {
        let recipientRing = try ring([recipient])
        let signerRing = try ring([signer.key])
        defer {
            recipientRing.clearPrivateParams()
            signerRing.clearPrivateParams()
        }
        let plain = CryptoGo.CryptoNewPlainMessageFromString(text)
        let message = try recipientRing.encrypt(plain, privateKey: nil)
        let signature = try signerRing.signDetached(plain)
        var error: NSError?
        let armoredMessage = message.getArmored(&error)
        guard error == nil, !armoredMessage.isEmpty else { throw DriveCryptoWriteError.encryptFailed }
        let armoredSignature = signature.getArmored(&error)
        guard error == nil, !armoredSignature.isEmpty else { throw DriveCryptoWriteError.encryptFailed }
        return (armoredMessage, armoredSignature)
    }

    /// Decrypts a link's armored `NodePassphrase` with its parent key → the cleartext passphrase
    /// string (needed to RE-encrypt the same passphrase to an album key when adding to an album).
    func decryptPassphrase(_ armored: String, parent: UnlockableKey) throws -> String {
        try decryptArmored(armored, with: [parent]).getString()
    }
}
