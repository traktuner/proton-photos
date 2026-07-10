import Testing
@testable import ProtonDriveBackend

@Suite("Upload client identity")
struct UploadClientIdentityTests {
    @Test func identityIsStableButDistinctAcrossAccountsAndDevices() {
        let first = UploadClientIdentity.make(accountUID: "account-a", deviceIdentifier: "device-a", prefix: "test_")
        #expect(first == UploadClientIdentity.make(accountUID: "account-a", deviceIdentifier: "device-a", prefix: "test_"))
        #expect(first != UploadClientIdentity.make(accountUID: "account-b", deviceIdentifier: "device-a", prefix: "test_"))
        #expect(first != UploadClientIdentity.make(accountUID: "account-a", deviceIdentifier: "device-b", prefix: "test_"))
        #expect(first.hasPrefix("test_"))
    }
}
