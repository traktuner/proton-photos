import Foundation
import ProtonDriveSDK
import ProtonCoreDataModel
import ProtonCoreCrypto
import ProtonCoreCryptoGoInterface

/// Supplies the Proton Drive SDK with the user's addresses and their *unlocked* private keys,
/// so the C# core can decrypt node/thumbnail metadata. All key material is unlocked once at
/// sign-in (see `SDKAccountClientBuilder`) and read synchronously here, as the SDK requires.
struct SDKAccountClient: AccountClientProtocol, @unchecked Sendable {
    let addresses: [Address]
    let unlockedByKeyID: [String: Data]

    func getAddress(addressId: String) -> Address? {
        addresses.first { $0.addressID == addressId }
    }

    func getDefaultAddress() -> Address? {
        addresses.min { $0.order < $1.order } ?? addresses.first
    }

    func getAddressPrimaryPrivateKey(addressId: String) -> Data? {
        guard let address = getAddress(addressId: addressId),
              let primary = address.keys.first(where: { $0.primary == 1 }) ?? address.keys.first
        else { return nil }
        return unlockedByKeyID[primary.keyID]
    }

    func getAddressPrivateKeys(addressId: String) -> [Data]? {
        guard let address = getAddress(addressId: addressId) else { return nil }
        let keys = address.keys.filter { $0.active == 1 }.compactMap { unlockedByKeyID[$0.keyID] }
        return keys.isEmpty ? nil : keys
    }

    func getAddressPublicKeysRequest(emailAddress: String) -> [Data] {
        // TODO(Phase 2): return armored public keys for arbitrary emails (signature verification
        // of other users' shared content). For own-library timeline/thumbnails this is not needed.
        []
    }
}

enum SDKAccountClientBuilder {
    /// Unlocks every active address key using the mailbox key password from the fork payload.
    static func build(account: AccountData, keyPassword: String) throws -> SDKAccountClient {
        var unlocked: [String: Data] = [:]

        for address in account.addresses {
            for key in address.keys where key.active == 1 {
                guard let data = try? unlock(key, userKeys: account.userKeys, keyPassword: keyPassword) else {
                    continue
                }
                unlocked[key.keyID] = data
            }
        }
        return SDKAccountClient(addresses: account.addresses, unlockedByKeyID: unlocked)
    }

    private static func unlock(_ key: Key, userKeys: [Key], keyPassword: String) throws -> Data {
        let passphrase = try key.passphrase(userKeys: userKeys, mailboxPassphrase: keyPassword)
        var error: NSError?
        guard let cryptoKey = CryptoGo.CryptoNewKeyFromArmored(key.privateKey, &error), error == nil else {
            throw error ?? CocoaError(.coderInvalidValue)
        }
        let unlockedKey = try cryptoKey.unlock(passphrase.value.data(using: .utf8))
        return try unlockedKey.serialize()
    }
}
