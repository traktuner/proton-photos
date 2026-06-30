import Foundation

/// Proton's built-in photo tags (server-side smart filters). Raw values are the API's PhotoTag enum.
public enum PhotoTag: Int, Sendable, CaseIterable, Codable {
    case favorites = 0
    case screenshots = 1
    case videos = 2
    case livePhotos = 3
    case motionPhotos = 4
    case selfies = 5
    case portraits = 6
    case bursts = 7
    case panoramas = 8
    case raw = 9

    public var title: String {
        switch self {
        case .favorites: L10n.string("tag.favorites")
        case .screenshots: L10n.string("tag.screenshots")
        case .videos: L10n.string("tag.videos")
        case .livePhotos: L10n.string("tag.live_photos")
        case .motionPhotos: L10n.string("tag.motion")
        case .selfies: L10n.string("tag.selfies")
        case .portraits: L10n.string("tag.portraits")
        case .bursts: L10n.string("tag.bursts")
        case .panoramas: L10n.string("tag.panoramas")
        case .raw: L10n.string("tag.raw")
        }
    }

    public var systemImage: String {
        switch self {
        case .favorites: "heart"
        case .screenshots: "camera.viewfinder"
        case .videos: "video"
        case .livePhotos: "livephoto"
        case .motionPhotos: "livephoto.play"   // was "circle.motionlines" — not a real SF Symbol, so it rendered blank
        case .selfies: "person.crop.square"
        case .portraits: "person.fill"
        case .bursts: "square.stack.3d.down.right"
        case .panoramas: "pano"
        case .raw: "r.square"
        }
    }
}

/// What the grid is currently showing — the whole library, a smart-filter tag, an album, or trash.
public enum PhotoFilter: Equatable, Hashable, Sendable {
    case all
    case tag(PhotoTag)
    case album(id: String, title: String)
    case trash
    /// The whole-library Map view — no timeline load; the detail shows the map instead.
    case map

    /// Whether selecting this route should load timeline sections into the Metal grid.
    public var hasTimeline: Bool {
        switch self {
        case .map: false
        default: true
        }
    }
}

/// Read + write of the favorites tag. `favoriteUIDs` reads the server's favorites (so photos
/// favorited on iOS show up); `setFavorite` writes the toggle back.
public protocol FavoritesProvider: Sendable {
    func favoriteUIDs() async throws -> Set<PhotoUID>
    func setFavorite(_ uid: PhotoUID, _ favorite: Bool) async throws
}

/// Move photos to / restore from the Proton trash.
public protocol TrashProvider: Sendable {
    func trash(_ uids: [PhotoUID]) async throws
    func restore(_ uids: [PhotoUID]) async throws
}

/// A Proton photo album (user-created collection).
public struct PhotoAlbum: Identifiable, Sendable, Equatable {
    public let id: String          // album link id
    public let title: String
    public let photoCount: Int
    public let coverLinkID: String?

    public init(id: String, title: String, photoCount: Int, coverLinkID: String?) {
        self.id = id
        self.title = title
        self.photoCount = photoCount
        self.coverLinkID = coverLinkID
    }
}

/// Optional backend capability: list albums and load a filtered/album timeline. `.all` falls back to
/// the fast SDK-cached timeline; tag/album views use the direct REST endpoints.
public protocol PhotoLibraryProvider: Sendable {
    func albums() async throws -> [PhotoAlbum]
    func timeline(filter: PhotoFilter) async throws -> [TimelineSection]
}
