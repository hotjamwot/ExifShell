import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
class FileListViewModel: ObservableObject {

    @Published var files: [ImageFile] = []
    @Published var selectedFile: ImageFile?
    @Published var isLoading = false
    @Published var statusMessage: String?

    /// Tracks the most recent save operation for rich feedback.
    /// Set on successful write, displayed in the UI, and auto-cleared.
    @Published var lastSaveFeedback: SaveFeedback?

    struct SaveFeedback: Equatable {
        let filename: String
        let field: String
        let from: String
        let to: String
    }

    // MARK: - Import

    /// Accepts dropped file URLs, loads them as ImageFile models,
    /// and reads DateTimeOriginal via ExifTool. Skips duplicates.
    func importFiles(_ urls: [URL]) {
        let imageURLs = urls.filter { isImageFile($0) }
        guard !imageURLs.isEmpty else {
            statusMessage = "No image files found in drop."
            return
        }

        // Dedup: skip URLs that are already loaded
        let existingURLs = Set(files.map(\.url))
        let newURLs = imageURLs.filter { !existingURLs.contains($0) }

        guard !newURLs.isEmpty else {
            statusMessage = "All files already loaded."
            return
        }

        isLoading = true
        statusMessage = nil

        let newFiles = newURLs.map { url in
            let dto = ExifToolService.readDateTimeOriginal(from: url) ?? ""
            return ImageFile(url: url, dateTimeOriginal: dto)
        }

        files.append(contentsOf: newFiles)
        isLoading = false
        statusMessage = "Loaded \(newFiles.count) file(s)."
    }

    /// Recursively loads all image files in a directory.
    func importFolder(_ url: URL) {
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var urls: [URL] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            if isImageFile(fileURL) {
                urls.append(fileURL)
            }
        }

        importFiles(urls)
    }

    // MARK: - Selection

    func select(_ file: ImageFile?) {
        selectedFile = file
    }

    // MARK: - Apply (Dirty-Only)

    /// The number of files with unsaved changes.
    var dirtyCount: Int {
        files.filter(\.isDirty).count
    }

    /// Applies changes only to the selected file if it's dirty.
    func applySelected() {
        guard let file = selectedFile else {
            statusMessage = "No file selected."
            return
        }

        guard file.isDirty else {
            statusMessage = "No changes to save for selected file."
            return
        }

        let result = ExifToolService.writeDateTimeOriginal(
            file.dateTimeOriginal,
            to: [file.url]
        )

        if result.success {
            let from = file.originalDateTimeOriginal
            let to = file.dateTimeOriginal
            markClean(file)
            lastSaveFeedback = SaveFeedback(
                filename: file.filename,
                field: "DateTimeOriginal",
                from: from.isEmpty ? "(empty)" : from,
                to: to
            )
            statusMessage = "✅ \(file.filename): \(from) → \(to)"
        } else {
            statusMessage = "❌ \(file.filename) — \(result.output)"
        }
    }

    /// Applies changes to all dirty files, grouped by value for efficient batch writes.
    func applyAll() {
        let dirtyFiles = files.filter(\.isDirty)
        guard !dirtyFiles.isEmpty else {
            statusMessage = "No changes to save."
            return
        }

        // Group dirty files by dateTimeOriginal value so we can batch-write
        // files sharing the same value in a single exiftool call.
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
                    let from = file.originalDateTimeOriginal
                    let to = file.dateTimeOriginal
                    markClean(file)
                    lastFeedback = SaveFeedback(
                        filename: file.filename,
                        field: "DateTimeOriginal",
                        from: from.isEmpty ? "(empty)" : from,
                        to: to
                    )
                }
                totalSuccess += group.count
            } else {
                totalFail += group.count
                lastError = result.output
            }
        }

        if let feedback = lastFeedback {
            lastSaveFeedback = feedback
        }

        if totalFail == 0 {
            statusMessage = "✅ Saved all \(totalSuccess) file(s)."
        } else if totalSuccess > 0 {
            statusMessage = "✅ \(totalSuccess) saved, ❌ \(totalFail) failed. Error: \(lastError)"
        } else {
            statusMessage = "❌ Save failed: \(lastError)"
        }
    }

    // MARK: - Helpers

    /// Resets dirty state for a file after a successful write.
    private func markClean(_ file: ImageFile) {
        guard let idx = files.firstIndex(where: { $0.id == file.id }) else { return }
        files[idx].markClean()
    }

    /// Common image file extensions.
    private let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "gif", "bmp", "heic", "heif",
        "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "sr2",
        "webp", "ico", "psd"
    ]

    /// Checks if a file is an image based on its extension.
    private func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }
}