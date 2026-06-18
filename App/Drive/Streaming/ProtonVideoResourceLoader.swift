import Foundation
import AVFoundation

/// Serves a Proton video to AVFoundation via range requests: maps each requested byte range to the
/// blocks that cover it, fetches + decrypts only those blocks, and responds with the exact window.
/// A small LRU cache of decrypted blocks keeps sequential playback from re-fetching. AVFoundation
/// calls the delegate on the queue we hand to `setDelegate(_:queue:)`; the per-request work runs in
/// a detached Task so the queue never blocks on the network.
final class ProtonVideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let prepared: PreparedVideo
    private let source: PhotoVideoStreamSource
    private let crypto: DriveCrypto
    private let decryptedCache = NSCache<NSNumber, NSData>()

    init(prepared: PreparedVideo, source: PhotoVideoStreamSource, crypto: DriveCrypto) {
        self.prepared = prepared
        self.source = source
        self.crypto = crypto
        super.init()
        decryptedCache.countLimit = 12   // ~ up to 12 decrypted blocks held for sequential reads
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = prepared.contentTypeUTI
            info.isByteRangeAccessSupported = true
            info.contentLength = Int64(prepared.totalSize)
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.serve(dataRequest)
                loadingRequest.finishLoading()
            } catch {
                loadingRequest.finishLoading(with: error as NSError)
            }
        }
        return true
    }

    private func serve(_ dataRequest: AVAssetResourceLoadingDataRequest) async throws {
        let total = prepared.totalSize
        var pos = Int(dataRequest.currentOffset)
        let reqEnd = min(Int(dataRequest.requestedOffset) + dataRequest.requestedLength, total)

        for block in prepared.blocks {
            guard block.clearSize > 0 else { continue }
            let bStart = block.clearOffset
            let bEnd = block.clearOffset + block.clearSize
            if bEnd <= pos { continue }       // entirely before the window
            if bStart >= reqEnd { break }     // past the window — blocks are ordered

            let clear = try await decryptedBlock(block)
            let from = max(pos, bStart) - bStart
            let to = min(reqEnd, bEnd) - bStart
            if from < to, from < clear.count {
                let slice = clear.subdata(in: from..<min(to, clear.count))
                dataRequest.respond(with: slice)
                pos += slice.count
            }
            if pos >= reqEnd { break }
        }
    }

    private func decryptedBlock(_ block: VideoBlock) async throws -> Data {
        let key = NSNumber(value: block.clearOffset)
        if let cached = decryptedCache.object(forKey: key) { return cached as Data }
        let encrypted = try await source.encryptedBlockData(block)
        let clear = try crypto.decryptBlock(encrypted, sessionKey: prepared.sessionKey)
        decryptedCache.setObject(clear as NSData, forKey: key)
        return clear
    }
}
