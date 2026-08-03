import Foundation
import AppKit
import AVFoundation
import Observation

// ============================================================================
// MediaType
// ============================================================================
/// Distinguishes between image and video files. Controls which ExifTool tags
/// are used for read/write operations and how thumbnails are generated.
// ============================================================================

enum MediaType: String, CaseIterable {
    case image
    case video
}

// ============================================================================
// ReadOnlyMetadata
// ============================================================================
/// Groups all read-only metadata fields that ExifTool populates during import.
/// These fields are display-only and never edited by the user.
///
/// Stored as a single struct on `ImageFile` to reduce property clutter and
/// simplify `applyMetadata()` assignment.
// ============================================================================

struct ReadOnlyMetadata {
    var createDate: String?
    var modifyDate: String?
    var imageDescription: String?
    var captionAbstract: String?
    /// The XMP Dublin Core description (e.g. `XMP-dc:Description`).
    /// HEIC/HEIF files store descriptions here rather than in EXIF ImageDescription.
    var xmpDescription: String?
    var subject: String?
    var keywords: String?
    var lastKeywordXMP: String?

    /// Duration string for video files (e.g. "00:05:30"). nil for images.
    var duration: String?

    /// Resolution string for video files (e.g. "1920x1080"). nil for images.
    var resolution: String?

    /// The filesystem modification date from ExifTool's File:FileModifyDate.
    /// Used as a last-resort fallback for files (e.g. MPG) with no embedded date tags.
    var fileModifyDate: String?

    /// Where the dateTimeOriginal value came from. nil when dateTimeOriginal is nil.
    /// Used to display a source indicator in the Preview Panel.
    var dateSource: ExifToolService.DateSource?

    /// Camera make (e.g. "Apple", "FUJIFILM", "Canon"). Read-only, populated from ExifTool.
    var cameraMake: String?

    /// Camera model (e.g. "iPhone 15 Pro", "X-T3", "DIGITAL IXUS v"). Read-only, populated from ExifTool.
    var cameraModel: String?

    /// The actual file type detected by ExifTool (e.g. "JPEG", "HEIC", "PNG").
    /// Read-only, populated from ExifTool's `-FileType` tag.
    /// Used to detect files whose suffix doesn't match their real content type.
    var actualFileType: String?

    /// The correct file extension for the actual content type (e.g. "jpg").
    /// Read-only, populated from ExifTool's `-FileTypeExtension` tag.
    /// Used to detect suffix mismatches and suggest corrections.
    var actualFileExtension: String?
}

// ============================================================================
// ImageFile
// ============================================================================
// @Observable class representing a single media file loaded into ExifShell.
// Works with both images (JPEG, PNG, HEIC, RAW, …) and videos (MP4, MOV, …).
//
// Each instance holds the file's URL, filename, thumbnail, and all metadata
// fields we care about. Two fields are user-editable (DateTimeOriginal,
// Description) with automatic dirty tracking — editing either one sets
// `isDirty = true` via `didSet`. The remaining fields are read-only display
// values populated from ExifTool during import, grouped into `readOnly`.
//
// Dirty state pattern:
//   - `dateTimeOriginal` didSet compares against `originalDateTimeOriginal`
//   - `description` didSet compares against `originalDescription`
//   - `markClean()` resets both baselines after a successful save
//
// Types referencing this:
//   - FileListViewModel (ExifShell/ViewModels/FileListViewModel.swift)
//   - FileTableView (ExifShell/Views/FileTableView.swift)
//   - PreviewPanel (ExifShell/Views/PreviewPanel.swift)
// ============================================================================

@Observable
final class ImageFile: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    var filename: String

    /// Whether this file is an image or video. Determines which ExifTool tags
    /// are used for read/write operations and how the thumbnail is generated.
    let mediaType: MediaType

    // MARK: - DateTimeOriginal (editable)

    /// The last-saved DateTimeOriginal value.
    var originalDateTimeOriginal: String

    /// The current (possibly edited) value.
    /// For videos this maps to QuickTime:CreationDate; for images EXIF:DateTimeOriginal.
    var dateTimeOriginal: String {
        didSet {
            if dateTimeOriginal != originalDateTimeOriginal {
                isDirty = true
            }
        }
    }

    /// Whether this video uses QuickTime metadata tags for dates.
    var usesQuickTimeCreationDate: Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "m4v"].contains(ext)
    }

    /// The display label for the editable date field based on media type.
    /// For images this is `DateTimeOriginal`; for QuickTime videos it is
    /// `QuickTime:CreationDate`.
    var editableDateTagLabel: String {
        mediaType == .video && usesQuickTimeCreationDate ? "QuickTime:CreationDate" : "DateTimeOriginal"
    }

    /// The display label for the source badge shown in the preview.
    var dateSourceLabel: String? {
        guard let source = readOnly.dateSource else { return nil }
        switch source {
        case .dateTimeOriginal:
            return mediaType == .video && usesQuickTimeCreationDate ? "QuickTime:CreationDate" : "DateTimeOriginal"
        case .createDate:
            return "CreateDate"
        case .fileModifyDate:
            return "File System"
        }
    }

    /// The display label for the description source badge shown in the preview.
    /// Indicates which tag the description value came from — XMP for HEIC/HEIF
    /// files (XMP-dc:Description), EXIF for ImageDescription, or IPTC for
    /// Caption-Abstract.
    var descriptionSourceLabel: String? {
        if let v = readOnly.xmpDescription, !v.isEmpty {
            return "XMP"
        }
        if let v = readOnly.imageDescription, !v.isEmpty {
            return "EXIF"
        }
        if let v = readOnly.captionAbstract, !v.isEmpty {
            return "IPTC"
        }
        return nil
    }

    // MARK: - Extension Mismatch Detection

    /// Returns true when the file's actual content type (detected by ExifTool)
    /// has a different extension than the filename suffix.
    ///
    /// Common case: HEIC files that are actually JPEGs — the filename ends in
    /// `.heic` but ExifTool reports `FileType: JPEG` / `FileTypeExtension: jpg`.
    var hasMismatchedExtension: Bool {
        guard let actualExt = readOnly.actualFileExtension?.lowercased(),
              !actualExt.isEmpty else { return false }
        let currentExt = url.pathExtension.lowercased()
        return currentExt != actualExt
    }

    /// The correct extension for the file's actual content type, lowercased.
    /// e.g. "jpg" for a JPEG file with a `.heic` suffix. nil when unknown.
    var correctExtension: String? {
        readOnly.actualFileExtension?.lowercased()
    }

    /// A human-readable description of the mismatch, e.g.
    /// "This file is actually JPEG (.jpg), not .heic".
    var mismatchDescription: String? {
        guard hasMismatchedExtension else { return nil }
        let actualType = readOnly.actualFileType ?? "unknown format"
        let correctExt = correctExtension ?? "?"
        let currentExt = url.pathExtension.lowercased()
        return "This file is actually \(actualType) (.\(correctExt)), not .\(currentExt)."
    }

    // MARK: - Description (editable, master field)

    /// The last-saved description value.
    var originalDescription: String

    /// The current (possibly edited) description value.
    /// When edited, this is the master value that will be written to all
    /// description-related tags (Description, ImageDescription, Caption-Abstract for images;
    /// Description for videos).
    var description: String {
        didSet {
            if description != originalDescription {
                isDirty = true
            }
        }
    }

    // MARK: - Read-Only Display Fields

    /// All read-only metadata populated by ExifTool during import.
    /// Assigning a new struct value replaces all fields atomically.
    var readOnly = ReadOnlyMetadata()

    // MARK: - Dirty State

    /// Whether the file has unsaved changes.
    private(set) var isDirty: Bool = false

    /// Thumbnail image for display in the preview panel.
    /// For images: generated from the file itself.
    /// For videos: generated from the first frame via AVAssetImageGenerator, or a video icon.
    let thumbnail: NSImage?

    init(
        url: URL,
        mediaType: MediaType,
        dateTimeOriginal: String = "",
        description: String = "",
        readOnly: ReadOnlyMetadata = ReadOnlyMetadata()
    ) {
        self.url = url
        self.filename = url.lastPathComponent
        self.mediaType = mediaType
        self.originalDateTimeOriginal = dateTimeOriginal
        self.dateTimeOriginal = dateTimeOriginal
        self.originalDescription = description
        self.description = description
        self.readOnly = readOnly
        self.thumbnail = Self.generateThumbnail(for: url, mediaType: mediaType)
    }

    /// Marks the file as clean after a successful write.
    func markClean() {
        originalDateTimeOriginal = dateTimeOriginal
        originalDescription = description
        isDirty = false
    }

    /// Updates the URL and filename after a file rename on disk.
    func updateURL(_ newURL: URL) {
        url = newURL
        filename = newURL.lastPathComponent
    }

    // MARK: - Thumbnail Generation

    /// Generates a thumbnail for the given file.
    /// - Images: loaded directly via NSImage.
    /// - Videos: extracted from the first frame via AVFoundation, falling back
    ///   to a system video icon if frame extraction fails.
    private static func generateThumbnail(for url: URL, mediaType: MediaType) -> NSImage? {
        switch mediaType {
        case .image:
            return NSImage(contentsOf: url)
        case .video:
            // Try to extract the first frame as a thumbnail
            let asset = AVAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let time = CMTime(seconds: 0, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return NSImage(cgImage: cgImage, size: NSSize(
                    width: cgImage.width,
                    height: cgImage.height
                ))
            }
            // Fallback: return nil — PreviewPanel will show a video icon
            return nil
        }
    }

    // MARK: - Sanitise Detection

    /// The expected format for DateTimeOriginal values: `yyyy:MM:dd HH:mm:ss`.
    /// XMP-style ISO 8601 dates (e.g. `2010-03-27T01:40:19+00:00`) need to be
    /// sanitised before ExifShell can use them properly.
    private static let exifDatePattern = #"^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$"#

    /// Returns true if the file's `dateTimeOriginal` contains a non-EXIF date
    /// format that would benefit from sanitisation. This typically catches
    /// XMP/ISO 8601 dates like `2010-03-27T01:40:19+00:00` that the app's
    /// date formatter cannot parse.
    var needsSanitise: Bool {
        guard !dateTimeOriginal.isEmpty else { return false }
        // Check if it already matches the expected EXIF format
        if let regex = try? NSRegularExpression(pattern: Self.exifDatePattern) {
            let range = NSRange(dateTimeOriginal.startIndex..<dateTimeOriginal.endIndex, in: dateTimeOriginal)
            if regex.firstMatch(in: dateTimeOriginal, range: range) != nil {
                return false
            }
        }
        return true
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ImageFile, rhs: ImageFile) -> Bool {
        lhs.id == rhs.id
    }
}