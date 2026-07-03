import CryptoKit
import Foundation
import Testing
@testable import ProtonAuth

@Suite("Proton fork authentication")
struct ProtonForkAuthenticatorTests {
    @Test func defaultProtonAPIConfigIdentifiesProtonPhotos() {
        let config = ProtonAPIConfig()

        #expect(config.appVersion == "protonphotos@1.0.0-stable")
        #expect(config.authClientID == "protonphotos")
    }

    @Test func defaultSignInPayloadIdentifiesProtonPhotosClient() async throws {
        let authenticator = ProtonForkAuthenticator()
        let key = SymmetricKey(data: Data(repeating: 0, count: 32))

        let url = await authenticator.signInURL(userCode: "USER-CODE", encryptionKey: key)
        let fragment = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment)
        let encodedPayload = try #require(fragment.split(separator: "payload=").last.map(String.init))
        let payload = try #require(encodedPayload.removingPercentEncoding)

        #expect(url.absoluteString.hasPrefix("https://account.proton.me/desktop/login?app=drive&pv=3#payload="))
        #expect(payload.hasPrefix("0:USER-CODE:"))
        #expect(payload.hasSuffix(":protonphotos"))
        #expect(!payload.hasSuffix(":external-drive"))
    }
}
