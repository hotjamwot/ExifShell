import Foundation
import SwiftUI

// ============================================================================
// FileListViewModel+Save
// ============================================================================
// Extension containing all save-related logic for FileListViewModel.
//
// Save has been merged with the old sanitise behaviour:
// - For images: writes DateTimeOriginal, CreateDate, ModifyDate, clears offsets
// - For videos: writes QuickTime:CreationDate, CreateDate, ModifyDate
// - Description writes to Description + ImageDescription/Caption-Abstract (images)
//   or Description (videos)
// ============================================================================

extension FileListViewModel {

    struct SaveFeedback: Equatable {
        let filename: String
        let from: String
        let to: String
    }

    // MARK: - Save

    /// Saves all dirty files in batch — groups by distinct field values
    /// so that files with the same edits are written together.
    func saveAll() {
        Task { await saveAllAsync() }
    }

    /// Saves dirty files among the current selection.
    func saveSelected() {
        Task { await saveAllAsync(only: selectedFiles) }
    }

    /// Saves dirty files. When `only` is provided, only those files are
    /// considered (used by sanitise to avoid saving unrelated dirty files).
    func saveAllAsync(only: [ImageFile]? = nil) async -> Bool {
        let dirtyFiles = (only ?? files).filter(\.isDirty)
        guard !dirtyFiles.isEmpty else {
            statusMessage = "No changes to save."
            return true
        }

        guard !isSaving else {
            statusMessage = "Save already in progress."
            return false
        }

        // Separate unwritable video files (ExifTool can't write RIFF/AVI or MPEG containers)
        let unwritableFiles = dirtyFiles.filter { ExifToolService.isUnwritableVideo($0.url) }
        let writableFiles = dirtyFiles.filter { !ExifToolService.isUnwritableVideo($0.url) }

        isSaving = true

        if unwritableFiles.isEmpty {
            beginOperation(message: "Saving changes...", determinate: false)
        } else {
            beginOperation(message: "Saving changes (skipping \(unwritableFiles.count) unwritable file(s))...", determinate: false)
        }

        let dateGroupResults = await saveDateGroups(from: writableFiles)
        let descGroupResults = await saveDescriptionGroups(from: writableFiles)

        // Only mark writable files clean — unwritable files (AVI/MPEG) were
        // skipped by the save helpers, so their changes were not persisted.
        markFilesClean(writableFiles,
                       dateChanged: dateGroupResults.changedIDs,
                       dateSaved: dateGroupResults.savedIDs,
                       descChanged: descGroupResults.changedIDs,
                       descSaved: descGroupResults.savedIDs)

        // After a successful save, re-sort to reflect any saved value changes
        invalidateSort()

        lastSaveFeedback = dateGroupResults.feedback
        lastDescriptionSaveFeedback = descGroupResults.feedback

        let totalSuccess = dateGroupResults.successCount + descGroupResults.successCount
        let totalFail = dateGroupResults.failCount + descGroupResults.failCount
        let lastError = dateGroupResults.errorMessage ?? descGroupResults.errorMessage ?? ""

        let aviWarning = unwritableFiles.isEmpty ? "" : " ⚠️ \(unwritableFiles.count) file(s) skipped (ExifTool cannot write AVI/MPEG containers)."

        let finalMessage: String
        if totalFail == 0 {
            if unwritableFiles.isEmpty {
                finalMessage = "✅ Saved \(totalSuccess) file(s)."
            } else {
                finalMessage = "✅ Saved \(totalSuccess) file(s).\(aviWarning)"
            }
            lastErrorDetail = nil
        } else if totalSuccess > 0 {
            finalMessage = "✅ \(totalSuccess) saved, ❌ \(totalFail) failed. Error: \(lastError)\(aviWarning)"
            lastErrorDetail = lastError
        } else {
            finalMessage = "❌ Save failed: \(lastError)\(aviWarning)"
            lastErrorDetail = lastError
        }

        isSaving = false
        endOperation(successMessage: finalMessage)
        return totalFail == 0
    }

    // MARK: - Save helpers

    /// Groups files by their pending `dateTimeOriginal` value and writes each group.
    /// Returns counts and feedback for the caller to aggregate.
    private struct SaveGroupResult {
        let successCount: Int
        let failCount: Int
        let savedIDs: Set<ImageFile.ID>
        let changedIDs: Set<ImageFile.ID>
        let feedback: SaveFeedback?
        let errorMessage: String?
    }

    private func saveDateGroups(from dirtyFiles: [ImageFile]) async -> SaveGroupResult {
        let changedFiles = dirtyFiles.filter { $0.dateTimeOriginal != $0.originalDateTimeOriginal }
        guard !changedFiles.isEmpty else {
            return SaveGroupResult(successCount: 0, failCount: 0, savedIDs: [], changedIDs: [], feedback: nil, errorMessage: nil)
        }

        let groups = Dictionary(grouping: changedFiles) { $0.dateTimeOriginal }
        let changedIDs = Set(changedFiles.map(\.id))
        var successCount = 0
        var failCount = 0
        var savedIDs: Set<ImageFile.ID> = []
        var feedback: SaveFeedback?
        var lastError: String?
        var completed = 0
        let total = groups.count

        for (value, group) in groups {
            let urls = group.map(\.url)
            let result = await runBackground { ExifToolService.writeDateTimeOriginal(value, to: urls) }
            completed += 1
            updateOperation(progress: Double(completed) / Double(total), message: "Saving date \(completed) of \(total)...")

            if result.success {
                for file in group {
                    savedIDs.insert(file.id)
                    feedback = SaveFeedback(
                        filename: file.filename,
                        from: file.originalDateTimeOriginal.isEmpty ? "(empty)" : file.originalDateTimeOriginal,
                        to: file.dateTimeOriginal
                    )
                }
                successCount += group.count
            } else {
                failCount += group.count
                lastError = ExifToolService.parseErrorSummary(result.output)
            }
        }

        return SaveGroupResult(
            successCount: successCount,
            failCount: failCount,
            savedIDs: savedIDs,
            changedIDs: changedIDs,
            feedback: feedback,
            errorMessage: lastError
        )
    }

    private func saveDescriptionGroups(from dirtyFiles: [ImageFile]) async -> SaveGroupResult {
        let changedFiles = dirtyFiles.filter { $0.description != $0.originalDescription }
        guard !changedFiles.isEmpty else {
            return SaveGroupResult(successCount: 0, failCount: 0, savedIDs: [], changedIDs: [], feedback: nil, errorMessage: nil)
        }

        let groups = Dictionary(grouping: changedFiles) { $0.description }
        let changedIDs = Set(changedFiles.map(\.id))
        var successCount = 0
        var failCount = 0
        var savedIDs: Set<ImageFile.ID> = []
        var feedback: SaveFeedback?
        var lastError: String?
        var completed = 0
        let total = groups.count

        for (value, group) in groups {
            let urls = group.map(\.url)
            let result = await runBackground { ExifToolService.writeDescription(value, to: urls) }
            completed += 1
            updateOperation(progress: Double(completed) / Double(total), message: "Saving description \(completed) of \(total)...")

            if result.success {
                for file in group {
                    savedIDs.insert(file.id)
                    feedback = SaveFeedback(
                        filename: file.filename,
                        from: file.originalDescription.isEmpty ? "(empty)" : file.originalDescription,
                        to: file.description
                    )
                }
                successCount += group.count
            } else {
                failCount += group.count
                lastError = ExifToolService.parseErrorSummary(result.output)
            }
        }

        return SaveGroupResult(
            successCount: successCount,
            failCount: failCount,
            savedIDs: savedIDs,
            changedIDs: changedIDs,
            feedback: feedback,
            errorMessage: lastError
        )
    }

    /// Marks files clean only after ALL writes succeed for each field.
    func markFilesClean(_ dirtyFiles: [ImageFile],
                         dateChanged: Set<ImageFile.ID>,
                         dateSaved: Set<ImageFile.ID>,
                         descChanged: Set<ImageFile.ID>,
                         descSaved: Set<ImageFile.ID>) {
        for file in dirtyFiles {
            let dateOK = !dateChanged.contains(file.id) || dateSaved.contains(file.id)
            let descOK = !descChanged.contains(file.id) || descSaved.contains(file.id)
            if dateOK && descOK {
                file.markClean()
            }
        }
    }
}