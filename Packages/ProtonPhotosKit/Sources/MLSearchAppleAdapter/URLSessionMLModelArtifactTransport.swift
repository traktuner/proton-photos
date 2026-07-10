import Foundation
import MLSearchCore

public enum MLArtifactTransportError: Error, Equatable {
    case httpStatus(Int)
    case notHTTPS
}

/// URLSession byte transport for model artifact downloads.
///
/// Streams straight to the installer-owned destination file, reports byte progress, enforces
/// HTTPS, and rejects non-200 responses. Integrity is not this layer's job — the installer
/// verifies size and SHA-256 before anything becomes loadable.
public struct URLSessionMLModelArtifactTransport: MLModelArtifactTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(
        from url: URL,
        to destination: URL,
        expectedByteCount: Int64,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        guard url.scheme?.lowercased() == "https" else { throw MLArtifactTransportError.notHTTPS }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            throw MLArtifactTransportError.httpStatus(http.statusCode)
        }
        let expectedTotal = http.expectedContentLength > 0 ? http.expectedContentLength : expectedByteCount

        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        fm.createFile(atPath: destination.path, contents: nil)
        applyLocalFileProtection(to: destination)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data(capacity: 1 << 18)
        var received: Int64 = 0
        var lastReported: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 18 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                // At most one progress emission per 256 KiB — no UI storms on fast links.
                if received - lastReported >= 1 << 18 {
                    lastReported = received
                    progress(received, expectedTotal > 0 ? expectedTotal : nil)
                }
                try Task.checkCancellation()
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        progress(received, expectedTotal > 0 ? expectedTotal : nil)
    }

    /// Model artifacts are not secrets, but they should not be readable before first unlock
    /// on devices that support file protection classes.
    private func applyLocalFileProtection(to url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}
