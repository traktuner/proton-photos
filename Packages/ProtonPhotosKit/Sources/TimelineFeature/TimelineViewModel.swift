import Foundation
import PhotosCore
import MediaCache

@MainActor
@Observable
public final class TimelineViewModel {
    public enum State {
        case loading
        case empty
        case loaded([TimelineSection])
        case failed(String)
    }

    public private(set) var state: State = .loading

    private let repository: PhotosRepository
    private let thumbnails: ThumbnailProvider
    private let cache: ThumbnailCache

    public init(repository: PhotosRepository, thumbnails: ThumbnailProvider, cache: ThumbnailCache) {
        self.repository = repository
        self.thumbnails = thumbnails
        self.cache = cache
    }

    public func load() async {
        state = .loading
        do {
            let sections = try await repository.loadTimeline()
            state = sections.isEmpty ? .empty : .loaded(sections)
        } catch is CancellationError {
            // ignore
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Returns thumbnail bytes, hitting the cache first and falling back to the SDK.
    public func thumbnailData(for uid: PhotoUID) async -> Data? {
        if let cached = await cache.data(for: uid) { return cached }
        do {
            let data = try await thumbnails.thumbnail(for: uid)
            await cache.store(data, for: uid)
            return data
        } catch {
            return nil
        }
    }
}
