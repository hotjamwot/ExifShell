import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
class FileListViewModel {

    var files: [ImageFile] = []
    var selectedFile: ImageFile? {
        didSet { clearFeedback() }
    }
    var selectedFiles: [ImageFile] = []
    var isLoading = false
    var statusMessage: String?
    var lastSaveFeedback: SaveFeedback?
    var lastDescriptionSaveFeedback: SaveFeedback?

    /// The bulk-edit value being typed (shown in the toolbar when multiple files are selected).
    var bulkEditValue: String = ""

    enum DateBulkEditMode: String, CaseIterable, Identifiable {
        case set = "Set"
        case offset = "Offset"

        var id: String { rawValue }
    }

    enum BulkOffsetUnit: String, CaseIterable, Identifiable {
        case hours = "Hours"
        case days = "Days"
        case months = "Months"

        var id: String { rawValue }
        var calendarComponent: Calendar.Component {
            switch self {
            case .hours: return .hour
            case .days: return .day
            case .months: return .month
            }
        }
    }

    var bulkEditMode: DateBulkEditMode = .set
    var bulkOffsetPositive = true
    var bulkOffsetAmount: String = ""
    var bulkOffsetUnit: BulkOffsetUnit = .hours

    struct SaveFeedback: Equatable {
        let filename: String
        let from: String
        let to: String
    }

    // MARK: - Import

    func importFiles(_ urls: [URL]) {
        let imageURLs = urls.filter { isImageFile($0) }
        guard !imageURLs.isEmpty else {
            statusMessage = "No image files found in drop."
            return
        }

        let existingURLs = Set(files.map(\.url))
        let newURLs = imageURLs.filter { !existingURLs.contains($0) }
        guard !newURLs.isEmpty else {
            statusMessage = "All files already loaded."
            return
        }

        isLoading = true
        statusMessage = nil

        // Batch-read all metadata in a single ExifTool invocation (much faster)
        let metadata = ExifToolService.readAllMetadata(from: newURLs)

        let newFiles = newURLs.map { url in
            let m = metadata[url]
            return ImageFile(
                url: url,
                dateTimeOriginal: m?.dateTimeOriginal ?? "",
                description: m?.description ?? "",
                createDate: m?.createDate,
                modifyDate: m?.modifyDate,
                imageDescription: m?.imageDescription,
                captionAbstract: m?.captionAbstract
            )
        }

        files.append(contentsOf: newFiles)
        isLoading = false
        statusMessage = "Loaded \(newFiles.count) file(s)."
    }

    func importFolder(_ url: URL) {
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var urls: [URL] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            if isImageFile(fileURL) { urls.append(fileURL) }
        }
        importFiles(urls)
    }

    // MARK: - Remove / Clear

    /// Removes the selected files from the list.
    func removeSelected() {
        guard !selectedFiles.isEmpty else {
            statusMessage = "No files selected to remove."
            return
        }
        let idsToRemove = Set(selectedFiles.map(\.id))
        files.removeAll { idsToRemove.contains($0.id) }
        selectedFile = nil
        selectedFiles = []
        lastSaveFeedback = nil
        lastDescriptionSaveFeedback = nil
        statusMessage = "Removed \(idsToRemove.count) file(s)."
    }

    /// Removes all loaded files and resets state.
    func clearAll() {
        files.removeAll()
        selectedFile = nil
        selectedFiles = []
        lastSaveFeedback = nil
        lastDescriptionSaveFeedback = nil
        statusMessage = nil
        bulkEditValue = ""
    }

    // MARK: - Selection & Feedback

    func select(_ file: ImageFile?) {
        selectedFile = file
    }

    /// Clears transient save feedback when navigating away or re-selecting.
    private func clearFeedback() {
        lastSaveFeedback = nil
        lastDescriptionSaveFeedback = nil
        statusMessage = nil
    }

    // MARK: - Bulk Edit

    /// Applies the current bulk edit settings to all currently selected files.
    func applyBulkEdit() {
        switch bulkEditMode {
        case .set:
            applyBulkSet()
        case .offset:
            applyBulkOffset()
        }
    }

    private func applyBulkSet() {
        let value = bulkEditValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            statusMessage = "Enter a date value before applying."
            return
        }
        let targets = selectedFiles.filter { $0.dateTimeOriginal != value }
        guard !targets.isEmpty else {
            statusMessage = "All selected files already have this value."
            return
        }
        for file in targets {
            file.dateTimeOriginal = value
        }
        statusMessage = "Applied to \(targets.count) file(s)."
    }

    private func applyBulkOffset() {
        let trimmedAmount = bulkOffsetAmount.trimmingCharacters(in: .whitespaces)
        guard let amount = Int(trimmedAmount), amount != 0 else {
            statusMessage = "Enter a non-zero offset amount."
            return
        }
        let signedAmount = bulkOffsetPositive ? amount : -amount
        let targets = selectedFiles
        guard !targets.isEmpty else {
            statusMessage = "No files selected."
            return
        }

        var appliedCount = 0
        var skippedCount = 0

        for file in targets {
            guard let originalDate = Self.exifDateFormatter.date(from: file.dateTimeOriginal) else {
                skippedCount += 1
                continue
            }
            guard let shiftedDate = Calendar.current.date(
                byAdding: bulkOffsetUnit.calendarComponent,
                value: signedAmount,
                to: originalDate
            ) else {
                skippedCount += 1
                continue
            }

            let newValue = Self.exifDateFormatter.string(from: shiftedDate)
            if newValue != file.dateTimeOriginal {
                file.dateTimeOriginal = newValue
                appliedCount += 1
            }
        }

        if appliedCount > 0 {
            let sign = bulkOffsetPositive ? "+" : "−"
            statusMessage = "Applied \(sign)\(amount) \(bulkOffsetUnit.rawValue.lowercased()) to \(appliedCount) file(s)."
        } else if skippedCount > 0 {
            statusMessage = "No valid DateTimeOriginal values could be offset."
        } else {
            statusMessage = "Offset did not change any files."
        }
    }

    /// Applies the current `bulkEditValue` to descriptions of all currently selected files.
    func applyBulkEditDescription() {
        let value = bulkEditValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            statusMessage = "Enter a description value before applying."
            return
        }
        let targets = selectedFiles.filter { $0.description != value }
        guard !targets.isEmpty else {
            statusMessage = "All selected files already have this description."
            return
        }
        for file in targets {
            file.description = value
        }
        statusMessage = "Applied description to \(targets.count) file(s)."
    }

    // MARK: - Save

    /// The number of files with unsaved changes.
    var dirtyCount: Int { files.filter(\.isDirty).count }

    /// Saves all dirty files in batch — groups by distinct field values
    /// so that files with the same edits are written together.
    func saveAll() {
        let dirtyFiles = files.filter(\.isDirty)
        guard !dirtyFiles.isEmpty else {
            statusMessage = "No changes to save."
            return
        }

        // Determine which files changed which field
        let dateChangedFiles = dirtyFiles.filter { $0.dateTimeOriginal != $0.originalDateTimeOriginal }
        let descChangedFiles = dirtyFiles.filter { $0.description != $0.originalDescription }

        var totalSuccess = 0
        var totalFail = 0
        var lastError = ""
        var dateFeedback: SaveFeedback?
        var descFeedback: SaveFeedback?

        // Track which files were successfully saved (by field)
        var dateSaved = Set<ImageFile.ID>()
        var descSaved = Set<ImageFile.ID>()

        // Save DateTimeOriginal changes grouped by value
        if !dateChangedFiles.isEmpty {
            let grouped = Dictionary(grouping: dateChangedFiles) { $0.dateTimeOriginal }
            for (value, group) in grouped {
                let urls = group.map(\.url)
                let result = ExifToolService.writeDateTimeOriginal(value, to: urls)
                if result.success {
                    for file in group {
                        dateSaved.insert(file.id)
                        dateFeedback = SaveFeedback(
                            filename: file.filename,
                            from: file.originalDateTimeOriginal.isEmpty ? "(empty)" : file.originalDateTimeOriginal,
                            to: file.dateTimeOriginal
                        )
                    }
                    totalSuccess += group.count
                } else {
                    totalFail += group.count
                    lastError = result.output
                }
            }
        }

        // Save Description changes grouped by value
        if !descChangedFiles.isEmpty {
            let grouped = Dictionary(grouping: descChangedFiles) { $0.description }
            for (value, group) in grouped {
                let urls = group.map(\.url)
                let result = ExifToolService.writeDescription(value, to: urls)
                if result.success {
                    for file in group {
                        descSaved.insert(file.id)
                        descFeedback = SaveFeedback(
                            filename: file.filename,
                            from: file.originalDescription.isEmpty ? "(empty)" : file.originalDescription,
                            to: file.description
                        )
                    }
                    totalSuccess += group.count
                } else {
                    totalFail += group.count
                    lastError = result.output
                }
            }
        }

        // Mark files clean only after ALL writes succeed for each field
        for file in dirtyFiles {
            let dateOK = !dateChangedFiles.contains(where: { $0.id == file.id }) || dateSaved.contains(file.id)
            let descOK = !descChangedFiles.contains(where: { $0.id == file.id }) || descSaved.contains(file.id)
            if dateOK && descOK {
                file.markClean()
            }
        }

        if let feedback = dateFeedback { lastSaveFeedback = feedback }
        if let feedback = descFeedback { lastDescriptionSaveFeedback = feedback }

        if totalFail == 0 {
            statusMessage = "✅ Saved \(totalSuccess) file(s)."
        } else if totalSuccess > 0 {
            statusMessage = "✅ \(totalSuccess) saved, ❌ \(totalFail) failed. Error: \(lastError)"
        } else {
            statusMessage = "❌ Save failed: \(lastError)"
        }
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    // MARK: - Sanitise

    /// Whether sanitise is currently running.
    var isSanitising = false

    /// Whether rename is currently running.
    var isRenaming = false

    /// Runs the full sanitise pipeline on all loaded files:
    ///   - Normalises DateTimeOriginal format
    ///   - Copies DateTimeOriginal → CreateDate, ModifyDate
    ///   - Clears OffsetTime, OffsetTimeOriginal, OffsetTimeDigitized
    ///   - Copies Description → ImageDescription, Caption-Abstract
    func sanitiseAll() {
        guard !files.isEmpty else {
            statusMessage = "No files to sanitise."
            return
        }

        guard !isSanitising else { return }

        isSanitising = true
        statusMessage = "Sanitising \(files.count) file(s)..."

        // Save any dirty files first so we sanitise from clean state
        if dirtyCount > 0 {
            saveAll()
        }

        let urls = files.map(\.url)
        let result = ExifToolService.sanitise(urls)

        if result.success {
            statusMessage = "✅ Sanitised \(files.count) file(s)."
            // Re-read metadata so read-only fields update
            let metadata = ExifToolService.readAllMetadata(from: urls)
            for file in files {
                if let m = metadata[file.url] {
                    // Set current values first (these will mark dirty via didSet
                    // since originals are still old), then reset originals to match.
                    if let dto = m.dateTimeOriginal {
                        file.dateTimeOriginal = dto
                    }
                    if let desc = m.description {
                        file.description = desc
                    }
                    // Update read-only fields
                    file.createDate = m.createDate
                    file.modifyDate = m.modifyDate
                    file.imageDescription = m.imageDescription
                    file.captionAbstract = m.captionAbstract
                }
                // markClean syncs originals to current, clearing dirty
                file.markClean()
            }
        } else {
            statusMessage = "❌ Sanitise failed: \(result.output)"
        }

        isSanitising = false
    }

    // MARK: - Rename

    /// Runs the rename pipeline on all loaded files.
    /// Renames files to: `{DateTimeOriginal}_{###}_{Description}.{ext}`
    func renameAll() {
        guard !files.isEmpty else {
            statusMessage = "No files to rename."
            return
        }

        guard !isRenaming else { return }

        // Save any dirty files first so we rename with clean metadata
        if dirtyCount > 0 {
            saveAll()
        }

        isRenaming = true
        statusMessage = "Renaming \(files.count) file(s)..."
        clearFeedback()

        let urls = files.map(\.url)
        let result = ExifToolService.renameFiles(urls)

        if result.success {
            let mappingCount = result.pathMapping.count
            statusMessage = "✅ Renamed \(mappingCount) file(s) successfully."

            // Update each file's URL and filename to match the new names on disk
            for file in files {
                if let newPath = result.pathMapping[file.url.path] {
                    let newURL = URL(fileURLWithPath: newPath)
                    file.updateURL(newURL)
                }
            }
        } else {
            statusMessage = "❌ Rename failed: \(result.output)"
        }

        isRenaming = false
    }

    // MARK: - Dedup

    private let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "gif", "bmp", "heic", "heif",
        "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "sr2",
        "webp", "ico", "psd"
    ]

    private func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }
}