import Foundation
import PhotosCore
import MediaCache

/// Lightweight, read-only handoff of the LIVE library to the (separate-window) Metal Grid Lab. The main
/// UI publishes the loaded timeline sections + the shared `ThumbnailFeed` here; the lab consumes them to
/// render the REAL photo grid. If nothing has been published (e.g. the lab is opened before sign-in /
/// before the timeline loads), the lab falls back to synthetic data.
///
/// This does not alter any production behaviour — the lab only reads the same feed/sections the main
/// grid already uses.
@MainActor
public final class MetalGridLabBridge {
    public static let shared = MetalGridLabBridge()
    private init() {}

    private(set) var sections: [TimelineSection] = []
    private(set) var feed: ThumbnailFeed?
    /// Bumped on each publish so an open lab can detect that fresher data is available.
    public private(set) var revision = 0

    /// Called by the main UI whenever the live timeline + feed are available/updated.
    public func publish(sections: [TimelineSection], feed: ThumbnailFeed) {
        self.sections = sections
        self.feed = feed
        revision &+= 1
    }

    var hasRealData: Bool { feed != nil && !sections.isEmpty }

    /// A data source backed by the live library, or nil if none has been published yet.
    func makeRealDataSource() -> MetalGridDataSource? {
        guard let feed, !sections.isEmpty else { return nil }
        return RealMetalGridDataSource(sections: sections, feed: feed)
    }
}
