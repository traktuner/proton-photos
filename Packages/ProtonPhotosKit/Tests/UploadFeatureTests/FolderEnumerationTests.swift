import XCTest
@testable import UploadCore

final class FolderEnumerationTests: XCTestCase {

    private func makeTree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("enum-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        func write(_ rel: String) throws { try Data("x".utf8).write(to: root.appendingPathComponent(rel)) }
        try write("photo1.jpg")
        try write(".hidden.jpg")        // hidden - skipped by default
        try write("note.txt")           // unsupported - reported, not uploaded
        try write("sub/photo2.png")     // nested media
        try write("sub/clip.mov")       // nested video
        try write("sub/.DS_Store")      // hidden junk
        return root
    }

    func testDiscoversMediaRecursivelyAndSkipsHiddenAndUnsupported() throws {
        let root = try makeTree()
        let result = FolderEnumerator.enumerate(root)
        let names = Set(result.mediaFiles.map(\.lastPathComponent))
        XCTAssertEqual(names, ["photo1.jpg", "photo2.png", "clip.mov"])
        XCTAssertFalse(names.contains(".hidden.jpg"))
        XCTAssertEqual(result.skippedUnsupported.map(\.lastPathComponent), ["note.txt"])
    }

    func testDeterministicOrdering() throws {
        let root = try makeTree()
        let a = FolderEnumerator.enumerate(root).mediaFiles.map(\.path)
        let b = FolderEnumerator.enumerate(root).mediaFiles.map(\.path)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, a.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    func testIncludeHiddenOptIn() throws {
        let root = try makeTree()
        let names = Set(FolderEnumerator.enumerate(root, includeHidden: true).mediaFiles.map(\.lastPathComponent))
        XCTAssertTrue(names.contains(".hidden.jpg"))
    }
}

final class SupportedMediaTests: XCTestCase {
    func testImageAndVideoDetection() {
        XCTAssertEqual(SupportedMedia.mimeType(for: URL(fileURLWithPath: "/x/a.JPG")), "image/jpeg")
        XCTAssertEqual(SupportedMedia.mimeType(for: URL(fileURLWithPath: "/x/a.heic")), "image/heic")
        XCTAssertEqual(SupportedMedia.mimeType(for: URL(fileURLWithPath: "/x/a.DNG")), "image/x-adobe-dng")
        XCTAssertEqual(SupportedMedia.kind(for: URL(fileURLWithPath: "/x/a.mov")), .video)
        XCTAssertEqual(SupportedMedia.mimeType(for: URL(fileURLWithPath: "/x/a.mp4")), "video/mp4")
    }

    func testUnsupportedReturnsNil() {
        XCTAssertNil(SupportedMedia.mimeType(for: URL(fileURLWithPath: "/x/a.txt")))
        XCTAssertFalse(SupportedMedia.isSupported(URL(fileURLWithPath: "/x/a.pdf")))
    }
}
