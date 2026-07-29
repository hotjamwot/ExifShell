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
//   - isLoading / isSaving / isRenaming — operation progress flags
//
// Key methods:
//   - importFiles(_:) / importFolder(_:) — validates, deduplicates, batch-reads metadata
//   - removeSelected() / clearAll() — list management
//   - applyBulkEdit() / applyBulkEditDescription() — bulk set values on selected files
//   - copyCreateDateToDateTimeOriginalSelection() / copyModifyDate...() — copy source dates
//   - sanitiseSelected() / sanitiseAll() — normalise dates/sync descriptions
//
// Save logic is in FileListViewModel+Save.swift:
//   - saveAll() / saveSelected() — groups dirty files by value for efficient ExifTool batch writes
//
// Rename logic is in FileListViewModel+Rename.swift:
//   - renameAll() / renameSelected() — renames files to {CreateDate}_{###}_{Description}.{ext}
//
// SORTING:
//   sortedFiles is cached and only re-computed when:
//   - sortKey or sortAscending changes
//   - files array is mutated (import, remove, clear)
//
// Types consumed:
//   - ImageFile (ExifShell/Models/ImageFile.swift)
//   - ExifToolService (ExifShell/Services/ExifToolService.swift)
//
// Used by:
//   - ContentView (ExifShell/ContentView.swift)
//   - FileTableView (ExifShell/Views/FileTableView.swift)
//   - PreviewPanel (ExifShell/Views/PreviewPanel.swift)
//   - BulkEditDateBar (ExifShell/Views/BulkEditDateBar.swift)
//   - BulkEditDescriptionBar (ExifShell/Views/BulkEditDescriptionBar.swift)
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
        case camera
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
    func invalidateSort() {
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
                case .camera:
                    let ca = "\(a.readOnly.cameraModel ?? "")"  // Sort by model only (most identifiable)
                    let cb = "\(b.readOnly.cameraModel ?? "")"
                    cmp = ca.localizedCaseInsensitiveCompare(cb)
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
    /// Whether rename is currently running.
    var isRenaming = false
    var lastSaveFeedback: SaveFeedback?
    var lastDescriptionSaveFeedback: SaveFeedback?
    /// Stores the full error output from the last failed operation (ExifTool stderr/stdout).
    /// Displayed alongside status messages containing ❌ so users can copy the details.
    var lastErrorDetail: String?

    // MARK: - Quick Stats

    /// Number of image files currently loaded.
    var imageCount: Int { files.filter { $0.mediaType == .image }.count }

    /// Number of video files currently loaded.
    var videoCount: Int { files.filter { $0.mediaType == .video }.count }

    /// Number of files with unsaved changes.
    var dirtyCount: Int { files.filter(\.isDirty).count }

    /// Number of selected files with unsaved changes.
    var selectedDirtyCount: Int { selectedFiles.filter(\.isDirty).count }

    /// The bulk-edit date value being typed (shown in the DateTimeOriginal toolbar when multiple files are selected).
    var bulkEditValue: String = ""

    /// The bulk-edit description value being typed (shown in the Description toolbar when multiple files are selected).
    var bulkEditDescriptionValue: String = ""

    /// Label text used for bulk edit actions, based on the selected files.
    var bulkEditDateLabel: String {
        if selectedFiles.isEmpty {
            return "DateTimeOriginal"
        }
        let quickTimeSelected = selectedFiles.contains { $0.mediaType == .video && $0.usesQuickTimeCreationDate }
        let imageSelected = selectedFiles.contains { $0.mediaType == .image }
        if quickTimeSelected && imageSelected {
            return "DateTimeOriginal / QuickTime:CreationDate"
        }
        return quickTimeSelected ? "QuickTime:CreationDate" : "DateTimeOriginal"
    }

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

    // MARK: - Import

    func importFiles(_ urls: [URL]) {
        let supportedURLs = urls.filter { isSupportedFile($0) }
        guard !supportedURLs.isEmpty else {
            statusMessage = "No supported files found in drop."
            return
        }

        let existingURLs = Set(files.map(\.url))
        let newURLs = supportedURLs.filter { !existingURLs.contains($0) }
        let reloadURLs = Array(Set(supportedURLs.filter { existingURLs.contains($0) }))
        guard !newURLs.isEmpty || !reloadURLs.isEmpty else {
            statusMessage = "No supported files found in drop."
            return
        }

        isLoading = true
        let initialMessage = newURLs.isEmpty ? "Refreshing metadata for \(reloadURLs.count) file(s)..." : "Loading \(newURLs.count) file(s)..."
        beginOperation(message: initialMessage, determinate: true)

        let placeholders = newURLs.map { url in
            ImageFile(
                url: url,
                mediaType: Self.mediaType(for: url),
                dateTimeOriginal: "",
                description: ""
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
            if isSupportedFile(fileURL) { urls.append(fileURL) }
        }
        importFiles(urls)
    }

    private let metadataBatchSize = 200

    /// Splits an array into chunks of `metadataBatchSize`.
    /// Eliminates the duplicated `stride` pattern across loadMetadata,
    /// sanitiseSelectedAsync, and renameAllAsync.
    ///
    /// Increasing the batch size helps keep ExifTool invocations efficient
    /// for dozens of files at once.
    func chunked<T>(_ array: [T]) -> [[T]] {
        stride(from: 0, to: array.count, by: metadataBatchSize).map { start in
            Array(array[start..<min(start + metadataBatchSize, array.count)])
        }
    }

    private func loadMetadata(for urls: [URL]) async -> [URL: ExifToolService.FileMetadata] {
        var merged: [URL: ExifToolService.FileMetadata] = [:]
        let chunks = chunked(urls)

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

                var readOnly = ReadOnlyMetadata()
                readOnly.createDate = m.createDate
                readOnly.modifyDate = m.modifyDate
                readOnly.imageDescription = m.imageDescription
                readOnly.captionAbstract = m.captionAbstract
                readOnly.subject = m.subject
                readOnly.keywords = m.keywords
                readOnly.lastKeywordXMP = m.lastKeywordXMP
                readOnly.duration = m.duration
                if let w = m.imageWidth, let h = m.imageHeight {
                    readOnly.resolution = "\(w)×\(h)"
                }
                readOnly.fileModifyDate = m.fileModifyDate
                readOnly.dateSource = m.dateSource
                readOnly.cameraMake = m.cameraMake
                readOnly.cameraModel = m.cameraModel
                file.readOnly = readOnly
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
        lastErrorDetail = nil
        statusMessage = nil
        bulkEditValue = ""
        bulkEditDescriptionValue = ""
        // files.didSet handles invalidation
    }

    // MARK: - Selection & Feedback

    func select(_ file: ImageFile?) {
        selectedFile = file
    }

    /// Clears transient save feedback when navigating away or re-selecting.
    func clearFeedback() {
        lastSaveFeedback = nil
        lastDescriptionSaveFeedback = nil
        lastErrorDetail = nil
        statusMessage = nil
        operationMessage = nil
        operationProgress = nil
    }

    func beginOperation(message: String, determinate: Bool = false) {
        operationMessage = message
        operationProgress = determinate ? 0 : nil
        statusMessage = nil
    }

    func updateOperation(progress: Double, message: String? = nil) {
        operationProgress = progress
        if let message {
            operationMessage = message
        }
    }

    func endOperation(successMessage: String?) {
        operationMessage = nil
        operationProgress = nil
        statusMessage = successMessage
    }

    func runBackground<T>(_ work: @escaping @Sendable () -> T) async -> T {
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
        invalidateSort()
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
            invalidateSort()
            let sign = bulkOffsetPositive ? "+" : "−"
            statusMessage = "Applied \(sign)\(amount) \(bulkOffsetUnit.rawValue.lowercased()) to \(appliedCount) file(s)."
        } else if skippedCount > 0 {
            statusMessage = "No valid DateTimeOriginal values could be offset."
        } else {
            statusMessage = "Offset did not change any files."
        }
    }

    /// Applies the current `bulkEditDescriptionValue` to descriptions of all currently selected files.
    func applyBulkEditDescription() {
        let value = bulkEditDescriptionValue.trimmingCharacters(in: .whitespaces)
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
        invalidateSort()
        statusMessage = "Applied description to \(targets.count) file(s)."
    }

    // MARK: - Date helpers

    /// Copies CreateDate into DateTimeOriginal for each selected file.
    func copyCreateDateToDateTimeOriginalSelection() {
        copyDateFieldToDateTimeOriginal(
            sourceKeyPath: \ImageFile.readOnly.createDate,
            label: "Create Date"
        )
    }

    /// Copies ModifyDate into DateTimeOriginal for each selected file.
    func copyModifyDateToDateTimeOriginalSelection() {
        copyDateFieldToDateTimeOriginal(
            sourceKeyPath: \ImageFile.readOnly.modifyDate,
            label: "Modify Date"
        )
    }

    /// Copies FileModifyDate into DateTimeOriginal for each selected file.
    func copyFileModifyDateToDateTimeOriginalSelection() {
        copyDateFieldToDateTimeOriginal(
            sourceKeyPath: \ImageFile.readOnly.fileModifyDate,
            label: "File Modification Date/Time"
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
            invalidateSort()
            statusMessage = "Copied \(label) into DateTimeOriginal for \(updatedCount) file(s)."
        } else {
            statusMessage = "Selected files already have matching DateTimeOriginal values."
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

    /// Sanitises the currently selected files by normalising date formats,
    /// propagating dates, clearing offset tags (images), and syncing descriptions.
    ///
    /// This fixes files with XMP-style ISO 8601 dates (e.g. `2010-03-27T01:40:19+00:00`)
    /// that the app's date formatter cannot parse, causing the Offset feature to skip them.
    ///
    /// Process:
    ///   1. Saves any dirty files first so in-memory changes are on disk
    ///   2. Runs ExifTool sanitise in batches of 80 with live determinate progress
    ///   3. Re-reads all metadata from disk to refresh the display
    func sanitiseSelected() {
        Task { await sanitiseSelectedAsync() }
    }

    /// Sanitises all loaded files by normalising date formats, propagating dates,
    /// clearing offset tags (images), and syncing descriptions.
    func sanitiseAll() {
        Task { await sanitiseAllAsync() }
    }

    private func sanitiseSelectedAsync() async {
        await sanitiseFiles(selectedFiles, emptyMessage: "No files selected to sanitise.")
    }

    private func sanitiseAllAsync() async {
        await sanitiseFiles(files, emptyMessage: "No files loaded to sanitise.")
    }

    private func sanitiseFiles(_ targets: [ImageFile], emptyMessage: String) async {
        guard !targets.isEmpty else {
            statusMessage = emptyMessage
            return
        }

        guard !isSanitising else { return }

        // Save only the dirty files among the targets — avoid saving
        // unrelated dirty files which would reset their dirty state.
        let dirtyTargets = targets.filter(\.isDirty)
        if !dirtyTargets.isEmpty {
            let saveSucceeded = await saveAllAsync(only: dirtyTargets)
            if !saveSucceeded { return }
        }

        // Filter out unwritable videos (AVI, MPEG — ExifTool can't write to these)
        let writableTargets = targets.filter { !ExifToolService.isUnwritableVideo($0.url) }
        let skippedCount = targets.count - writableTargets.count

        guard !writableTargets.isEmpty else {
            statusMessage = "ExifTool cannot write to AVI/MPEG containers. No files to sanitise."
            return
        }

        // Phase 1: Pre-write date tags for files whose date came from FileModifyDate,
        // OR files whose dateTimeOriginal contains a timezone offset (like
        // "2011:03:16 11:55:13+00:00"). These files have no embedded tag on disk
        // (fileModifyDate case), or have a date format that DateFmt cannot parse
        // (timezone-suffixed EXIF dates). In both cases we first write the
        // in-memory date value (stripped of timezone offset) to the appropriate
        // tag via a direct SET, then let the main sanitise pipeline normalise
        // via DateFmt (which only handles clean EXIF or ISO 8601 formats).
        //
        // Each file uses its OWN dateTimeOriginal — grouping by the stripped
        // value so files with matching dates are batched efficiently.
        //
        // IMPORTANT: For QuickTime videos, we write ONLY QuickTime:CreationDate
        // (not DateTimeOriginal) because -DateTimeOriginal= would create an XMP
        // tag in QuickTime containers, which ExifTool reads back in ISO 8601
        // format (e.g. "2011-03-16T11:55:13+00:00"), defeating the sanitise.
        let needsPreWrite = writableTargets.filter { file in
            guard !file.dateTimeOriginal.isEmpty else { return false }
            // Files with fileModifyDate source have no embedded tag — pre-write needed
            if file.readOnly.dateSource == .fileModifyDate { return true }
            // Files with non-EXIF date formats (ISO/T with dashes or timezone)
            // need a pre-write. Normalise to EXIF format and compare.
            let normalized = ExifToolService.normalizeToExifDate(file.dateTimeOriginal)
            return normalized != file.dateTimeOriginal
        }

        var preWriteError: String?

        if !needsPreWrite.isEmpty {
            updateOperation(
                progress: 0,
                message: "Preparing files with timezone-offset dates (\(needsPreWrite.count) file(s))..."
            )
            // Group files by their normalised EXIF date so files with
            // matching dates are written together in a single ExifTool call.
            let groupedByDate = Dictionary(grouping: needsPreWrite) {
                ExifToolService.normalizeToExifDate($0.dateTimeOriginal)
            }
            // Split groups by media type so QuickTime videos only get
            // QuickTime:CreationDate (not DateTimeOriginal which creates XMP tags)
            for (cleanedValue, group) in groupedByDate {
                let (_, qtURLs, otherVideoURLs) = ExifToolService.splitByMediaType(group.map(\.url))
                let imageAndOtherURLs = group.map(\.url).filter { !qtURLs.contains($0) }

                if !imageAndOtherURLs.isEmpty {
                    let result = await runBackground { ExifToolService.writeDateTimeOriginal(cleanedValue, to: imageAndOtherURLs) }
                    if !result.success {
                        preWriteError = ExifToolService.parseErrorSummary(result.output)
                        break
                    }
                }

                // For QuickTime videos, write only QuickTime:CreationDate (NOT DateTimeOriginal)
                // to avoid creating XMP tags that read back as ISO 8601
                if !qtURLs.isEmpty {
                    let result = await runBackground {
                        ExifToolService.writeQuickTimeCreationDate(cleanedValue, to: qtURLs)
                    }
                    if !result.success {
                        preWriteError = ExifToolService.parseErrorSummary(result.output)
                        break
                    }
                }
            }
        }

        isSanitising = true
        let messageBase = skippedCount > 0
            ? "Sanitising \(writableTargets.count) file(s) (skipping \(skippedCount) unwritable)..."
            : "Sanitising \(writableTargets.count) file(s)..."
        beginOperation(message: messageBase, determinate: true)

        // If the pre-write failed, we still continue with the main sanitise
        // on the remaining files (it'll just be a no-op on the fileModifyDate ones).
        let writableURLs = writableTargets.map(\.url)
        let chunks = chunked(writableURLs)
        let totalChunks = chunks.count

        var allSucceeded = true
        var lastError: String?

        for (index, chunk) in chunks.enumerated() {
            let result = await runBackground { ExifToolService.sanitise(chunk) }
            let progress = Double(index + 1) / Double(totalChunks)
            updateOperation(progress: progress, message: "Sanitising (\(index + 1)/\(totalChunks))...")

            if !result.success {
                allSucceeded = false
                lastError = ExifToolService.parseErrorSummary(result.output)
                break
            }
        }

        // Re-read metadata so display is refreshed with sanitised values
        let allURLs = writableTargets.map(\.url)
        let freshMetadata = await loadMetadata(for: allURLs)
        applyMetadata(freshMetadata, to: writableTargets)

        let suffix = skippedCount > 0 ? " ⚠️ \(skippedCount) file(s) skipped (unwritable format)." : ""

        if allSucceeded {
            endOperation(successMessage: "✅ Sanitised \(writableTargets.count) file(s).\(suffix)")
            lastErrorDetail = nil
        } else {
            let errorMsg = lastError ?? "unknown error"
            endOperation(successMessage: "❌ Sanitise failed: \(errorMsg)\(suffix)")
            lastErrorDetail = errorMsg
        }

        isSanitising = false
    }

    // MARK: - File Type Detection

    /// Image extensions supported by ExifShell. Video extensions are defined
    /// in `ExifToolService.videoExtensions` (single source of truth).
    private let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "gif", "bmp", "heic", "heif",
        "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "sr2",
        "webp", "ico", "psd"
    ]

    /// Returns the MediaType for a given URL based on its extension.
    /// Uses ExifToolService.videoExtensions as the single source of truth.
    static func mediaType(for url: URL) -> MediaType {
        let ext = url.pathExtension.lowercased()
        if ExifToolService.videoExtensions.contains(ext) {
            return .video
        }
        return .image
    }

    /// Returns true if the file extension is a supported image or video type.
    /// Video extensions reference ExifToolService.videoExtensions (single source of truth).
    private func isSupportedFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return imageExtensions.contains(ext) || ExifToolService.videoExtensions.contains(ext)
    }
}