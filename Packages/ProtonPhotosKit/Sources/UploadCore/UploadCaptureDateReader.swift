import AVFoundation
import Foundation
import ImageIO

/// Reads the best available media capture date for uploads.
///
/// Source order is intentional: embedded media metadata is authoritative; file-system dates are
/// only a fallback for files with no readable capture metadata.
public enum UploadCaptureDateReader {
    public static func captureDate(for url: URL, fallback: Date) async -> Date {
        if let imageDate = imageCaptureDate(for: url) {
            return imageDate
        }
        if let videoDate = await videoCaptureDate(for: url) {
            return videoDate
        }
        return fallback
    }

    public static func fileSystemFallback(from attributes: [FileAttributeKey: Any], default defaultDate: Date) -> Date {
        (attributes[.creationDate] as? Date)
            ?? (attributes[.modificationDate] as? Date)
            ?? defaultDate
    }

    private static func imageCaptureDate(for url: URL) -> Date? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [String: Any] else {
            return nil
        }

        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            for (dateKey, offsetKey) in [
                (kCGImagePropertyExifDateTimeOriginal as String, "OffsetTimeOriginal"),
                (kCGImagePropertyExifDateTimeDigitized as String, "OffsetTimeDigitized"),
            ] {
                guard let raw = exif[dateKey] as? String else { continue }
                if let parsed = parseExifDate(raw, offset: exif[offsetKey] as? String) {
                    return parsed
                }
            }
        }

        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let raw = tiff[kCGImagePropertyTIFFDateTime as String] as? String {
            return parseExifDate(raw, offset: nil)
        }
        return nil
    }

    private static func videoCaptureDate(for url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.metadata)
            let commonMetadata = try await asset.load(.commonMetadata)
            for item in metadata + commonMetadata {
                guard item.identifier == .quickTimeMetadataCreationDate
                    || item.identifier == .commonIdentifierCreationDate
                    || item.commonKey == .commonKeyCreationDate else {
                    continue
                }
                if let raw = try await item.load(.stringValue),
                   let parsed = parseISODate(raw) ?? parseExifDate(raw, offset: nil) {
                    return parsed
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func parseExifDate(_ raw: String, offset: String?) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let offset, !offset.isEmpty {
            let combined = trimmed + offset.trimmingCharacters(in: .whitespacesAndNewlines)
            for format in ["yyyy:MM:dd HH:mm:ssXXXXX", "yyyy:MM:dd HH:mm:ssXX"] {
                if let date = dateFormatter(format: format, timeZone: nil).date(from: combined) {
                    return date
                }
            }
        }

        return dateFormatter(format: "yyyy:MM:dd HH:mm:ss", timeZone: .current).date(from: trimmed)
            ?? parseISODate(trimmed)
    }

    private static func parseISODate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func dateFormatter(format: String, timeZone: TimeZone?) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        if let timeZone {
            formatter.timeZone = timeZone
        }
        return formatter
    }
}
