import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
class FileListViewModel {

    var files: [ImageFile] = []
    var selectedFile: ImageFile?
    var isLoading = false
    var statusMessage: String?
    var lastSaveFeedback: SaveFeedback?

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

        let newFiles = newURLs.map { url in
            let dto = ExifToolService.readDateTimeOriginal(from: url) ?? ""
            return ImageFile(url: url, dateTimeOriginal: dto)
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

    // MARK: - Selection

    func select(_ file: ImageFile?) {
        selectedFile = file
    }

    // MARK: - Single Save

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