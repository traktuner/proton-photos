import Foundation

/// Minimal STREAMING ZIP writer, STORE method (no compression — photos/videos are already compressed, so
/// recompressing wastes CPU for ~0 gain). Each entry's bytes are written straight to the destination file via a
/// `FileHandle`:
///   • E2EE: decrypted originals only ever land at the user's chosen `.zip` — never staged in an app temp dir.
///   • Scale: the whole archive is never held in RAM, and ZIP64 is emitted per-entry / per-archive whenever a
///     size or offset crosses the 4 GB zip32 limit, so an export of any size (multi-TB) is a valid archive.
///
/// Each `addFile` is given the file's full decrypted bytes (so CRC-32 + size are known up front — no streaming
/// data-descriptor needed). Little-endian throughout, per the PKZIP APPNOTE.
public final class ZipStreamWriter {
    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    private struct Entry { let name: [UInt8]; let crc: UInt32; let size: UInt64; let localOffset: UInt64 }

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        let (t, d) = Self.dosDateTime(Date())
        self.dosTime = t
        self.dosDate = d
    }

    /// Appends one file (`data` = its full decrypted bytes).
    public func addFile(name: String, data: Data) throws {
        let nameBytes = Array(name.utf8)
        let crc = Self.crc32(data)
        let size = UInt64(data.count)
        let localOffset = offset
        let sizeOver = size >= 0xFFFF_FFFF

        var h = [UInt8]()
        appendU32(&h, 0x0403_4b50)                              // local file header signature
        appendU16(&h, sizeOver ? 45 : 20)                       // version needed (ZIP64 = 45)
        appendU16(&h, 0x0800)                                   // general-purpose flag: UTF-8 filename
        appendU16(&h, 0)                                        // method: store
        appendU16(&h, dosTime); appendU16(&h, dosDate)
        appendU32(&h, crc)
        appendU32(&h, sizeOver ? 0xFFFF_FFFF : UInt32(size))    // compressed size
        appendU32(&h, sizeOver ? 0xFFFF_FFFF : UInt32(size))    // uncompressed size
        appendU16(&h, UInt16(nameBytes.count))
        let extra: [UInt8] = sizeOver ? zip64Extra([size, size]) : []   // local: uncompressed, compressed
        appendU16(&h, UInt16(extra.count))
        h.append(contentsOf: nameBytes)
        h.append(contentsOf: extra)
        try write(h)
        try write(data)

        entries.append(Entry(name: nameBytes, crc: crc, size: size, localOffset: localOffset))
    }

    /// Writes the central directory + (ZIP64) end records and closes the file.
    public func finish() throws {
        let cdStart = offset
        for e in entries {
            let sizeOver = e.size >= 0xFFFF_FFFF
            let offOver = e.localOffset >= 0xFFFF_FFFF
            var c = [UInt8]()
            appendU32(&c, 0x0201_4b50)                                  // central dir header signature
            appendU16(&c, 45)                                           // version made by
            appendU16(&c, (sizeOver || offOver) ? 45 : 20)              // version needed
            appendU16(&c, 0x0800)                                       // UTF-8 filename
            appendU16(&c, 0)                                            // method: store
            appendU16(&c, dosTime); appendU16(&c, dosDate)
            appendU32(&c, e.crc)
            appendU32(&c, sizeOver ? 0xFFFF_FFFF : UInt32(e.size))      // compressed
            appendU32(&c, sizeOver ? 0xFFFF_FFFF : UInt32(e.size))      // uncompressed
            appendU16(&c, UInt16(e.name.count))
            // ZIP64 extra carries ONLY the fields that were set to 0xFFFFFFFF, in fixed order:
            // uncompressed, compressed, local-header-offset.
            var zfields: [UInt64] = []
            if sizeOver { zfields.append(e.size); zfields.append(e.size) }
            if offOver { zfields.append(e.localOffset) }
            let extra: [UInt8] = zfields.isEmpty ? [] : zip64Extra(zfields)
            appendU16(&c, UInt16(extra.count))
            appendU16(&c, 0)                                            // file comment length
            appendU16(&c, 0)                                            // disk number start
            appendU16(&c, 0)                                            // internal attributes
            appendU32(&c, 0)                                            // external attributes
            appendU32(&c, offOver ? 0xFFFF_FFFF : UInt32(e.localOffset)) // local header offset
            c.append(contentsOf: e.name)
            c.append(contentsOf: extra)
            try write(c)
        }
        let cdSize = offset - cdStart
        let count = UInt64(entries.count)
        let needsZip64 = count >= 0xFFFF || cdSize >= 0xFFFF_FFFF || cdStart >= 0xFFFF_FFFF
            || entries.contains { $0.size >= 0xFFFF_FFFF || $0.localOffset >= 0xFFFF_FFFF }

        if needsZip64 {
            let eocd64Offset = offset
            var z = [UInt8]()
            appendU32(&z, 0x0606_4b50)          // ZIP64 end of central directory signature
            appendU64(&z, 44)                   // size of remaining EOCD64 record
            appendU16(&z, 45); appendU16(&z, 45)
            appendU32(&z, 0); appendU32(&z, 0)  // this disk / disk with CD start
            appendU64(&z, count); appendU64(&z, count)
            appendU64(&z, cdSize); appendU64(&z, cdStart)
            try write(z)
            var loc = [UInt8]()
            appendU32(&loc, 0x0706_4b50)        // ZIP64 EOCD locator signature
            appendU32(&loc, 0)                  // disk with EOCD64
            appendU64(&loc, eocd64Offset)
            appendU32(&loc, 1)                  // total number of disks
            try write(loc)
        }

        var e = [UInt8]()
        appendU32(&e, 0x0605_4b50)              // end of central directory signature
        appendU16(&e, 0); appendU16(&e, 0)      // this disk / disk with CD
        appendU16(&e, count >= 0xFFFF ? 0xFFFF : UInt16(count))
        appendU16(&e, count >= 0xFFFF ? 0xFFFF : UInt16(count))
        appendU32(&e, cdSize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(cdSize))
        appendU32(&e, cdStart >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(cdStart))
        appendU16(&e, 0)                        // comment length
        try write(e)

        try handle.close()
    }

    /// Closes the file WITHOUT writing the central directory — for an aborted export (the caller deletes the
    /// partial file). Leaves no valid archive behind.
    public func abort() { try? handle.close() }

    // MARK: - Byte helpers

    private func write(_ bytes: [UInt8]) throws { try write(Data(bytes)) }
    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    /// A ZIP64 extended-information extra field (tag 0x0001) carrying the given 8-byte values in order.
    private func zip64Extra(_ values: [UInt64]) -> [UInt8] {
        var x = [UInt8]()
        appendU16(&x, 0x0001)
        appendU16(&x, UInt16(values.count * 8))
        for v in values { appendU64(&x, v) }
        return x
    }

    private func appendU16(_ a: inout [UInt8], _ v: UInt16) {
        a.append(UInt8(v & 0xFF)); a.append(UInt8((v >> 8) & 0xFF))
    }
    private func appendU32(_ a: inout [UInt8], _ v: UInt32) {
        for i in 0..<4 { a.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) }
    }
    private func appendU64(_ a: inout [UInt8], _ v: UInt64) {
        for i in 0..<8 { a.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) }
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980)
        let dosDate = UInt16(((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        let dosTime = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        return (dosTime, dosDate)
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
    /// Standard IEEE CRC-32 (as ZIP requires).
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
