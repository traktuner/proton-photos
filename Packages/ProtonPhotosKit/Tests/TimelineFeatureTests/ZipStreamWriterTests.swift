import Testing
import Foundation
import PhotosCore

struct ZipStreamWriterTests {
    /// Writes a real archive to /tmp so an external `unzip -t` can confirm it's a valid, extractable zip
    /// (the byte layout is what matters; this just exercises + leaves the artifact).
    @Test func writesAStoreZip() throws {
        let url = URL(fileURLWithPath: "/tmp/proton-ziptest.zip")
        try? FileManager.default.removeItem(at: url)
        let w = try ZipStreamWriter(url: url)
        try w.addFile(name: "hello.txt", data: Data("hello world".utf8))
        try w.addFile(name: "folder/blob.bin", data: Data((0..<200_000).map { UInt8($0 & 0xFF) }))
        try w.finish()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// Known-answer test for the CRC-32 implementation (zip requires IEEE CRC-32).
    @Test func crc32MatchesKnownAnswer() {
        #expect(ZipStreamWriter.crc32(Data("hello world".utf8)) == 0x0D4A_1185)
        #expect(ZipStreamWriter.crc32(Data()) == 0)
    }
}
