import Foundation

// ============================================================================
// ExifToolService + Extensions
// ============================================================================
// Utility helpers that don't fit into read/write/rename but are used across
// multiple service files. Contains media type detection, URL splitting,
// and error output parsing.
//
// Contains:
//   - imageExtensions / videoExtensions    — shared sets of known extensions
//   - isSupportedFile(_:)                  — checks if a URL is a supported type
//   - mediaType(for:)                      — returns .image or .video for a URL
//   - isUnwritableVideo(_:)                — checks if ExifTool can write to a file
//   - splitByMediaType(_:)                 — splits URLs by image/QuickTime/other
//   - parseErrorSummary(_:)                — user-friendly error extraction
// ============================================================================

extension ExifToolService {

    // MARK: - Media Type Helpers

    /// Set of known image file extensions.
    /// Shared across the app — `FileListViewModel` uses this as the single
    /// source of truth for image extension detection.
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "gif", "bmp", "heic", "heif",
        "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "sr2",
        "webp", "ico", "psd"
    ]

    /// Set of known video file extensions.
    /// Shared across the app — `FileListViewModel` uses this as the single
    /// source of truth for video extension detection (see Design #3).
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm",
        "ts", "mts", "m2ts", "3gp", "3g2", "ogv", "mxf", "mpg", "mpeg"
    ]

    /// Returns true if the file extension is a supported image or video type.
    static func isSupportedFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return imageExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    /// Returns the MediaType for a given URL based on its extension.
    static func mediaType(for url: URL) -> MediaType {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) {
            return .video
        }
        return .image
    }

    /// Video extensions that use QuickTime containers (MP4/MOV/M4V).
    /// These support `-QuickTime:CreationDate` for date writes.
    private static let quickTimeExtensions: Set<String> = [
        "mp4", "mov", "m4v"
    ]

    /// HEIC/HEIF image extensions. These containers don't properly support
    /// the EXIF `ImageDescription` tag — descriptions must be written to the
    /// XMP namespace via `-XMP-dc:Description=` instead.
    private static let heicExtensions: Set<String> = [
        "heic", "heif"
    ]

    /// Returns true if the file extension is HEIC/HEIF.
    static func isHEIC(_ url: URL) -> Bool {
        heicExtensions.contains(url.pathExtension.lowercased())
    }

    /// Video extensions that ExifTool cannot write to (RIFF/AVI, MPEG container limitations).
    /// These files can be read but not modified by ExifTool.
    private static let unwritableVideoExtensions: Set<String> = [
        "avi", "mpg", "mpeg"
    ]

    /// Returns true if the file extension belongs to a video format that ExifTool
    /// cannot write to (e.g. AVI/RIFF containers).
    static func isUnwritableVideo(_ url: URL) -> Bool {
        unwritableVideoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Splits a list of URLs into image, QuickTime video, and other video buckets
    /// based on file extension.
    ///
    /// QuickTime videos (mp4, mov, m4v) use `-QuickTime:CreationDate` for date writes.
    /// Other videos (avi, mkv, wmv, etc.) use generic `-DateTimeOriginal` tags.
    ///
    /// - Parameter urls: The file URLs to split.
    /// - Returns: A tuple of (imageURLs, quickTimeURLs, otherVideoURLs).
    static func splitByMediaType(_ urls: [URL]) -> (images: [URL], quickTimeVideos: [URL], otherVideos: [URL]) {
        var images: [URL] = []
        var quickTimeVideos: [URL] = []
        var otherVideos: [URL] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if quickTimeExtensions.contains(ext) {
                quickTimeVideos.append(url)
            } else if videoExtensions.contains(ext) {
                otherVideos.append(url)
            } else {
                images.append(url)
            }
        }
        return (images, quickTimeVideos, otherVideos)
    }

    // MARK: - Error Parser

    /// Strips trailing timezone offset from a date string returned by ExifTool's
    /// FileModifyDate tag (e.g. `2026:06:19 10:59:26+01:00` → `2026:06:19 10:59:26`).
    ///
    /// FileModifyDate is a filesystem timestamp that includes the local timezone offset,
    /// unlike EXIF DateTimeOriginal / CreateDate which are timezone-naive.
    /// This helper removes the trailing `+HH:MM`, `-HH:MM`, or `Z` suffix.
    ///
    /// - Parameter dateString: The raw date string from ExifTool.
    /// - Returns: The date string with any timezone offset stripped, or the original
    ///   string if no offset pattern is found.
    static func stripTimezone(from dateString: String) -> String {
        // Matches trailing timezone offsets: +01:00, -05:30, Z (UTC)
        guard let regex = try? NSRegularExpression(pattern: "[+-]\\d{2}:\\d{2}$|Z$") else {
            return dateString
        }
        let range = NSRange(dateString.startIndex..<dateString.endIndex, in: dateString)
        return regex.stringByReplacingMatches(in: dateString, range: range, withTemplate: "")
    }

    /// Normalises a variety of date string shapes into the EXIF date format
    /// `YYYY:MM:DD HH:MM:SS` where possible. This is used by the Phase 1
    /// pre-write so values like `2011-03-16T11:55:13+00:00` or
    /// `2011-03-16 11:55:13+00:00` become `2011:03:16 11:55:13`.
    ///
    /// Behaviour:
    ///  - Strips any trailing timezone (`+00:00`, `Z`, etc.)
    ///  - Replaces a literal `T` between date/time with a space
    ///  - Converts `YYYY-MM-DD` → `YYYY:MM:DD`
    ///  - If the input already matches EXIF format, returns it unchanged
    ///
    /// NOTE: This intentionally does NOT strip fractional seconds (e.g.
    /// `17:08:43.93`). It is used on the read path (`readAllMetadata`,
    /// `readDateTimeOriginal`) and the sanitise pre-write, where silently
    /// altering the value would hide the ⚠️ invalid-date flag and bypass
    /// the user's review. Fractional-second stripping is handled by
    /// `normalizeToExifDateForFix` (used only by the "Fix DTO" action).
    static func normalizeToExifDate(_ dateString: String) -> String {
        let stripped = stripTimezone(from: dateString)

        // If already EXIF format, return as-is
        if let regex = try? NSRegularExpression(pattern: "^\\d{4}:\\d{2}:\\d{2} \\d{2}:\\d{2}:\\d{2}$") {
            let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
            if regex.firstMatch(in: stripped, range: range) != nil {
                return stripped
            }
        }

        // Normalize ISO-like strings: YYYY-MM-DDTHH:MM:SS or YYYY-MM-DD HH:MM:SS
        let s = stripped.replacingOccurrences(of: "T", with: " ")
        // Split into date and time (if present)
        let parts = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count > 0 else { return stripped }
        let datePart = parts[0].replacingOccurrences(of: "-", with: ":")
        let timePart = parts.count > 1 ? String(parts[1]) : ""

        if !timePart.isEmpty {
            return "\(datePart) \(timePart)"
        }
        return datePart
    }

    /// Normalises a date string for the "Fix DTO" action.
    ///
    /// Unlike `normalizeToExifDate` (used on the read path), this also strips
    /// fractional seconds so values like `2024:09:28 17:08:43.93` become
    /// `2024:09:28 17:08:43`. This is intentionally NOT applied on import —
    /// the user should see the raw value flagged with ⚠️ and review the fix
    /// in the diff before committing via Save.
    ///
    /// - Parameter dateString: The raw date string from the model.
    /// - Returns: The normalised EXIF-format date string.
    static func normalizeToExifDateForFix(_ dateString: String) -> String {
        let normalized = normalizeToExifDate(dateString)
        // Strip fractional seconds (e.g. "17:08:43.93" → "17:08:43").
        // iPhone/camera EXIF dates often include milliseconds after the seconds.
        if let fracRegex = try? NSRegularExpression(pattern: "\\.\\d+$") {
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            return fracRegex.stringByReplacingMatches(in: normalized, range: range, withTemplate: "")
        }
        return normalized
    }

    /// Attempts to extract a concise, user-friendly error summary from ExifTool's
    /// verbose output. ExifTool can produce hundreds of lines for batch operations,
    /// most of which are warnings or per-file progress that the user doesn't need.
    ///
    /// This function:
    ///   1. Looks for known error patterns and maps them to plain-English messages.
    ///   2. Filters out noise lines (repetitive "Warning" entries, per-file warnings).
    ///   3. Falls back to truncating the raw output if no known pattern matches.
    ///
    /// - Parameter output: The raw combined stdout/stderr from an ExifTool operation.
    /// - Returns: A user-friendly error message string.
    static func parseErrorSummary(_ output: String) -> String {
        guard !output.isEmpty else { return "Unknown error (no output from ExifTool)." }

        // Strip ANSI escape sequences that ExifTool may emit in some configurations
        let stripped = output.replacingOccurrences(
            of: #"\e\[[0-9;]*[a-zA-Z]"#,
            with: "",
            options: .regularExpression
        )

        // Known error patterns — ordered by specificity (most specific first)
        let patterns: [(pattern: String, summary: String)] = [
            // Access / permission errors
            ("Error: .* - Access denied", "Permission denied — ExifTool does not have read/write access to a file."),
            ("Error: .* - Permission denied", "Permission denied — ExifTool does not have read/write access to a file."),

            // File-level errors
            ("Error: File not found", "A file could not be found at the specified path. It may have been moved or deleted."),
            ("Error: .* - File not found", "A file could not be found at the specified path. It may have been moved or deleted."),

            // Format recognition failures
            ("Error: .* - Not a recognized", "One or more files are not in a recognized image or video format."),
            ("Error: .* - Unknown file type", "One or more files are in an unknown or unsupported format."),

            // No writable tags
            ("Warning: No writable tags set", "No metadata tags were available to write. The file format may not support the requested tags."),
            ("Nothing to do", "No changes were applied — all values were already as requested, or no writable tags were found."),

            // Tag-level errors
            ("Warning: .* - Tag not found", "A metadata tag expected for writing was not found in one or more files."),
            ("Warning: .* - Tag '.*' is not defined", "An unknown or unsupported metadata tag was specified."),

            // Date format errors
            ("Error: .* - Format error", "A date value could not be parsed. Ensure dates are in the format YYYY:MM:DD HH:MM:SS."),
            ("Error: .* - Invalid date", "A date value could not be parsed. Ensure dates are in the format YYYY:MM:DD HH:MM:SS."),

            // Container/write errors
            ("Error: .* - Container is not writable", "The file container format does not support writing metadata."),
            ("Error: .* - Not writable", "The file format does not support writing metadata."),
        ]

        // Check each pattern against the stripped output
        for (pattern, summary) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
                if regex.firstMatch(in: stripped, options: [], range: range) != nil {
                    return summary
                }
            }
        }

        // No known pattern matched. Attempt to produce a concise summary by:
        // 1. Collecting unique "Error:" and "Warning:" lines (not per-file duplicates)
        // 2. Truncating to a reasonable length
        var errorLines: String = ""
        var warningLines: String = ""

        let lines = stripped.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Error:") || trimmed.range(of: "^Error: ", options: .regularExpression) != nil {
                if !errorLines.contains(trimmed) {
                    errorLines += (errorLines.isEmpty ? "" : "; ") + trimmed
                }
            } else if trimmed.hasPrefix("Warning:") || trimmed.range(of: "^Warning: ", options: .regularExpression) != nil {
                if !warningLines.contains(trimmed) {
                    warningLines += (warningLines.isEmpty ? "" : "; ") + trimmed
                }
            }
        }

        var parts: [String] = []
        if !errorLines.isEmpty {
            let firstError = errorLines.components(separatedBy: "; ").first ?? errorLines
            let cleanError = firstError
                .replacingOccurrences(of: "^Error: ", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^Warning: ", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !cleanError.isEmpty {
                parts.append(cleanError)
            }
        }
        if !warningLines.isEmpty {
            let warningCount = stripped.components(separatedBy: "Warning:").count - 1
            parts.append("(\(warningCount) warning(s))")
        }

        if !parts.isEmpty {
            return parts.joined(separator: " — ")
        }

        // Last resort: truncate raw output
        let maxLen = 200
        if stripped.count > maxLen {
            let truncated = stripped.prefix(maxLen).trimmingCharacters(in: .whitespacesAndNewlines)
            return String(truncated) + "…"
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}