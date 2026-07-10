import CryptoKit
import Foundation
import MLSearchCore

public enum MLSearchKeyDerivation {
    public static func localIndexKey(accountUID: String, keyPassword: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(keyPassword.utf8)),
            salt: Data("ProtonPhotos.ml-index.v1.\(accountUID)".utf8),
            info: Data("semantic-search-vectors".utf8),
            outputByteCount: 32
        )
    }
}

public struct CryptoKitMLVectorCipher: MLVectorCipher, Sendable {
    private let key: SymmetricKey
    private let accountUID: String

    public init(key: SymmetricKey, accountUID: String) {
        self.key = key
        self.accountUID = accountUID
    }

    public func seal(_ plaintext: Data, context: MLVectorCipherContext) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData(for: context))
        guard let combined = box.combined else { throw MLVectorCipherError.sealFailed }
        return combined
    }

    public func open(_ ciphertext: Data, context: MLVectorCipherContext) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key, authenticating: associatedData(for: context))
    }

    private func associatedData(for context: MLVectorCipherContext) -> Data {
        let fields = [
            "ns=ml-search",
            "v=1",
            "acct=\(accountUID)",
            "model=\(context.descriptor.identifier)",
            "epoch=\(context.descriptor.version)",
            "dim=\(context.descriptor.embeddingDimension)",
            "vol=\(context.uid.volumeID)",
            "node=\(context.uid.nodeID)",
        ]
        return Data(fields.joined(separator: "\u{1f}").utf8)
    }
}

public enum MLVectorCipherError: Error {
    case sealFailed
}
