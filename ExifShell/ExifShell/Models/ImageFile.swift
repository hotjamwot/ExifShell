import Foundation
import AppKit
import Observation

@Observable
final class ImageFile: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    var filename: String

    // MARK: - DateTimeOriginal (editable)

    /// The last-saved DateTimeOriginal value.
    var originalDateTimeOriginal: String

    /// The current (possibly edited) value.
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
    /// description-related EXIF tags (ImageDescription, Caption-Abstract, Description).
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

    // MARK: - Dirty State

    /// Whether the file has unsaved changes.
    private(set) var isDirty: Bool = false

    let thumbnail: NSImage?

    init(
        url: URL,
        dateTimeOriginal: String = "",
        description: String = "",
        createDate: String? = nil,
        modifyDate: String? = nil,
        imageDescription: String? = nil,
        captionAbstract: String? = nil,
        subject: String? = nil,
        keywords: String? = nil,
        lastKeywordXMP: String? = nil
    ) {
        self.url = url
        self.filename = url.lastPathComponent
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
        self.thumbnail = NSImage(contentsOf: url)
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
        // Re-check dirty status since we may need to re-read metadata
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ImageFile, rhs: ImageFile) -> Bool {
        lhs.id == rhs.id
    }
}