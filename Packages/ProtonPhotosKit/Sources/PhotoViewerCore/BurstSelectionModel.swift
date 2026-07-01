import Foundation
import PhotosCore

/// Platform-neutral selection state for Proton burst / series photos.
///
/// The model owns only item identity, selection, navigation, and loading flags. Backend loading and native
/// filmstrip presentation stay in platform feature adapters.
public struct BurstSelectionModel: Equatable, Sendable {
    public private(set) var items: [PhotoItem]
    public private(set) var selectedIndex: Int?
    public private(set) var isLoading: Bool
    public private(set) var loadFailed: Bool

    public init(
        items: [PhotoItem] = [],
        selectedIndex: Int? = nil,
        isLoading: Bool = false,
        loadFailed: Bool = false
    ) {
        self.items = items
        self.selectedIndex = selectedIndex
        self.isLoading = isLoading
        self.loadFailed = loadFailed
    }

    public var hasFilmstrip: Bool { items.count > 1 }
    public var canMoveNext: Bool {
        hasFilmstrip && selectedIndex.map { $0 < items.count - 1 } == true
    }
    public var canMovePrevious: Bool {
        hasFilmstrip && selectedIndex.map { $0 > 0 } == true
    }

    public func current(fallback: PhotoItem) -> PhotoItem {
        guard let selectedIndex, items.indices.contains(selectedIndex) else { return fallback }
        return items[selectedIndex]
    }

    public func exportItems(current: PhotoItem) -> [PhotoItem] {
        hasFilmstrip ? items : [current]
    }

    public func gridReturnCandidates(current: PhotoItem, base: PhotoItem) -> [PhotoItem] {
        current.uid == base.uid ? [base] : [current, base]
    }

    public mutating func reset() {
        items = []
        selectedIndex = nil
        isLoading = false
        loadFailed = false
    }

    public mutating func seedKnownGroup(for item: PhotoItem, libraryItems: [PhotoItem]) {
        let memberIDs = item.burstMemberIDs
        guard memberIDs.count > 1 else { return }
        let itemByNodeID = Dictionary(uniqueKeysWithValues: libraryItems.map { ($0.uid.nodeID, $0) })
        let known = memberIDs.compactMap { itemByNodeID[$0] }
        guard known.count > 1 else { return }
        items = known
        selectedIndex = known.firstIndex(where: { $0.uid == item.uid }) ?? 0
        isLoading = false
        loadFailed = false
    }

    @discardableResult
    public mutating func beginLoadingIfCandidate(_ item: PhotoItem) -> Bool {
        guard item.isBurstCandidate else { return false }
        isLoading = true
        loadFailed = false
        return true
    }

    public mutating func applyLoadedGroup(_ group: [PhotoItem], containing item: PhotoItem) {
        isLoading = false
        loadFailed = false
        guard group.count > 1 else {
            if hasFilmstrip { return }
            items = []
            selectedIndex = nil
            return
        }
        items = group
        selectedIndex = group.firstIndex(where: { $0.uid == item.uid }) ?? 0
    }

    public mutating func failLoading() {
        isLoading = false
        loadFailed = true
        items = []
        selectedIndex = nil
    }

    public mutating func selectIndex(_ newIndex: Int) -> PhotoItem? {
        guard items.indices.contains(newIndex), selectedIndex != newIndex else { return nil }
        selectedIndex = newIndex
        return items[newIndex]
    }

    public mutating func selectNext() -> PhotoItem? {
        guard canMoveNext, let selectedIndex else { return nil }
        return selectIndex(selectedIndex + 1)
    }

    public mutating func selectPrevious() -> PhotoItem? {
        guard canMovePrevious, let selectedIndex else { return nil }
        return selectIndex(selectedIndex - 1)
    }
}
