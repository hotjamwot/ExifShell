import Foundation
import SwiftUI

// ============================================================================
// FileListViewModel+DTOFix
// ============================================================================
// Extension containing logic to fix files whose DateTimeOriginal uses an
// invalid (non-EXIF) date format that ExifShell cannot parse.
//
// Common case: XMP/ISO 8601 dates like `2010-03-27T01:40:19+00:00` or EXIF
// dates with a trailing timezone like `2011:03:16 11:55:13+00:00`.
//
// The fix is a **dirty-save** edit (NOT an immediate disk write), matching
// the app's core "edit → mark dirty → apply" philosophy:
//   1. Fix DTO normalises the in-memory `dateTimeOriginal` to EXIF format
//      (`YYYY:MM:DD HH:MM:SS`) via `ExifToolService.normalizeToExifDate`.
//   2. This marks the file dirty (orange text in table, diff in preview).
//   3. The user reviews the change and commits via the normal Save button.
//
// The save path (ExifToolService.writeDateTimeOriginal) additionally clears
// stray XMP/IPTC date tags so the corrected EXIF value isn't shadowed by the
// old ISO-8601 tag on the next read.
// ============================================================================

extension FileListViewModel {

    /// The number of selected files whose DateTimeOriginal format is invalid.
    var selectedDTOFixCount: Int { selectedFiles.filter(\.dateNeedsFix).count }

    /// Fixes the DateTimeOriginal format of all loaded files that need it.
    func fixDTOAll() {
        Task { await fixDTOAsync(only: nil) }
    }

    /// Fixes the DateTimeOriginal format of the currently selected files that need it.
    func fixDTOSelected() {
        Task { await fixDTOAsync(only: selectedFiles) }
    }

    /// Normalises the in-memory `dateTimeOriginal` value of files flagged by
    /// `dateNeedsFix` to proper EXIF format (`YYYY:MM:DD HH:MM:SS`).
    ///
    /// This is a **dirty-save** operation: nothing is written to disk here.
    /// Setting `dateTimeOriginal` marks the file dirty via `didSet`, and the
    /// user commits via the normal Save button. The save path clears stray
    /// XMP/IPTC date tags so the fix persists on disk.
    ///
    /// When `only` is provided, only those files are considered.
    func fixDTOAsync(only: [ImageFile]? = nil) async {
        let targets = (only ?? files).filter(\.dateNeedsFix)
        guard !targets.isEmpty else {
            statusMessage = "No files with invalid date formats to fix."
            return
        }

        guard !isFixingDTO else { return }

        isFixingDTO = true
        beginOperation(message: "Fixing date formats for \(targets.count) file(s)...", determinate: true)

        var fixedCount = 0
        var skippedCount = 0

        for (index, file) in targets.enumerated() {
            guard let cleaned = file.cleanedDateTimeOriginal, !cleaned.isEmpty else {
                skippedCount += 1
                continue
            }
            // Only mark dirty if the cleaned value actually differs.
            if cleaned != file.dateTimeOriginal {
                file.dateTimeOriginal = cleaned
                fixedCount += 1
            } else {
                skippedCount += 1
            }
            updateOperation(
                progress: Double(index + 1) / Double(targets.count),
                message: "Fixing date formats (\(index + 1)/\(targets.count))..."
            )
        }

        invalidateSort()

        let skipSuffix = skippedCount > 0 ? " (\(skippedCount) skipped — could not be normalised)" : ""
        endOperation(successMessage: "✅ Fixed date format on \(fixedCount) file(s).\(skipSuffix) Review the diff and press Save.")
        lastErrorDetail = nil

        isFixingDTO = false
    }

    /// Selects all files whose DateTimeOriginal format is invalid, for bulk fixing.
    func selectAllNeedsDTOFix() {
        let needsFix = files.filter(\.dateNeedsFix)
        selectedFiles = needsFix
        selectedFile = needsFix.first
        if needsFix.isEmpty {
            statusMessage = "No files with invalid date formats to select."
        } else {
            statusMessage = "Selected \(needsFix.count) file(s) with invalid date formats."
        }
    }
}