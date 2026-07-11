import Foundation
import MLSearchCore

public enum MLArtifactTransportError: Error, Equatable {
    case httpStatus(Int)
    case notHTTPS
    case invalidContentRange
    case rangeUnsupported
    case responseTooLarge
}

/// Resumable HTTPS transport for immutable model artifacts.
///
/// Transfers bounded ranges into an installer-owned partial file. A suspended app resumes at
/// the exact byte boundary without retaining a model-sized `Data` value in memory.
public struct URLSessionMLModelArtifactTransport: MLModelArtifactTransport {
    private static let chunkByteCount: Int64 = 8 << 20
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

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var offset = Self.fileSize(at: destination)
        if offset > expectedByteCount {
            try? fm.removeItem(at: destination)
            offset = 0
        }
        progress(offset, expectedByteCount)

        while offset < expectedByteCount {
            try Task.checkCancellation()
            let end = min(expectedByteCount - 1, offset + Self.chunkByteCount - 1)
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            MLModelRequestIdentity.apply(to: &request)

            let (temporaryURL, response) = try await session.download(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

            switch http.statusCode {
            case 206:
                guard Self.contentRangeStart(http.value(forHTTPHeaderField: "Content-Range")) == offset else {
                    throw MLArtifactTransportError.invalidContentRange
                }
                let received = Self.fileSize(at: temporaryURL)
                guard received > 0,
                      received <= end - offset + 1,
                      offset + received <= expectedByteCount else {
                    throw MLArtifactTransportError.responseTooLarge
                }
                try Self.append(temporaryURL, to: destination)
                offset += received
            case 200 where offset == 0:
                let received = Self.fileSize(at: temporaryURL)
                guard received <= expectedByteCount else { throw MLArtifactTransportError.responseTooLarge }
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: temporaryURL, to: destination)
                applyLocalFileProtection(to: destination)
                offset = received
            case 200:
                // Do not keep both a partial and a full fallback response. Discard the partial;
                // the next retry starts cleanly against a server without Range support.
                try? fm.removeItem(at: destination)
                throw MLArtifactTransportError.rangeUnsupported
            default:
                throw MLArtifactTransportError.httpStatus(http.statusCode)
            }
            applyLocalFileProtection(to: destination)
            progress(offset, expectedByteCount)
        }
    }

    private static func append(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            fm.createFile(atPath: destination.path, contents: nil)
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        try output.seekToEnd()
        while let data = try input.read(upToCount: 1 << 20), !data.isEmpty {
            try output.write(contentsOf: data)
        }
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func contentRangeStart(_ value: String?) -> Int64? {
        guard let value, value.hasPrefix("bytes "),
              let range = value.dropFirst(6).split(separator: "/").first,
              let start = range.split(separator: "-").first else { return nil }
        return Int64(start)
    }

    /// Model weights are public, but user-selected downloads should remain unavailable before
    /// first unlock on devices that support file protection classes.
    private func applyLocalFileProtection(to url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}
