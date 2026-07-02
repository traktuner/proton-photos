import Foundation

/// Derives the Apple-Photos-style two-line center title for the viewer top bar.
///
/// Priority (per the UX spec):
///  - Line 1: POI / location name if available, else capture date/time, else filename, else a
///    localized "Photo"/"Foto" fallback.
///  - Line 2: when a location is on line 1 → "date/time · position"; otherwise → just the position
///    ("4.454 von 35.666"). When there is no date at all, line 1 falls back to filename/the localized
///    "Photo"/"Foto" fallback and line 2 is the position.
///
/// Pure value type so it is unit-testable without any view layer.
public struct ViewerTitle: Equatable, Sendable {
    public let line1: String
    public let line2: String

    public init(line1: String, line2: String) {
        self.line1 = line1
        self.line2 = line2
    }
}

public enum ViewerTitleFormatter {
    /// - Parameters:
    ///   - captureDate: capture date/time, if known.
    ///   - index: zero-based index of the current item in the library.
    ///   - total: total item count.
    ///   - locationName: reverse-geocoded POI/location name, if already available (never blocks on it).
    ///   - filename: original filename, used only as a date-less fallback.
    ///   - locale: user/app locale - drives date wording ("um") and the "von"/"of" connector.
    public static func make(
        captureDate: Date?,
        index: Int,
        total: Int,
        locationName: String? = nil,
        filename: String? = nil,
        locale: Locale = .current
    ) -> ViewerTitle {
        let position = positionString(index: index, total: total, locale: locale)
        let dateTime = captureDate.map { dateTimeString($0, locale: locale) }

        if let locationName, !locationName.isEmpty {
            let second = dateTime.map { "\($0) · \(position)" } ?? position
            return ViewerTitle(line1: locationName, line2: second)
        }
        if let dateTime {
            return ViewerTitle(line1: dateTime, line2: position)
        }
        if let filename, !filename.isEmpty {
            return ViewerTitle(line1: filename, line2: position)
        }
        // Localized via the same `locale` parameter the rest of this formatter honors (kept locale-driven
        // rather than bundle-driven so the formatter stays deterministically unit-testable per locale).
        return ViewerTitle(line1: isGerman(locale) ? "Foto" : "Photo", line2: position)
    }

    /// "17. Juni 2026 um 16:53:58" for German locales, otherwise the locale's natural date+time string.
    static func dateTimeString(_ date: Date, locale: Locale) -> String {
        let datePart = date.formatted(.dateTime.day().month(.wide).year().locale(locale))
        let timePart = date.formatted(.dateTime.hour().minute().second().locale(locale))
        if isGerman(locale) {
            return "\(datePart) um \(timePart)"
        }
        return "\(datePart) · \(timePart)"
    }

    /// "4.454 von 35.666" (German) / "4,454 of 35,666" (English). Index is presented 1-based.
    static func positionString(index: Int, total: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        let current = formatter.string(from: NSNumber(value: index + 1)) ?? "\(index + 1)"
        let count = formatter.string(from: NSNumber(value: total)) ?? "\(total)"
        let connector = isGerman(locale) ? "von" : "of"
        return "\(current) \(connector) \(count)"
    }

    private static func isGerman(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier == "de"
    }
}
