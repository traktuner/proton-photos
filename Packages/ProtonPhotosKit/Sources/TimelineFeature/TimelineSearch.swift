import Foundation
import PhotosCore

struct TimelineSearchContext: Equatable, Sendable {
    var activeFilter: PhotoFilter?
    var favoriteUIDs: Set<PhotoUID>

    init(activeFilter: PhotoFilter? = nil, favoriteUIDs: Set<PhotoUID> = []) {
        self.activeFilter = activeFilter
        self.favoriteUIDs = favoriteUIDs
    }
}

enum TimelineSearch {
    static func filter(_ sections: [TimelineSection], query rawQuery: String,
                       context: TimelineSearchContext = TimelineSearchContext()) -> [TimelineSection] {
        let query = TimelineSearchQuery(rawQuery)
        guard !query.isEmpty else { return sections }

        return sections.compactMap { section in
            let items = section.items.filter { query.matches(item: $0, in: section, context: context) }
            guard !items.isEmpty else { return nil }
            return TimelineSection(id: section.id, date: section.date, title: section.title, items: items)
        }
    }
}

struct TimelineSearchQuery: Equatable, Sendable {
    private enum Term: Equatable, Sendable {
        case text(String)
        case smart(SmartKind)
    }

    private enum SmartKind: Equatable, Sendable {
        case favorites
        case videos
        case screenshots
        case selfies
        case raw

        var photoTag: PhotoTag {
            switch self {
            case .favorites: .favorites
            case .videos: .videos
            case .screenshots: .screenshots
            case .selfies: .selfies
            case .raw: .raw
            }
        }
    }

    private let terms: [Term]

    init(_ raw: String) {
        terms = Self.tokens(from: raw).map { token in
            if let smart = Self.smartKind(for: token) {
                .smart(smart)
            } else {
                .text(token)
            }
        }
    }

    var isEmpty: Bool { terms.isEmpty }

    func matches(item: PhotoItem, in section: TimelineSection, context: TimelineSearchContext) -> Bool {
        let haystack = Self.searchText(for: item, in: section)
        return terms.allSatisfy { term in
            switch term {
            case .text(let token):
                haystack.contains(token)
            case .smart(let smart):
                Self.matches(smart, item: item, section: section, haystack: haystack, context: context)
            }
        }
    }

    private static func matches(_ smart: SmartKind, item: PhotoItem, section: TimelineSection,
                                haystack: String, context: TimelineSearchContext) -> Bool {
        if item.tags.contains(smart.photoTag) { return true }
        if case .tag(let activeTag) = context.activeFilter, activeTag == smart.photoTag { return true }

        switch smart {
        case .favorites:
            return context.favoriteUIDs.contains(item.uid)
        case .videos:
            return item.isVideo
        case .raw:
            return isRawMediaType(item.mediaType)
        case .screenshots:
            return haystack.contains("screenshot") || haystack.contains("bildschirmfoto") || item.mediaType == "image/png"
        case .selfies:
            return haystack.contains("selfie")
        }
    }

    private static func smartKind(for token: String) -> SmartKind? {
        switch token {
        case "favorite", "favorites", "favourite", "favourites", "favorit", "favoriten", "heart", "herz":
            .favorites
        case "video", "videos", "film", "filme", "movie", "movies":
            .videos
        case "screenshot", "screenshots", "bildschirmfoto", "bildschirmfotos":
            .screenshots
        case "selfie", "selfies", "selbstportrait", "selbstportraits", "selbstportrat", "selbstportrats":
            .selfies
        case "raw", "dng":
            .raw
        default:
            nil
        }
    }

    private static func searchText(for item: PhotoItem, in section: TimelineSection) -> String {
        var fields: [String] = [
            item.uid.nodeID,
            item.uid.volumeID,
            item.mediaType,
            item.isVideo ? "video videos film filme movie movies" : "photo foto image bild",
            item.isLivePhoto ? "live photo livephoto" : "",
            section.id,
            section.title
        ]

        fields.append(contentsOf: dateFields(for: item.captureTime))
        if Calendar(identifier: .gregorian).isDate(item.captureTime, inSameDayAs: section.date) == false {
            fields.append(contentsOf: dateFields(for: section.date))
        }
        fields.append(contentsOf: item.tags.map(\.title))

        return normalize(fields.joined(separator: " "))
    }

    private static func dateFields(for date: Date) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return [] }

        let monthNamesEN = [
            "january", "february", "march", "april", "may", "june",
            "july", "august", "september", "october", "november", "december"
        ]
        let monthNamesDE = [
            "januar", "februar", "maerz", "april", "mai", "juni",
            "juli", "august", "september", "oktober", "november", "dezember"
        ]
        let monthIndex = max(0, min(11, month - 1))
        let twoMonth = String(format: "%02d", month)
        let twoDay = String(format: "%02d", day)

        return [
            "\(year)",
            "\(month)", twoMonth,
            "\(day)", twoDay,
            "\(year)-\(twoMonth)-\(twoDay)",
            "\(day).\(month).\(year)",
            "\(twoDay).\(twoMonth).\(year)",
            monthNamesEN[monthIndex],
            String(monthNamesEN[monthIndex].prefix(3)),
            monthNamesDE[monthIndex],
            String(monthNamesDE[monthIndex].prefix(3))
        ]
    }

    private static func isRawMediaType(_ mediaType: String) -> Bool {
        let value = normalize(mediaType)
        return value.contains("raw")
            || value.contains("dng")
            || value.contains("x-adobe-dng")
            || value.contains("x-canon-cr2")
            || value.contains("x-canon-cr3")
            || value.contains("x-nikon-nef")
            || value.contains("x-sony-arw")
            || value.contains("x-panasonic-rw2")
            || value.contains("x-fuji-raf")
    }

    private static func tokens(from raw: String) -> [String] {
        normalize(raw)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }
}
