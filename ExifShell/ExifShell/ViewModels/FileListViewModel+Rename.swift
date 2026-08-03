import Foundation
import SwiftUI

// ============================================================================
// FileListViewModel+Rename
// ============================================================================
// Extension containing all rename-related logic for FileListViewModel.
//
// Renames files to: `{Date}_{###}_{Description}.{ext}`
//
// Date source: CreateDate for files that have it (images + QuickTime
// videos), falling back to DateTimeOriginal for files without CreateDate
// (notably AVI/RIFF containers).
//
// Processed in batches of `metadataBatchSize` so the user sees live
// determinate progress and ExifTool isn't overwhelmed with a single
// massive command that appears to hang.
// ============================================================================

extension FileListViewModel {

    // MARK: - Rename

    /// Runs the rename pipeline on all loaded files.
    func renameAll() {
        Task { await renameAllAsync() }
    }

    /// Renames only the currently selected files.
    func renameSelected() {
        Task { await renameAllAsync(only: selectedFiles) }
    }

    /// Renames files. When `only` is provided, only those files are renamed.
    func renameAllAsync(only: [ImageFile]? = nil) async {
        let targets = only ?? files
        guard !targets.isEmpty else {
            statusMessage = "No files to rename."
            return
        }

        guard !isRenaming else { return }

        // Save any unsaved changes among the targets first
        let dirtyTargets = targets.filter(\.isDirty)
        if !dirtyTargets.isEmpty {
            let saveSucceeded = await saveAllAsync(only: dirtyTargets)
            if !saveSucceeded {
                return
            }
        }

        isRenaming = true
        beginOperation(message: "Renaming \(targets.count) file(s)...", determinate: true)
        clearFeedback()

        let allInputs = targets.map { file in
            ExifToolService.RenameInput(
                url: file.url,
                dateTimeOriginal: file.dateTimeOriginal,
                description: file.description
            )
        }
        let chunks = chunked(allInputs)
        let totalChunks = chunks.count

        var totalRenamed = 0
        var allSucceeded = true
        var lastError: String?

        for (index, chunk) in chunks.enumerated() {
            let chunkStartProgress = Double(index) / Double(totalChunks)
            let chunkEndProgress = Double(index + 1) / Double(totalChunks)

            updateOperation(
                progress: chunkStartProgress,
                message: "Renaming (\(index + 1)/\(totalChunks) chunks)..."
            )

            // Use a progress handler to report per-pass granularity inside each chunk,
            // so the progress bar doesn't stall during the multi-pass ExifTool rename.
            // runBackground is the shared helper for off-main-thread work.
            let result = await runBackground {
                ExifToolService.renameFiles(chunk) { passProgress, passMessage in
                    // Map the per-pass progress (0–1) into the chunk's progress window.
                    let overallProgress = chunkStartProgress + passProgress * (chunkEndProgress - chunkStartProgress)
                    Task { @MainActor in
                        self.updateOperation(
                            progress: overallProgress,
                            message: "\(passMessage) (\(index + 1)/\(totalChunks) chunks)"
                        )
                    }
                }
            }

            if result.success {
                let mappingCount = result.pathMapping.count
                totalRenamed += mappingCount

                // Update in-memory URL for each successfully renamed file
                for file in files {
                    if let newPath = result.pathMapping[file.url.path] {
                        let newURL = URL(fileURLWithPath: newPath)
                        file.updateURL(newURL)
                    }
                }
            } else {
                allSucceeded = false
                lastError = ExifToolService.parseErrorSummary(result.output)
                break
            }
        }

        if allSucceeded {
            endOperation(successMessage: "✅ Renamed \(totalRenamed) file(s) successfully.")
            lastErrorDetail = nil
        } else {
            let errorMsg = lastError ?? "unknown error"
            endOperation(successMessage: "❌ Rename failed after \(totalRenamed) file(s): \(errorMsg)")
            lastErrorDetail = errorMsg
        }

        isRenaming = false
    }
}