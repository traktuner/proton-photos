import Foundation

enum MLModelRequestIdentity {
    static let headerName = "X-ProtonPhotos-App-ID"

    static var appIdentifier: String {
        Bundle.main.bundleIdentifier ?? "me.protonphotos.unknown"
    }

    static func apply(to request: inout URLRequest) {
        request.setValue(appIdentifier, forHTTPHeaderField: headerName)
    }
}
