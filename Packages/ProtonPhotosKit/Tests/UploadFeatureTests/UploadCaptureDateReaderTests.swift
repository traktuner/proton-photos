import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import UploadCore

final class UploadCaptureDateReaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-capture-date-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testReaderPrefersExifDateTimeOriginalOverFileDates() async throws {
        let url = tempDir.appendingPathComponent("IMG_OLD.JPG")
        let expected = try writeJPEGWithExifDate(
            at: url,
            dateTimeOriginal: "2014:05:06 07:08:09",
            offset: "+00:00"
        )
        let fallback = try date("2026-01-02T03:04:05Z")
        try setFileDates(url, fallback)

        let actual = await UploadCaptureDateReader.captureDate(for: url, fallback: fallback)

        XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testManualUploadUsesExifCaptureDate() async throws {
        let url = tempDir.appendingPathComponent("manual.jpg")
        let expected = try writeJPEGWithExifDate(
            at: url,
            dateTimeOriginal: "2015:06:07 08:09:10",
            offset: "+00:00"
        )
        try setFileDates(url, try date("2026-02-03T04:05:06Z"))
        let uploader = MockUploader(deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)

        await manager.enqueueFiles([url], destination: .library)
        _ = await waitForAllTerminal(manager)

        let request = try XCTUnwrap(uploader.requests.first)
        XCTAssertEqual(request.captureTime.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testFolderBackupResolverUsesExifCaptureDate() async throws {
        let url = tempDir.appendingPathComponent("folder.jpg")
        let expected = try writeJPEGWithExifDate(
            at: url,
            dateTimeOriginal: "2016:07:08 09:10:11",
            offset: "+00:00"
        )
        try setFileDates(url, try date("2026-03-04T05:06:07Z"))
        let entry = UploadBackupSyncQueueEntry(
            source: .file(url),
            revision: UploadBackupRevision(date: Date()),
            originalFilename: url.lastPathComponent,
            state: .queuedForUpload,
            updatedAt: Date()
        )

        let resolvedCandidate = try await FileBackupResourceResolver().resolve(entry)
        let resolved = try XCTUnwrap(resolvedCandidate)

        XCTAssertEqual(resolved.captureDate.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    private func writeJPEGWithExifDate(at url: URL, dateTimeOriginal: String, offset: String) throws -> Date {
        let pixels = Data([0xFF, 0x00, 0x00, 0xFF])
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: dateTimeOriginal,
                "OffsetTimeOriginal": offset,
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try exifDate(dateTimeOriginal + offset)
    }

    private func setFileDates(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes(
            [.creationDate: date, .modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    private func date(_ raw: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: raw))
    }

    private func exifDate(_ raw: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
        return try XCTUnwrap(formatter.date(from: raw))
    }
}
