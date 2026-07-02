import Foundation
import CryptoKit
import PhotosCore

/// On-disk cache of a video's *encrypted* blocks, keyed by `uid` + block index, so reopening a video
/// (or seeking back over already-watched regions) reuses bytes instead of re-downloading. We persist
/// the ENCRYPTED block — not the decrypted plaintext — so no clear video content lands on disk; the
/// decrypt happens in memory on read (mirroring Proton Drive Web, which keeps decrypted bytes only in
/// the page's memory and never persists them). A size budget with LRU eviction keeps disk bounded.
///
/// Thread-safe (NSLock); the resource loader hits this from its serving queue + detached tasks.
final class VideoByteRangeCache: @unchecked Sendable {
    static let shared = VideoByteRangeCache()

    private let root: URL
    private let lock = NSLock()
    private let budgetBytes: Int
    private let fm = FileManager.default
    private var sizeOnDisk: Int?

    init(budgetBytes: Int = 512 * 1024 * 1024) {
        self.budgetBytes = budgetBytes
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.root = caches.appendingPathComponent("ProtonPhotos/video-blocks", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Stable, filesystem-safe directory name for a uid (SHA-256 hex of the volume~node pair).
    private func dir(for uid: PhotoUID) -> URL {
        let digest = SHA256.hash(data: Data("\(uid.volumeID)~\(uid.nodeID)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(hex, isDirectory: true)
    }

    private func file(for uid: PhotoUID, block: Int) -> URL {
        dir(for: uid).appendingPathComponent("\(block).blk")
    }

    /// Encrypted bytes for a block, or `nil` on a miss. Touches the file's mtime so it survives LRU.
    func encryptedBlock(uid: PhotoUID, block: Int) -> Data? {
        let url = file(for: uid, block: block)
        return lock.withLock {
            guard let data = try? Data(contentsOf: url) else { return nil }
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.deletingLastPathComponent().path)
            return data
        }
    }

    /// Persists a block's encrypted bytes, then enforces the budget. Best-effort: a write failure is
    /// non-fatal (we just re-fetch next time).
    func store(uid: PhotoUID, block: Int, encrypted: Data) {
        let d = dir(for: uid)
        lock.withLock {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            let url = d.appendingPathComponent("\(block).blk")
            let previousTotal = sizeOnDiskLocked()
            let oldSize = fileSize(url)
            do {
                try encrypted.write(to: url, options: .atomic)
                sizeOnDisk = max(0, previousTotal - oldSize + encrypted.count)
            } catch {
                return
            }
            enforceBudgetLocked(keep: d.lastPathComponent)
        }
    }

    /// Clears the whole video block cache (wired to the existing "delete cache" Settings action).
    func clearAll() {
        lock.withLock {
            try? fm.removeItem(at: root)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            sizeOnDisk = 0
        }
        PhotoDiagnostics.shared.emit("VideoCache", ["action": "clearAll", "sizeOnDisk": "0"])
    }

    // MARK: - Budget

    /// Evicts least-recently-used uid directories until under budget. Coarse-grained (per video, by
    /// the directory's newest mtime) — cheap and good enough; a single video's blocks live or die
    /// together, which keeps a partially-played file fully reusable.
    private func enforceBudgetLocked(keep: String) {
        var total = sizeOnDiskLocked()
        guard total > budgetBytes else { return }
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []
        let sorted = dirs
            .filter { $0.lastPathComponent != keep }   // never evict the video being played
            .sorted { mtime($0) < mtime($1) }          // oldest first
        for d in sorted where total > budgetBytes {
            let size = directorySize(d)
            try? fm.removeItem(at: d)
            total = max(0, total - size)
            sizeOnDisk = total
            PhotoDiagnostics.shared.emit("VideoCache", [
                "action": "evict", "dir": d.lastPathComponent, "freed": "\(size)", "sizeOnDisk": "\(total)",
            ])
        }
    }

    private func sizeOnDiskLocked() -> Int {
        if let sizeOnDisk { return sizeOnDisk }
        let measured = directorySize(root)
        sizeOnDisk = measured
        return measured
    }

    private func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func directorySize(_ url: URL) -> Int {
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let f as URL in e {
            total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
