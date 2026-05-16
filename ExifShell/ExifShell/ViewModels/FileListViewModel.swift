import Foundation
import SwiftUI
import UniformTypeIdentifiers

// ============================================================================
// FileListViewModel
// ============================================================================
// @MainActor @Observable view model that owns all application state:
//   - files: [ImageFile] — the source-of-truth file list
//   - selectedFile / selectedFiles — single-selection for preview, multi-selection for bulk edit
//   - bulkEditValue / bulkEditMode — state backing the bulk edit UI in ContentView
//   - isLoading / isSaving / isSanitising / isRenaming — operation progress flags
//
// Key methods:
//   - importFiles(_:) / importFolder(_:) — validates, deduplicates, batch-reads metadata
//   - saveAll() — groups dirty files by value for efficient ExifTool batch writes
//   - sanitiseAll() — full sanitise pipeline (normalise dates, clear offsets, sync descriptions)
//   - renameAll() — renames files to {DateTimeOriginal}_{###}_{Description}.{ext}
//   - applyBulkEdit() / applyBulkEditDescription() — bulk set values on selected files
//   - copyCreateDateToDateTimeOriginalSelection() / copyModifyDate...() — copy source dates
//   - removeSelected() / clearAll() — list management
//
// SORTING:
//   sortedFiles is cached and only re-computed when:
//   - sortKey or sortAscending changes
//   - files array is mutated (import, remove, clear)
//   - files are saved (markClean → invalidateSort)
//   - metadata is freshly loaded (applyMetadata → invalidateSort)
//   This prevents the table from re-sorting on every keystroke while editing.
//
// Types consumed:
//   - ImageFile (the data model)
//   - ExifToolService (static methods for all I/O)
//
// Types consuming this:
//   - ContentView (root view, imports calls importFiles/importFolder)
//   - FileTableView (reads sortedFiles, selectedFiles)
//   - PreviewPanel (reads selectedFile, calls saveAll/sanitiseAll/renameAll)
//   - DropZoneView (reads isLoading)
// ============================================================================

@MainActor
@Observable
class FileListViewModel {

    var files: [ImageFile] = [] {
        didSet { invalidateSort() }
    }

    // MARK: - Sorting

    enum SortKey {
        case filename
        case originalDateTime
        case description
    }

    /// Current sort key (defaults to filename).
    var sortKey: SortKey = .filename {
        didSet { invalidateSort() }
    }
    /// Whether sort is ascending.
    var sortAscending: Bool = true {
        didSet { invalidateSort() }
    }

    /// Private cache used by `sortedFiles`.
    private var _sortedFilesCache: [ImageFile] = []
    /// Incremented each time the sort cache should be rebuilt.
    /// `sortedFiles` always reads this property so the observation system
    /// always tracks it as a dependency, ensuring the view re-evaluates
    /// when invalidation occurs.
    private var _sortVersion = 0 {
        didSet { _sortedFilesCache = [] }
    }

    /// Marks the sort cache as stale so it will be rebuilt on the next read.
    private func invalidateSort() {
        _sortVersion &+= 1
    }

    /// Toggle sorting for a given key: if the same key is tapped, flip order; otherwise set to ascending.
    func toggleSort(_ key: SortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }
    }

    /// Returns the files array sorted according to `sortKey` and `sortAscending`.
    /// Uses a cached result that is only rebuilt when necessary (not on every keystroke).
    /// Always reads `_sortVersion` so the observation system tracks the dependency.
    var sortedFiles: [ImageFile] {
        // Read _sortVersion so the observation system tracks it as a dependency.
        // The value is not used directly — _sortVersion.didSet clears the cache,
        // so a stale cache is detected by .isEmpty below.
        let _ = _sortVersion
        if _sortedFilesCache.isEmpty {
            _sortedFilesCache = files.sorted { a, b in
                let cmp: ComparisonResult
                switch sortKey {
                case .filename:
                    cmp = a.filename.localizedCaseInsensitiveCompare(b.filename)
                case .description:
                    cmp = a.description.localizedCaseInsensitiveCompare(b.description)
                case .originalDateTime:
                    let da = Self.exifDateFormatter.date(from: a.dateTimeOriginal)
                    let db = Self.exifDateFormatter.date(from: b.dateTimeOriginal)
                    if let da, let db {
                        if da == db { cmp = .orderedSame }
                        else { cmp = da < db ? .orderedAscending : .orderedDescending }
                    } else if let _ = da {
                        cmp = .orderedAscending
                    } else if let _ = db {
                        cmp = .orderedDescending
                    } else {
                        cmp = a.filename.localizedCaseInsensitiveCompare(b.filename)
                    }
                }

                return sortAscending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
            }
        }
        return _sortedFilesCache
    }

    var selectedFile: ImageFile? {
        didSet { clearFeedback() }
    }
    var selectedFiles: [ImageFile] = []
    var isLoading = false
    var statusMessage: String?
    var operationMessage: String?
    var operationProgress: Double?
    var isSaving = false
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
        let reloadURLs = Array(Set(imageURLs.filter { existingURLs.contains($0) }))
        guard !newURLs.isEmpty || !reloadURLs.isEmpty else {
            statusMessage = "No image files found in drop."
            return
        }

        isLoading = true
        let initialMessage = newURLs.isEmpty ? "Refreshing metadata for \(reloadURLs.count) file(s)..." : "Loading \(newURLs.count) file(s)..."
        beginOperation(message: initialMessage, determinate: true)

        let placeholders = newURLs.map { url in
            ImageFile(
                url: url,
                dateTimeOriginal: "",
                description: "",
                createDate: nil,
                modifyDate: nil,
                imageDescription: nil,
                captionAbstract: nil
            )
        }
        files.append(contentsOf: placeholders)

        Task {
            // If ExifTool is unavailable, surface a helpful status message so users
            // understand why metadata fields may be empty.
            if let err = ExifToolService.availabilityError() {
                isLoading = false
                endOperation(successMessage: nil)
                statusMessage = err
                for file in placeholders { file.markClean() }
                return
            }

            let newMetadata = await loadMetadata(for: newURLs)
            let reloadMetadata = await loadMetadata(for: reloadURLs)

            applyMetadata(newMetadata, to: placeholders)
            applyMetadata(reloadMetadata, to: files.filter { reloadURLs.contains($0.url) })

            isLoading = false
            let successMessage: String
            switch (newURLs.count, reloadURLs.count) {
            case (0, let reloadCount):
                successMessage = "Refreshed metadata for \(reloadCount) file(s)."
            case (let newCount, 0):
                successMessage = "Loaded \(newCount) file(s)."
            default:
                successMessage = "Loaded \(newURLs.count) new file(s) and refreshed metadata for \(reloadURLs.count) existing file(s)."
            }
            endOperation(successMessage: successMessage)
        }
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

    private let metadataBatchSize = 80

    private func loadMetadata(for urls: [URL]) async -> [URL: ExifToolService.FileMetadata] {
        var merged: [URL: ExifToolService.FileMetadata] = [:]
        let chunks = stride(from: 0, to: urls.count, by: metadataBatchSize).map { start in
            Array(urls[start..<min(start + metadataBatchSize, urls.count)])
        }

        for (index, chunk) in chunks.enumerated() {
            let batchMetadata = await runBackground { ExifToolService.readAllMetadata(from: chunk) }
            for (url, metadata) in batchMetadata {
                merged[url] = metadata
            }
            let loadedCount = min((index + 1) * metadataBatchSize, urls.count)
            updateOperation(
                progress: Double(index + 1) / Double(chunks.count),
                message: "Reading metadata (\(loadedCount)/\(urls.count))..."
            )
        }

        return merged
    }

    /// Applies a metadata dictionary to the given file instances, marking them clean.
    private func applyMetadata(_ metadata: [URL: ExifToolService.FileMetadata], to files: [ImageFile]) {
        for file in files {
            if let m = metadata[file.url] {
                file.dateTimeOriginal = m.dateTimeOriginal ?? ""
                file.description = m.description ?? ""
                file.createDate = m.createDate
                file.modifyDate = m.modifyDate
                file.imageDescription = m.imageDescription
                file.captionAbstract = m.captionAbstract
                file.subject = m.subject
                file.keywords = m.keywords
                file.lastKeywordXMP = m.lastKeywordXMP
            }
            file.markClean()
        }
        invalidateSort()
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
        // files.didSet handles invalidation
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
        // files.didSet handles invalidation
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
        operationMessage = nil
        operationProgress = nil
    }

    private func beginOperation(message: String, determinate: Bool = false) {
        operationMessage = message
        operationProgress = determinate ? 0 : nil
        statusMessage = nil
    }

    private func updateOperation(progress: Double, message: String? = nil) {
        operationProgress = progress
        if let message {
            operationMessage = message
        }
    }

    private func endOperation(successMessage: String?) {
        operationMessage = nil
        operationProgress = nil
        statusMessage = successMessage
    }

    private func runBackground<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) {
            work()
        }.value
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

    // MARK: - Date helpers

    /// Copies CreateDate into DateTimeOriginal for each selected file.
    func copyCreateDateToDateTimeOriginalSelection() {
        copyDateFieldToDateTimeOriginal(
            sourceKeyPath: \ImageFile.createDate,
            label: "Create Date"
        )
    }

    /// Copies ModifyDate into DateTimeOriginal for each selected file.
    func copyModifyDateToDateTimeOriginalSelection() {
        copyDateFieldToDateTimeOriginal(
            sourceKeyPath: \ImageFile.modifyDate,
            label: "Modify Date"
        )
    }

    private func copyDateFieldToDateTimeOriginal(
        sourceKeyPath: KeyPath<ImageFile, String?>,
        label: String
    ) {
        let targets = selectedFiles.filter { $0[keyPath: sourceKeyPath]?.isEmpty == false }
        guard !targets.isEmpty else {
            statusMessage = "\(label) is unavailable for the selected file(s)."
            return
        }

        var updatedCount = 0
        for file in selectedFiles {
            guard let value = file[keyPath: sourceKeyPath], !value.isEmpty else {
                continue
            }
            if file.dateTimeOriginal != value {
                file.dateTimeOriginal = value
                updatedCount += 1
            }
        }

        if updatedCount > 0 {
            statusMessage = "Copied \(label) into DateTimeOriginal for \(updatedCount) file(s)."
        } else {
            statusMessage = "Selected files already have matching DateTimeOriginal values."
        }
    }

    // MARK: - Save

    /// The number of files with unsaved changes.
    var dirtyCount: Int { files.filter(\.isDirty).count }

    /// Saves all dirty files in batch — groups by distinct field values
    /// so that files with the same edits are written together.
    func saveAll() {
        Task { await saveAllAsync() }
    }

    private func saveAllAsync() async -> Bool {
        let dirtyFiles = files.filter(\.isDirty)
        guard !dirtyFiles.isEmpty else {
            statusMessage = "No changes to save."
            return true
        }

        guard !isSaving else {
            statusMessage = "Save already in progress."
            return false
        }

        isSaving = true
        beginOperation(message: "Saving changes...", determinate: false)

        let dateGroupResults = await saveDateGroups(from: dirtyFiles)
        let descGroupResults = await saveDescriptionGroups(from: dirtyFiles)

        markFilesClean(dirtyFiles,
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

        let finalMessage: String
        if totalFail == 0 {
            finalMessage = "✅ Saved \(totalSuccess) file(s)."
        } else if totalSuccess > 0 {
            finalMessage = "✅ \(totalSuccess) saved, ❌ \(totalFail) failed. Error: \(lastError)"
        } else {
            finalMessage = "❌ Save failed: \(lastError)"
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
                lastError = result.output
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
                lastError = result.output
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
    private func markFilesClean(_ dirtyFiles: [ImageFile],
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
        Task { await sanitiseAllAsync() }
    }

    private func sanitiseAllAsync() async {
        guard !files.isEmpty else {
            statusMessage = "No files to sanitise."
            return
        }

        guard !isSanitising else { return }

        isSanitising = true
        beginOperation(message: "Sanitising \(files.count) file(s)...")

        if dirtyCount > 0 {
            let saveSucceeded = await saveAllAsync()
            if !saveSucceeded {
                isSanitising = false
                endOperation(successMessage: statusMessage)
                return
            }
        }

        let urls = files.map(\.url)
        let result = await runBackground { ExifToolService.sanitise(urls) }

        if result.success {
            let metadata = await runBackground { ExifToolService.readAllMetadata(from: urls) }
            applyMetadata(metadata, to: files)
            endOperation(successMessage: "✅ Sanitised \(files.count) file(s).")
        } else {
            endOperation(successMessage: "❌ Sanitise failed: \(result.output)")
        }

        isSanitising = false
    }

    // MARK: - Rename

    /// Runs the rename pipeline on all loaded files.
    /// Renames files to: `{DateTimeOriginal}_{###}_{Description}.{ext}`
    func renameAll() {
        Task { await renameAllAsync() }
    }

    private func renameAllAsync() async {
        guard !files.isEmpty else {
            statusMessage = "No files to rename."
            return
        }

        guard !isRenaming else { return }

        if dirtyCount > 0 {
            let saveSucceeded = await saveAllAsync()
            if !saveSucceeded {
                return
            }
        }

        isRenaming = true
        beginOperation(message: "Renaming \(files.count) file(s)...")
        clearFeedback()

        let urls = files.map(\.url)
        let result = await runBackground { ExifToolService.renameFiles(urls) }

        if result.success {
            let mappingCount = result.pathMapping.count
            for file in files {
                if let newPath = result.pathMapping[file.url.path] {
                    let newURL = URL(fileURLWithPath: newPath)
                    file.updateURL(newURL)
                }
            }
            endOperation(successMessage: "✅ Renamed \(mappingCount) file(s) successfully.")
        } else {
            endOperation(successMessage: "❌ Rename failed: \(result.output)")
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