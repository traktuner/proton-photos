import CryptoKit
import Foundation

/// Proton-compatible photo filename correction - a faithful reimplementation of the behaviour of
/// Proton Drive iOS 1.61.0 (normalization in `PHAssetResource.getNormalizedFilename` + the
/// `PhotoNameCorrectionPolicy`), reproduced from its observed rules, not its code:
///
/// 1. Trim whitespace/newlines, keep the LAST 255 characters (suffix, so the extension survives).
/// 2. Delete (not replace) invalid characters: `/`, `\`, C0 controls, U+2000-200F, U+202E-202F.
/// 3. If the result is empty or fails validation (≤255 UTF-8 bytes, non-empty, not "."/"..",
///    no leading/trailing whitespace), fall back to a placeholder: UPPERCASE-hex SHA-1 of the
///    original name plus the original extension.
///
/// No lowercasing and no Unicode normalization - the corrected name feeds the name-hash HMAC
/// byte-for-byte, so any deviation here would silently break duplicate detection.
public enum ProtonPhotoNameCorrection {

    /// Everything Proton strips from a photo filename. Matches are DELETED.
    private static let invalidCharacters: NSRegularExpression = {
        // /, \, C0 controls, U+2000-200F (spaces, zero-width, direction marks), U+202E-202F.
        // The pattern is a constant; if it ever failed to compile every name would fall back to
        // its placeholder, which is safe but wrong - hence the precondition.
        guard let regex = try? NSRegularExpression(
            pattern: "/|\\\\|[\\x{0000}-\\x{001F}]|[\\x{2000}-\\x{200F}]|[\\x{202E}-\\x{202F}]"
        ) else { preconditionFailure("invalid-character pattern must compile") }
        return regex
    }()

    /// The Proton-corrected name for `originalFilename`. Deterministic and total: every input
    /// yields an uploadable name.
    public static func correctedName(for originalFilename: String) -> String {
        // Normalization: trim, keep the last 255 characters. An empty result gets Proton's
        // synthetic "emptyName" (extension preserved when the original had one).
        let trimmed = originalFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = String(trimmed.suffix(255))
        if base.isEmpty {
            let ext = (originalFilename as NSString).pathExtension
            base = ext.isEmpty ? "emptyName" : "emptyName.\(ext)"
        }

        let placeholder = placeholderName(for: base)
        let cleaned = removingInvalidCharacters(from: base)
        guard !cleaned.isEmpty, isValid(cleaned) else { return placeholder }
        return cleaned
    }

    /// Proton's fallback name: UPPERCASE-hex SHA-1 of the (pre-cleaning) name's UTF-8 bytes, with
    /// the original extension re-attached when there was one. Uppercase is load-bearing - this is
    /// the one place Proton formats SHA-1 as `%02X`.
    static func placeholderName(for name: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(name.utf8))
        let hex = digest.map { String(format: "%02X", $0) }.joined()
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? hex : "\(hex).\(ext)"
    }

    static func removingInvalidCharacters(from name: String) -> String {
        let range = NSRange(name.startIndex ..< name.endIndex, in: name)
        return invalidCharacters.stringByReplacingMatches(in: name, range: range, withTemplate: "")
    }

    /// Proton's `iosName` validation, minus the invalid-character check (guaranteed by cleaning).
    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255 else { return false }
        guard let first = name.unicodeScalars.first, let last = name.unicodeScalars.last else { return false }
        let whitespace = CharacterSet.whitespacesAndNewlines
        return !whitespace.contains(first) && !whitespace.contains(last)
    }
}
