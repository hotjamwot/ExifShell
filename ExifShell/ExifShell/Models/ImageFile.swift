import Foundation
import AppKit
import Observation

@Observable
final class ImageFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let filename: String

    /// The last-saved DateTimeOriginal value.
    private(set) var originalDateTimeOriginal: String

    /// The current (possibly edited) value.
    var dateTimeOriginal: String {
        didSet {
            if dateTimeOriginal != originalDateTimeOriginal {
                isDirty = true
            }
        }
    }

    /// Whether the file has unsaved changes.
    private(set) var isDirty: Bool = false

    let thumbnail: NSImage?

    init(url: URL, dateTimeOriginal: String = "") {
        self.url = url
        self.filename = url.lastPathComponent
        self.originalDateTimeOriginal = dateTimeOriginal
        self.dateTimeOriginal = dateTimeOriginal
        self.thumbnail = NSImage(contentsOf: url)
    }

    /// Marks the file as clean after a successful write.
    func markClean() {
        originalDateTimeOriginal = dateTimeOriginal
        isDirty = false
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ImageFile, rhs: ImageFile) -> Bool {
        lhs.id == rhs.id
    }
}