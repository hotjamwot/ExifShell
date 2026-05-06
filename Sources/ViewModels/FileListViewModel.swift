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

    /// The bulk-edit value being typed (shown in the toolbar when multiple files are selected).
    var bulkEditValue: String = ""

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

        // Batch-read all new files in a single ExifTool invocation (much faster)
        let metadata = ExifToolService.readDateTimeOriginal(from: newURLs)

        let newFiles = newURLs.map { url in
            let dto = metadata[url] ?? nil
            return ImageFile(url: url, dateTimeOriginal: dto ?? "")
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

    // MARK: - Clear

    /// Removes all loaded files and resets state.
    func clearAll() {
        files.removeAll()
        selectedFile = nil
        selectedFiles = []
        lastSaveFeedback = nil
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
        statusMessage = nil
    }

    // MARK: - Bulk Edit

    /// Applies the current `bulkEditValue` to all currently selected files.
    func applyBulkEdit() {
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

    // MARK: - Save

    /// The number of files with unsaved changes.
    var dirtyCount: Int { files.filter(\.isDirty).count }

    /// Saves all dirty files in a single batch per unique value.
    func saveAll() {
        let dirtyFiles = files.filter(\.isDirty)
        guard !dirtyFiles.isEmpty else {
            statusMessage = "No changes to save."
            return
        }

        let grouped = Dictionary(grouping: dirtyFiles) { $0.dateTimeOriginal }
        var totalSuccess = 0
        var totalFail = 0
        var lastError = ""
        var lastFeedback: SaveFeedback?

        for (value, group) in grouped {
            let urls = group.map(\.url)
            let result = ExifToolService.writeDateTimeOriginal(value, to: urls)
            if result.success {
                for file in group {
                    let feedback = SaveFeedback(
                        filename: file.filename,
                        from: file.originalDateTimeOriginal.isEmpty ? "(empty)" : file.originalDateTimeOriginal,
                        to: file.dateTimeOriginal
                    )
                    file.markClean()
                    lastFeedback = feedback
                }
                totalSuccess += group.count
            } else {
                totalFail += group.count
                lastError = result.output
            }
        }

        if let feedback = lastFeedback { lastSaveFeedback = feedback }

        if totalFail == 0 {
            statusMessage = "✅ Saved \(totalSuccess) file(s)."
        } else if totalSuccess > 0 {
            statusMessage = "✅ \(totalSuccess) saved, ❌ \(totalFail) failed. Error: \(lastError)"
        } else {
            statusMessage = "❌ Save failed: \(lastError)"
        }
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