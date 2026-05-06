import Foundation
import AppKit

struct ImageFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let filename: String

    /// The last-saved DateTimeOriginal value. Used as the dirty baseline.
    private(set) var originalDateTimeOriginal: String

    /// The current (possibly edited) DateTimeOriginal value.
    /// Setting this automatically marks the file as dirty if the value differs.
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
    /// Resets the baseline to the current value and clears the dirty flag.
    mutating func markClean() {
        originalDateTimeOriginal = dateTimeOriginal
        isDirty = false
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ImageFile, rhs: ImageFile) -> Bool {
        lhs.id == rhs.id
    }
}