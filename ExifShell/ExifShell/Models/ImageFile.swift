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
// ImageFile
// ============================================================================
// @Observable class representing a single media file loaded into ExifShell.
// Works with both images (JPEG, PNG, HEIC, RAW, …) and videos (MP4, MOV, …).
//
// Each instance holds the file's URL, filename, thumbnail, and all metadata
// fields we care about. Two fields are user-editable (DateTimeOriginal,
// Description) with automatic dirty tracking — editing either one sets
// `isDirty = true` via `didSet`. The remaining fields are read-only display
// values populated from ExifTool during import.
//
// Dirty state pattern:
//   - `dateTimeOriginal` didSet compares against `originalDateTimeOriginal`
//   - `description` didSet compares against `originalDescription`
//   - `markClean()` resets both baselines after a successful save
//
// Types referencing this:
//   - FileListViewModel owns the array of ImageFile instances
//   - FileTableView binds to individual fields via `@Bindable`
//   - PreviewPanel reads fields for diff display and read-only metadata
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

    var createDate: String?
    var modifyDate: String?
    var imageDescription: String?
    var captionAbstract: String?
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
        createDate: String? = nil,
        modifyDate: String? = nil,
        imageDescription: String? = nil,
        captionAbstract: String? = nil,
        subject: String? = nil,
        keywords: String? = nil,
        lastKeywordXMP: String? = nil,
        duration: String? = nil,
        resolution: String? = nil,
        fileModifyDate: String? = nil,
        dateSource: ExifToolService.DateSource? = nil
    ) {
        self.url = url
        self.filename = url.lastPathComponent
        self.mediaType = mediaType
        self.originalDateTimeOriginal = dateTimeOriginal
        self.dateTimeOriginal = dateTimeOriginal
        self.originalDescription = description
        self.description = description
        self.createDate = createDate
        self.modifyDate = modifyDate
        self.imageDescription = imageDescription
        self.captionAbstract = captionAbstract
        self.subject = subject
        self.keywords = keywords
        self.lastKeywordXMP = lastKeywordXMP
        self.duration = duration
        self.resolution = resolution
        self.fileModifyDate = fileModifyDate
        self.dateSource = dateSource
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