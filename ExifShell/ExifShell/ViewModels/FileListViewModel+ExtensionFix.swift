import Foundation
import SwiftUI

// ============================================================================
// FileListViewModel+ExtensionFix
// ============================================================================
// Extension containing logic to fix files whose actual content type
// (detected by ExifTool) doesn't match their filename suffix.
//
// Common case: HEIC files that are actually JPEGs — the filename ends in
// `.heic` but ExifTool reports `FileType: JPEG` / `FileTypeExtension: jpg`.
//
// The fix is a simple filesystem rename that only changes the extension:
//   `photo.heic` → `photo.jpg`
//
// This is safe because the file content is unchanged — only the suffix
// is corrected to match what the file actually contains.
// ============================================================================

extension FileListViewModel {

    /// Fixes the extension of all loaded files whose actual content type
    /// doesn't match their filename suffix.
    func fixExtensionsAll() {
        Task { await fixExtensionsAsync(only: nil) }
    }

    /// Fixes the extension of the currently selected files whose actual
    /// content type doesn't match their filename suffix.
    func fixExtensionsSelected() {
        Task { await fixExtensionsAsync(only: selectedFiles) }
    }

    /// Fixes the extension of files whose actual content type doesn't match
    /// their filename suffix. When `only` is provided, only those files are
    /// considered.
    ///
    /// The fix is a simple filesystem rename that only changes the extension:
    ///   `photo.heic` → `photo.jpg`
    ///
    /// This is safe because the file content is unchanged — only the suffix
    /// is corrected to match what the file actually contains.
    func fixExtensionsAsync(only: [ImageFile]? = nil) async {
        let targets = (only ?? files).filter(\.hasMismatchedExtension)
        guard !targets.isEmpty else {
            statusMessage = "No files with mismatched extensions to fix."
            return
        }

        guard !isFixingExtensions else { return }

        isFixingExtensions = true
        beginOperation(message: "Fixing extensions for \(targets.count) file(s)...", determinate: true)

        var fixedCount = 0
        var failedCount = 0
        var lastError: String?

        for (index, file) in targets.enumerated() {
            guard let correctExt = file.correctExtension, !correctExt.isEmpty else {
                failedCount += 1
                continue
            }

            let currentExt = file.url.pathExtension.lowercased()
            guard currentExt != correctExt else { continue }

            // Build the new URL with the corrected extension
            let newURL = file.url
                .deletingPathExtension()
                .appendingPathExtension(correctExt)

            // Skip if the destination already exists (avoid overwriting)
            if FileManager.default.fileExists(atPath: newURL.path) {
                failedCount += 1
                lastError = "Destination already exists: \(newURL.lastPathComponent)"
                continue
            }

            do {
                try FileManager.default.moveItem(at: file.url, to: newURL)
                file.updateURL(newURL)
                fixedCount += 1
            } catch {
                failedCount += 1
                lastError = error.localizedDescription
            }

            updateOperation(
                progress: Double(index + 1) / Double(targets.count),
                message: "Fixing extensions (\(index + 1)/\(targets.count))..."
            )
        }

        invalidateSort()

        if failedCount == 0 {
            endOperation(successMessage: "✅ Fixed extension on \(fixedCount) file(s).")
            lastErrorDetail = nil
        } else if fixedCount > 0 {
            endOperation(successMessage: "✅ Fixed \(fixedCount) file(s), ❌ \(failedCount) failed. Error: \(lastError ?? "unknown")")
            lastErrorDetail = lastError
        } else {
            endOperation(successMessage: "❌ Failed to fix extensions: \(lastError ?? "unknown error")")
            lastErrorDetail = lastError
        }

        isFixingExtensions = false
    }
}