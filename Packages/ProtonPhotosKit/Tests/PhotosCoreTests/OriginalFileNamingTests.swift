import XCTest
@testable import PhotosCore

/// Byte-fixture coverage for the shared export-extension resolver. Encodes the Task 4 acceptance
/// criteria: HEIC bytes export `.heic` (even when the timeline `mediaType` lies with `image/jpeg`),
/// JPEG bytes export `.jpg`, MOV/MP4 keep their container extension, and the real Proton filename
/// out-ranks every weaker signal.
final class OriginalFileNamingTests: XCTestCase {

    // MARK: - Byte fixtures

    /// An ISO-BMFF `ftyp` box header for the given 4-char brand (size + "ftyp" + brand + one compat).
    private func ftyp(_ brand: String) -> Data {
        var d = Data([0x00, 0x00, 0x00, 0x18])          // box size (arbitrary)
        d.append(Data("ftyp".utf8))
        d.append(Data(brand.padding(toLength: 4, withPad: " ", startingAt: 0).utf8))
        d.append(Data("mp41".utf8))                     // a compatible brand, padding out the box
        return d
    }

    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    private let gif = Data("GIF89a".utf8)
    private var heic: Data { ftyp("heic") }
    private var heif: Data { ftyp("mif1") }
    private var mov: Data { ftyp("qt  ") }
    private var mp4: Data { ftyp("isom") }
    private var tiff: Data { Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00]) }
    private var webp: Data { Data("RIFF".utf8) + Data([0x24, 0x00, 0x00, 0x00]) + Data("WEBP".utf8) }

    // MARK: - Header sniffing (the ground truth)

    func testHeaderSniffDistinguishesFormats() {
        XCTAssertEqual(OriginalFileNaming.extensionForHeader(jpeg), "jpg")
        XCTAssertEqual(OriginalFileNaming.extensionForHeader(png), "png")
        XCTAssertEqual(OriginalFileNaming.extensionForHeader(gif), "gif")
        XCTAssertEqual(OriginalFileNaming.extensionForHeader(heic), "heic")
        XCTAssertEqual(OriginalFileNaming.extensionForHeader(heif), "heif")
        XCTAssertEqual(OriginalFileNaming.extensionForHeader(mov), "mov")
        XCTAssertEqual(OriginalFileNaming.extensionForHeader(mp4), "mp4")
        XCTAssertEqual(OriginalFileNaming.extensionForHeader(tiff), "tiff")
        XCTAssertEqual(OriginalFileNaming.extensionForHeader(webp), "webp")
        XCTAssertNil(OriginalFileNaming.extensionForHeader(Data([0x00, 0x01])))
    }

    /// A sliced (non-zero-based) Data must still sniff correctly — the resolver rebases internally.
    func testHeaderSniffHandlesSlicedData() {
        let padded = Data([0xAA, 0xBB]) + heic
        let slice = padded.dropFirst(2)   // startIndex == 2, not 0
        XCTAssertEqual(OriginalFileNaming.extensionForHeader(slice), "heic")
    }

    // MARK: - Task 4 acceptance criteria

    /// HEIC byte fixture exports `.heic`.
    func testHEICBytesExportAsHeic() {
        XCTAssertEqual(
            OriginalFileNaming.fileExtension(filename: nil, mimeType: nil, header: heic), "heic"
        )
    }

    /// JPEG byte fixture exports `.jpg`.
    func testJPEGBytesExportAsJpg() {
        XCTAssertEqual(
            OriginalFileNaming.fileExtension(filename: nil, mimeType: nil, header: jpeg), "jpg"
        )
    }

    /// MOV/MP4 fixtures export the correct container extension.
    func testVideoBytesExportCorrectExtension() {
        XCTAssertEqual(OriginalFileNaming.fileExtension(filename: nil, mimeType: nil, header: mov), "mov")
        XCTAssertEqual(OriginalFileNaming.fileExtension(filename: nil, mimeType: nil, header: mp4), "mp4")
    }

    /// The lossy timeline `mediaType=image/jpeg` must NOT force `.jpg` when the bytes prove HEIC.
    func testPlaceholderMediaTypeDoesNotOverrideHEICBytes() {
        XCTAssertEqual(
            OriginalFileNaming.fileExtension(
                filename: nil, mimeType: "image/jpeg", header: heic, fallbackMediaType: "image/jpeg"
            ),
            "heic"
        )
    }

    /// The real Proton filename out-ranks a lying MIME and even mismatched bytes — it IS the original.
    func testRealFilenameWinsOverMimeAndBytes() {
        XCTAssertEqual(
            OriginalFileNaming.fileExtension(
                filename: "IMG_0001.HEIC", mimeType: "image/jpeg", header: jpeg
            ),
            "heic"
        )
        // A ".jpeg" filename is preserved verbatim (both .jpg and .jpeg are acceptable per the spec).
        XCTAssertEqual(
            OriginalFileNaming.fileExtension(filename: "vacation.jpeg", mimeType: nil, header: nil),
            "jpeg"
        )
    }

    /// A trustworthy (non-placeholder) MIME is used before falling back to bytes.
    func testTrustworthyMimeUsedBeforeHeader() {
        XCTAssertEqual(
            OriginalFileNaming.fileExtension(filename: nil, mimeType: "image/png", header: nil), "png"
        )
        XCTAssertEqual(
            OriginalFileNaming.fileExtension(filename: nil, mimeType: "video/mp4", header: nil), "mp4"
        )
        // charset parameters and casing are tolerated.
        XCTAssertEqual(
            OriginalFileNaming.fileExtension(filename: nil, mimeType: "IMAGE/HEIC; charset=binary", header: nil),
            "heic"
        )
    }

    /// A genuine JPEG with only the placeholder MIME and nothing to sniff still resolves to `.jpg`.
    func testGenuineJpegPlaceholderMimeFallsBackToJpg() {
        XCTAssertEqual(
            OriginalFileNaming.fileExtension(filename: nil, mimeType: "image/jpeg", header: nil), "jpg"
        )
    }

    /// Nothing resolvable → `nil`, and `resolvedExtension` applies the video/image last-resort default.
    func testResolvedExtensionFallback() {
        XCTAssertNil(OriginalFileNaming.fileExtension(filename: nil, mimeType: nil, header: nil))
        XCTAssertEqual(
            OriginalFileNaming.resolvedExtension(
                filename: nil, mimeType: nil, header: nil, fallbackMediaType: nil, isVideo: true
            ),
            "mov"
        )
        XCTAssertEqual(
            OriginalFileNaming.resolvedExtension(
                filename: nil, mimeType: nil, header: nil, fallbackMediaType: nil, isVideo: false
            ),
            "jpg"
        )
    }

    /// An unrecognised filename extension is ignored (not blindly trusted).
    func testUnknownFilenameExtensionIgnored() {
        XCTAssertNil(OriginalFileNaming.recognizedExtension(fromFilename: "notes.txt"))
        XCTAssertNil(OriginalFileNaming.recognizedExtension(fromFilename: "noextension"))
        XCTAssertNil(OriginalFileNaming.recognizedExtension(fromFilename: ""))
        XCTAssertEqual(OriginalFileNaming.recognizedExtension(fromFilename: "clip.MOV"), "mov")
    }

    // MARK: - exportFilename (the metadata-first naming decision shared by export + Photos-save)

    /// THE acceptance criterion: a real HEIC original keeps its exact name — no `ProtonPhotos-*`, no `.jpg`.
    /// Extension case is preserved verbatim (the base filename must remain the original).
    func testExportFilenameKeepsRealHeicNameVerbatim() {
        XCTAssertEqual(
            OriginalFileNaming.exportFilename(
                metadataFilename: "IMG_0001.HEIC", fallbackBase: "ProtonPhotos-20260101-000000-abcdef", ext: "heic"
            ),
            "IMG_0001.HEIC"
        )
        // A real MOV likewise stays a MOV, not the generated name.
        XCTAssertEqual(
            OriginalFileNaming.exportFilename(
                metadataFilename: "clip.MOV", fallbackBase: "ProtonPhotos-x", ext: "mov"
            ),
            "clip.MOV"
        )
    }

    /// No usable original name → the generated fallback base + resolved extension (the ONLY time a
    /// `ProtonPhotos-*` name is allowed).
    func testExportFilenameFallsBackWhenNoMetadataName() {
        XCTAssertEqual(
            OriginalFileNaming.exportFilename(
                metadataFilename: nil, fallbackBase: "ProtonPhotos-20260704-120000-abcdef", ext: "jpg"
            ),
            "ProtonPhotos-20260704-120000-abcdef.jpg"
        )
        // Empty / whitespace-only names are treated as "no name".
        XCTAssertEqual(
            OriginalFileNaming.exportFilename(metadataFilename: "   ", fallbackBase: "Base", ext: "png"),
            "Base.png"
        )
    }

    /// A real base name that lacks a (recognised) extension keeps the base and gains the sniffed extension —
    /// never dropping the original name, never mislabelling the format.
    func testExportFilenameAppendsSniffedExtensionWhenNameHasNone() {
        XCTAssertEqual(
            OriginalFileNaming.exportFilename(metadataFilename: "IMG_0001", fallbackBase: "Base", ext: "heic"),
            "IMG_0001.heic"
        )
        XCTAssertEqual(
            OriginalFileNaming.exportFilename(metadataFilename: "notes.txt", fallbackBase: "Base", ext: "jpg"),
            "notes.txt.jpg"
        )
    }

    /// A hostile / path-bearing link name can never escape the export directory: it is reduced to its last
    /// component before use, so no traversal or nested-folder creation is possible.
    func testExportFilenameSanitisesPathTraversal() {
        XCTAssertEqual(
            OriginalFileNaming.exportFilename(
                metadataFilename: "../../etc/passwd.heic", fallbackBase: "Base", ext: "heic"
            ),
            "passwd.heic"
        )
    }

    /// The sanitiser rejects unusable names and flattens paths to their last component.
    func testSanitizedOriginalName() {
        XCTAssertNil(OriginalFileNaming.sanitizedOriginalName(nil))
        XCTAssertNil(OriginalFileNaming.sanitizedOriginalName(""))
        XCTAssertNil(OriginalFileNaming.sanitizedOriginalName("   "))
        XCTAssertNil(OriginalFileNaming.sanitizedOriginalName("."))
        XCTAssertNil(OriginalFileNaming.sanitizedOriginalName(".."))
        XCTAssertEqual(OriginalFileNaming.sanitizedOriginalName("a/b/IMG.HEIC"), "IMG.HEIC")
        XCTAssertEqual(OriginalFileNaming.sanitizedOriginalName("IMG_0001.HEIC"), "IMG_0001.HEIC")
    }
}
