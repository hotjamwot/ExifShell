import Foundation

// ============================================================================
// ExifToolService
// ============================================================================
// All metadata operations delegate to the ExifTool CLI via Process.
// This file is a pure shell wrapper — all metadata logic lives in exiftool.
//
// Key design patterns:
//   - Batch reads: pass [URL], get [URL: T] back (single process call).
//   - Batch writes: pass [URL] with a shared value (single process call).
//   - All errors return nil/empty/default rather than throwing.
//   - exifToolPath auto-resolves at static init time, no PATH dependency.
//
// Video support:
//   - Images use EXIF tags (DateTimeOriginal, ImageDescription, etc.)
//   - Videos use QuickTime tags (QuickTime:CreationDate, etc.)
//   - File type is detected from URL extension at the service layer
//   - Mixed batches (images + videos) are split before write operations
//   - readAllMetadata falls back to CreateDate for files (especially videos)
//     that don't have DateTimeOriginal
//
// Save philosophy (merged with sanitise behaviour):
//   - writeDateTimeOriginal now writes to ALL date tags in one shot:
//     DateTimeOriginal/QuickTime:CreationDate + CreateDate + ModifyDate
//     + clears offset tags (images). This replaces the old sanitise pipeline.
//   - writeDescription writes to Description + ImageDescription/Caption-Abstract
//   - There is no separate "sanitise" operation — Save does it all.
//
// Depends on:
//   - MediaType enum from ImageFile.swift (for video extension detection)
//
// Types referenced:
//   - ImageFile (for the data model layer; service is decoupled via URL keys)
//   - FileListViewModel (calls this service, doesn't import it directly)
//   - ExifToolOutput, FullExifToolOutput (private JSON decoders)
//
// Commands used (see BRIEF.md for full list):
//   Read:    exiftool -json -TAG1 -TAG2 <files...>
//   Write:   exiftool -overwrite_original -TAG=VALUE <files...>
//   Rename:  exiftool -v -m "-FileName<${CreateDate;...}_%03.c....%e" -d fmt
// ============================================================================

enum ExifToolService {

    // MARK: - ExifTool Path Resolution

    /// Resolved path to the `exiftool` binary.
    /// Searches common installation locations so the app works regardless
    /// of whether it's launched via `swift run`, Xcode, or as a bundled .app.
    /// (Xcode does not inherit your shell PATH, which is the most common
    /// reason for ExifTool to appear missing.)
    private static let exifToolPath: String = {
        // First, try `which exiftool` using the user's PATH — this helps when
        // exiftool is installed via Homebrew and the runtime PATH points to it.
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        whichProcess.arguments = ["which", "exiftool"]
        let whichPipe = Pipe()
        whichProcess.standardOutput = whichPipe
        whichProcess.standardError = FileHandle.nullDevice
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            if whichProcess.terminationStatus == 0 {
                let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                    if FileManager.default.isExecutableFile(atPath: path) {
                        return path
                    }
                }
            }
        } catch {}

        // If `which` didn't return an executable path, fall back to common locations.
        let candidates = [
            "/opt/homebrew/bin/exiftool",   // Apple Silicon Homebrew
            "/usr/local/bin/exiftool",      // Intel Homebrew
            "/usr/bin/exiftool",            // System install (rare)
            "/opt/local/bin/exiftool",      // MacPorts
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return ""  // Will be detected at operation time
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Returns an error message if exiftool was not found at startup.
    private static var missingToolError: String? {
        guard !exifToolPath.isEmpty else {
            return "ExifTool not found. Install it with: brew install exiftool"
        }
        // Also verify it's still executable (in case it was uninstalled between runs)
        guard FileManager.default.isExecutableFile(atPath: exifToolPath) else {
            return "ExifTool at '\(exifToolPath)' is no longer executable."
        }
        return nil
    }

    /// Public helper to allow callers to check availability and show a helpful message.
    static func availabilityError() -> String? {
        return missingToolError
    }

    // MARK: - Shared Process Runner

    /// Result of a read operation — keeps raw stdout data so JSON decoding
    /// works without a String → Data round-trip that could corrupt encoding.
    private struct ReadResult {
        let success: Bool
        let stdoutData: Data
    }

    /// Result of a write operation — returns captured text output.
    struct WriteResult {
        let success: Bool
        let output: String
    }

    /// Runs exiftool for a **read** operation (stdout is JSON data).
    /// - Parameter args: Command-line arguments for exiftool.
    /// - Returns: A ReadResult with the raw stdout data. stderr is discarded.
    private static func runReadTool(with args: [String]) -> ReadResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exifToolPath)
        process.arguments = args

        let outPipe = Pipe()
        process.standardOutput = outPipe
        // Discard stderr for reads — exiftool may emit warnings there
        // but the JSON we need is always on stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            // ExifTool can return non-zero exit codes for warnings while
            // still producing valid JSON on stdout. We trust stdout data
            // if it's non-empty, even if exit code indicates a warning.
            let success = !data.isEmpty || process.terminationStatus == 0
            return ReadResult(success: success, stdoutData: data)
        } catch {
            return ReadResult(success: false, stdoutData: Data())
        }
    }

    /// Runs exiftool for a **write** operation (captures both stdout and stderr
    /// as text for error reporting).
    ///
    /// Tolerates exit code 1 as success because all write operations use `-m`
    /// (ignore minor errors). When `-m` is active, ExifTool still exits with
    /// code 1 for minor warnings even when all writes succeeded — treating it
    /// as failure would produce false "Save failed" / "Rename failed" messages
    /// with misleading verbose output in the status bar.
    ///
    /// - Parameter args: Command-line arguments for exiftool.
    /// - Returns: A WriteResult with success status and combined text output.
    private static func runWriteTool(with args: [String]) -> WriteResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exifToolPath)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errData, encoding: .utf8) ?? ""
            let combined = [output, errorOutput]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // ExifTool exit codes:
            //   0 = success (no warnings)
            //   1 = minor warnings (with -m flag, most minor errors are demoted to warnings)
            //   2+ = fatal errors
            // All write operations use -m, so treat exit code 1 as success.
            let success = process.terminationStatus <= 1
            return WriteResult(success: success, output: combined)
        } catch {
            return WriteResult(success: false, output: error.localizedDescription)
        }
    }

    /// Creates an empty FileMetadata value (all nil) for use as error/default sentinel.
    private static func emptyMetadata() -> FileMetadata {
        FileMetadata(
            dateTimeOriginal: nil, createDate: nil, modifyDate: nil,
            description: nil, imageDescription: nil, captionAbstract: nil, subject: nil,
            keywords: nil, lastKeywordXMP: nil,
            duration: nil, imageWidth: nil, imageHeight: nil,
            fileModifyDate: nil, dateSource: nil
        )
    }

    // MARK: - Read

    /// Reads `DateTimeOriginal` from a single file using `exiftool -json`.
    /// For files (especially videos) that don't have DateTimeOriginal,
    /// falls back to CreateDate which is available across both formats.
    /// - Parameter url: The file URL to read from.
    /// - Returns: The raw DateTimeOriginal string, or nil if missing/error.
    static func readDateTimeOriginal(from url: URL) -> String? {
        readDateTimeOriginal(from: [url])[url] ?? nil
    }

    /// Reads `DateTimeOriginal` from multiple files in a **single** ExifTool invocation.
    ///
    /// This is dramatically faster than calling `readDateTimeOriginal(from:)` in a loop
    /// because ExifTool only starts up once and processes all files in one pass.
    /// For large batches (100+ files), this can be 50–100× faster.
    ///
    /// Falls back to CreateDate for files (e.g. videos) that don't have DateTimeOriginal.
    /// This ensures the DTO field is always populated for display and rename operations.
    ///
    /// - Parameter urls: The file URLs to read from.
    /// - Returns: A dictionary mapping each URL to its DateTimeOriginal (or nil if missing/error).
    static func readDateTimeOriginal(from urls: [URL]) -> [URL: String?] {
        guard !urls.isEmpty else { return [:] }
        guard missingToolError == nil else {
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as String?) })
        }

        let result = runReadTool(with: ["-json", "-DateTimeOriginal", "-CreateDate"] + urls.map(\.path))
        guard !result.stdoutData.isEmpty,
              let json = try? decoder.decode([DateTimeFallbackOutput].self, from: result.stdoutData) else {
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as String?) })
        }

        // Build a lookup keyed by standardised file path to handle URL encoding
        // differences between drag-and-drop URLs (which may use %27 for apostrophes)
        // and file paths returned by exiftool in SourceFile (which use raw characters).
        // URL equality comparison would fail silently for paths with special characters
        // like apostrophes, commas, or spaces.
        let pathLookup: [String: URL] = Dictionary(uniqueKeysWithValues: urls.map {
            ($0.standardizedFileURL.path, $0)
        })

        var results: [URL: String?] = [:]
        for entry in json {
            let entryPath = (entry.sourceFile as NSString).standardizingPath
            if let originalURL = pathLookup[entryPath] {
                // Fallback: if DateTimeOriginal is nil, use CreateDate
                results[originalURL] = entry.dateTimeOriginal ?? entry.createDate
            }
        }
        for url in urls {
            if !results.keys.contains(url) { results[url] = nil }
        }
        return results
    }

    // MARK: - Full Metadata Read (Batch)

    /// A bundle of all metadata fields we care about for a single file.
    struct FileMetadata {
        let dateTimeOriginal: String?
        let createDate: String?
        let modifyDate: String?
        let description: String?
        let imageDescription: String?
        let captionAbstract: String?
        let subject: String?
        let keywords: String?
        let lastKeywordXMP: String?
        let duration: String?
        let imageWidth: String?
        let imageHeight: String?
        /// The filesystem modification date from ExifTool's File:FileModifyDate.
        /// Used as a last-resort fallback for files (e.g. MPG) with no embedded date tags.
        let fileModifyDate: String?
        /// Where the dateTimeOriginal value came from. nil when dateTimeOriginal is nil.
        let dateSource: DateSource?
    }

    /// Indicates which ExifTool tag provided the dateTimeOriginal value.
    enum DateSource: String {
        case dateTimeOriginal
        case createDate
        case fileModifyDate
    }

    /// Reads all supported metadata fields from multiple files in a **single** ExifTool invocation.
    ///
    /// For files that don't have DateTimeOriginal (e.g. videos), dateTimeOriginal
    /// falls back to CreateDate. This ensures the DTO field is always populated
    /// for display and rename operations.
    ///
    /// - Parameter urls: The file URLs to read from.
    /// - Returns: A dictionary mapping each URL to its FileMetadata.
    static func readAllMetadata(from urls: [URL]) -> [URL: FileMetadata] {
        guard !urls.isEmpty else { return [:] }
        guard missingToolError == nil else {
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, emptyMetadata()) })
        }

        let args = [
            "-json",
            "-DateTimeOriginal",
            "-CreateDate",
            "-ModifyDate",
            "-FileModifyDate",
            "-Description",
            "-ImageDescription",
            "-Caption-Abstract",
            "-Subject",
            "-Keywords",
            "-LastKeywordXMP",
            "-Duration",
            "-ImageWidth",
            "-ImageHeight"
        ] + urls.map(\.path)

        let result = runReadTool(with: args)

        // If stdout is empty but we had no error, all files simply have no metadata
        guard !result.stdoutData.isEmpty,
              let json = try? decoder.decode([FullExifToolOutput].self, from: result.stdoutData) else {
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, emptyMetadata()) })
        }

        // Build a path-based lookup to account for URL encoding differences between
        // drag-and-drop URLs and exiftool's SourceFile output. Example: a file at
        // "Val's Photo.jpg" would be passed as "file:///.../Val%27s%20Photo.jpg" from
        // the drag system, but exiftool returns "/.../Val's Photo.jpg" in SourceFile.
        // URL equality would fail; path-based matching resolves this robustly.
        let pathLookup: [String: URL] = Dictionary(uniqueKeysWithValues: urls.map {
            ($0.standardizedFileURL.path, $0)
        })

        var results: [URL: FileMetadata] = [:]
        for entry in json {
            let entryPath = (entry.sourceFile as NSString).standardizingPath
            guard let originalURL = pathLookup[entryPath] else { continue }
            // Fallback chain: DateTimeOriginal → CreateDate → FileModifyDate
            // FileModifyDate (filesystem timestamp) is the last resort for files
            // like MPG/MPEG that have no embedded date tags at all.
            let dateSource: ExifToolService.DateSource?
            let dto: String?
            if let dtoValue = entry.dateTimeOriginal {
                dto = dtoValue
                dateSource = .dateTimeOriginal
            } else if let cdValue = entry.createDate {
                dto = cdValue
                dateSource = .createDate
            } else if let fmdValue = entry.fileModifyDate {
                dto = fmdValue
                dateSource = .fileModifyDate
            } else {
                dto = nil
                dateSource = nil
            }
            results[originalURL] = FileMetadata(
                dateTimeOriginal: dto,
                createDate: entry.createDate,
                modifyDate: entry.modifyDate,
                description: entry.description,
                imageDescription: entry.imageDescription,
                captionAbstract: entry.captionAbstract,
                subject: entry.subject?.joined(separator: ", "),
                keywords: entry.keywords?.joined(separator: ", "),
                lastKeywordXMP: entry.lastKeywordXMP?.joined(separator: ", "),
                duration: entry.duration,
                imageWidth: entry.imageWidth,
                imageHeight: entry.imageHeight,
                fileModifyDate: entry.fileModifyDate,
                dateSource: dateSource
            )
        }
        for url in urls {
            if !results.keys.contains(url) {
                results[url] = emptyMetadata()
            }
        }
        return results
    }

    // MARK: - Write (Batch)

    /// Writes the date/time value to all relevant date tags in one shot.
    ///
    /// This replaces the old "save DateTimeOriginal" + "sanitise" two-step approach.
    /// Now a single Save operation writes to every date-related tag, ensuring
    /// consistency across all EXIF/QuickTime date fields without needing a
    /// separate sanitise step.
    ///
    /// **For images:**
    ///   - Writes DateTimeOriginal
    ///   - Copies to CreateDate, ModifyDate
    ///   - Clears OffsetTime, OffsetTimeOriginal, OffsetTimeDigitized
    ///
    /// **For videos:**
    ///   - Writes QuickTime:CreationDate
    ///   - Copies to CreateDate, ModifyDate, and DateTimeOriginal
    ///   - (No offset time tags — not applicable to QuickTime containers)
    ///
    /// Note: DateTimeOriginal is included so readAllMetadata (which reads
    /// DateTimeOriginal as the primary DTO field) returns the updated value
    /// when the file is re-imported. Without this, .mov/.mp4 files would
    /// appear to save correctly in the UI but revert on re-import.
    ///
    /// - Parameters:
    ///   - value: The date string to write (e.g. "2024:01:15 14:30:00").
    ///   - urls: The file URLs to apply the change to.
    /// - Returns: A WriteResult with success status and captured output/error.
    static func writeDateTimeOriginal(_ value: String, to urls: [URL]) -> WriteResult {
        guard !urls.isEmpty else {
            return WriteResult(success: false, output: "No files provided.")
        }
        if let error = missingToolError {
            return WriteResult(success: false, output: error)
        }

        // Split into images, QuickTime videos, and other videos (AVI, MKV, etc.)
        // — they use different primary date tags per container format.
        let (imageURLs, quickTimeURLs, otherVideoURLs) = splitByMediaType(urls)

        var allSucceeded = true
        var outputs: [String] = []

        if !imageURLs.isEmpty {
            // Images: write DateTimeOriginal, propagate to CreateDate/ModifyDate,
            // clear offset tags for clean EXIF data.
            let args: [String] = [
                "-overwrite_original",
                "-m",
                "-EXIF:DateTimeOriginal=\(value)",
                "-CreateDate=\(value)",
                "-ModifyDate=\(value)",
                "-OffsetTime=",
                "-OffsetTimeOriginal=",
                "-OffsetTimeDigitized="
            ] + imageURLs.map(\.path)
            let result = runWriteTool(with: args)
            if !result.success { allSucceeded = false }
            if !result.output.isEmpty { outputs.append(result.output) }
        }

        if !quickTimeURLs.isEmpty {
            // QuickTime videos (MP4, MOV, M4V): write QuickTime:CreationDate,
            // propagate to CreateDate, ModifyDate, and DateTimeOriginal.
            // DateTimeOriginal is read back by the app's readAllMetadata as the
            // primary DTO field — without writing it, the change appears to "stick"
            // in the table but reverts on re-import.
            let args: [String] = [
                "-overwrite_original",
                "-m",
                "-QuickTime:CreationDate=\(value)",
                "-CreateDate=\(value)",
                "-ModifyDate=\(value)",
                "-DateTimeOriginal=\(value)"
            ] + quickTimeURLs.map(\.path)
            let result = runWriteTool(with: args)
            if !result.success { allSucceeded = false }
            if !result.output.isEmpty { outputs.append(result.output) }
        }

        if !otherVideoURLs.isEmpty {
            // Non-QuickTime videos (AVI, MKV, WMV, etc.): use generic
            // DateTimeOriginal tag which ExifTool maps to the correct
            // container-specific tag (e.g. RIFF:DateTimeOriginal for AVI).
            let args: [String] = [
                "-overwrite_original",
                "-m",
                "-DateTimeOriginal=\(value)",
                "-CreateDate=\(value)",
                "-ModifyDate=\(value)"
            ] + otherVideoURLs.map(\.path)
            let result = runWriteTool(with: args)
            if !result.success { allSucceeded = false }
            if !result.output.isEmpty { outputs.append(result.output) }
        }

        let combined = outputs.joined(separator: "\n")
        let anyEmpty = imageURLs.isEmpty && quickTimeURLs.isEmpty && otherVideoURLs.isEmpty
        return WriteResult(success: allSucceeded || anyEmpty, output: combined)
    }

    /// Writes a description value to all description-related tags.
    /// For images: Description, ImageDescription, Caption-Abstract.
    /// For videos: Description only (ImageDescription / Caption-Abstract
    /// are EXIF/IPTC tags and don't exist in QuickTime containers).
    ///
    /// - Parameters:
    ///   - value: The description string to write.
    ///   - urls: The file URLs to apply the change to.
    /// - Returns: A WriteResult with success status and captured output/error.
    static func writeDescription(_ value: String, to urls: [URL]) -> WriteResult {
        guard !urls.isEmpty else {
            return WriteResult(success: false, output: "No files provided.")
        }
        if let error = missingToolError {
            return WriteResult(success: false, output: error)
        }

        let (imageURLs, quickTimeURLs, otherVideoURLs) = splitByMediaType(urls)
        let allVideoURLs = quickTimeURLs + otherVideoURLs
        var allSucceeded = true
        var outputs: [String] = []

        if !imageURLs.isEmpty {
            // Images: write to all description-related tags
            let args = [
                "-overwrite_original",
                "-m",
                "-Description=\(value)",
                "-ImageDescription=\(value)",
                "-Caption-Abstract=\(value)"
            ] + imageURLs.map(\.path)
            let result = runWriteTool(with: args)
            if !result.success { allSucceeded = false }
            if !result.output.isEmpty { outputs.append(result.output) }
        }

        if !allVideoURLs.isEmpty {
            // All videos (QuickTime and non-QuickTime): only Description tag is
            // applicable. ExifTool maps it to the correct container-specific tag
            // (QuickTime:UserData:Description for MP4/MOV, RIFF:Comment for AVI, etc.).
            let args = [
                "-overwrite_original",
                "-m",
                "-Description=\(value)"
            ] + allVideoURLs.map(\.path)
            let result = runWriteTool(with: args)
            if !result.success { allSucceeded = false }
            if !result.output.isEmpty { outputs.append(result.output) }
        }

        let combined = outputs.joined(separator: "\n")
        let anyEmpty = imageURLs.isEmpty && allVideoURLs.isEmpty
        return WriteResult(success: allSucceeded || anyEmpty, output: combined)
    }

    /// Result of a rename operation, including a mapping of old path → new path.
    struct RenameResult {
        let success: Bool
        let output: String
        /// Maps each original file path to its new path after renaming.
        /// Only populated on success — empty on failure.
        let pathMapping: [String: String]
    }

    /// Metadata needed for renaming a single file. Provides in-memory values
    /// so unwritable files (AVI, MPEG) can be renamed using the edited
    /// DateTimeOriginal rather than the stale on-disk value.
    struct RenameInput {
        let url: URL
        let dateTimeOriginal: String
        let description: String
    }

    /// Renames files using their metadata according to the pattern:
    ///   - With description: `{Date}_{###}_{Description}.{ext}`
    ///   - Without description: `{Date}_{###}.{ext}`
    ///
    /// The underscore separator before the description is only included when
    /// the file has a non-empty description, avoiding trailing underscores
    /// on descriptionless files.
    ///
    /// Date source priority:
    ///   1. `CreateDate` — available on images (EXIF:CreateDate) and
    ///      QuickTime videos (QuickTime:CreateDate), and always synced by Save.
    ///   2. `DateTimeOriginal` — fallback for files without CreateDate,
    ///      notably AVI/RIFF containers which only have RIFF:DateTimeOriginal.
    ///   3. `FileModifyDate` — last resort for files like MPG/MPEG that have
    ///      no embedded date tags at all; uses the filesystem modification date.
    ///
    /// Runs three ExifTool passes using `-if` to split the batch:
    ///   Pass 1: files that have CreateDate → uses `${CreateDate}`
    ///   Pass 2: remaining files without CreateDate but with DateTimeOriginal
    ///   Pass 3: remaining files without either → uses `${FileModifyDate}`
    ///
    /// With `-v` (verbose) ExifTool outputs lines like:
    /// `'old/path/file.jpg' -> 'new/path/file.jpg'`
    /// which we parse to build the path mapping for the caller.
    ///
    /// - Parameters:
    ///   - inputs: The file inputs (URL + metadata) to rename.
    ///   - progressHandler: Optional closure called after each of the 3 ExifTool
    ///     rename passes with a progress value in [0,1] and a message describing
    ///     the current pass. This lets the caller (e.g. ViewModel) show granular
    ///     progress within a single batch chunk instead of the progress bar
    ///     stalling during each multi-pass ExifTool invocation.
    /// - Returns: A RenameResult with success status, output, and a path mapping.
    static func renameFiles(_ inputs: [RenameInput],
                             progressHandler: ((Double, String) -> Void)? = nil) -> RenameResult {
        guard !inputs.isEmpty else {
            return RenameResult(success: false, output: "No files provided.", pathMapping: [:])
        }
        if let error = missingToolError {
            return RenameResult(success: false, output: error, pathMapping: [:])
        }

        // Split into writable (ExifTool can modify) and unwritable (AVI, MPEG).
        // Unwritable files are renamed via FileManager using in-memory metadata.
        let writableInputs = inputs.filter { !isUnwritableVideo($0.url) }
        let unwritableInputs = inputs.filter { isUnwritableVideo($0.url) }

        var allPathMapping: [String: String] = [:]
        var allOutputs: [String] = []
        var allSucceeded = true

        // === Writable files: Use ExifTool 3-pass rename ===
        if !writableInputs.isEmpty {
            let result = renameWritableFiles(writableInputs, progressHandler: progressHandler)
            for (k, v) in result.pathMapping { allPathMapping[k] = v }
            if !result.output.isEmpty { allOutputs.append(result.output) }
            if !result.success { allSucceeded = false }
        }

        // === Unwritable files: Use FileManager with in-memory metadata ===
        if !unwritableInputs.isEmpty {
            let result = renameUnwritableFiles(unwritableInputs)
            for (k, v) in result.pathMapping { allPathMapping[k] = v }
            if !result.output.isEmpty { allOutputs.append(result.output) }
            if !result.success { allSucceeded = false }
        }

        let combinedOutput = allOutputs.joined(separator: "\n")
        return RenameResult(success: allSucceeded, output: combinedOutput, pathMapping: allPathMapping)
    }

    // MARK: - Rename Helpers

    /// Renames writable files using ExifTool's 3-pass approach.
    /// Each pass only processes files not already renamed by a previous pass,
    /// preventing "File not found" errors when a file is renamed in Pass 1
    /// but still listed in the args for Pass 2/3.
    ///
    /// - Parameters:
    ///   - inputs: The file inputs to rename.
    ///   - progressHandler: Optional closure called after each pass with progress
    ///     in [0,1] and a message. progressHandler is called 3 times total:
    ///     at ~0.17 (1/6), ~0.5 (3/6), ~0.83 (5/6).
    private static func renameWritableFiles(_ inputs: [RenameInput],
                                             progressHandler: ((Double, String) -> Void)? = nil) -> RenameResult {
        let descriptionExpr = #"${Description;if($_){s/'\''//g;s/[^\p{L}\p{N}]+/_/g;s/^_+|_+$//g;$_="_ ".$_}}"#
        let dateFmt = ["-d", "%Y_%m_%d_%H%M"]

        // Pass 1: Rename files that have CreateDate (images + QuickTime videos)
        let createDateExpr = #"-FileName<${CreateDate}_%03.c"# + descriptionExpr + #".%e"#
        let fileArgs1 = inputs.map(\.url.path)
        progressHandler?(1.0 / 6.0, "Renaming pass 1/3 (CreateDate)...")
        let pass1 = runWriteTool(with: ["-v", "-m", "-if", "$CreateDate", createDateExpr] + dateFmt + fileArgs1)
        let pass1Renamed = Self.parseRenamedPaths(from: pass1.output)

        // Pass 2: Rename remaining files without CreateDate using DateTimeOriginal
        // (e.g. AVI/RIFF containers which only have RIFF:DateTimeOriginal)
        let remainingAfterPass1 = inputs.filter { !pass1Renamed.keys.contains($0.url.path) }
        let dtoExpr = #"-FileName<${DateTimeOriginal}_%03.c"# + descriptionExpr + #".%e"#
        let fileArgs2 = remainingAfterPass1.map(\.url.path)
        progressHandler?(3.0 / 6.0, "Renaming pass 2/3 (DateTimeOriginal)...")
        let pass2 = runWriteTool(with: ["-v", "-m", "-if", "!$CreateDate&&$DateTimeOriginal", dtoExpr] + dateFmt + fileArgs2)
        let pass2Renamed = Self.parseRenamedPaths(from: pass2.output)

        // Pass 3: Rename remaining files without CreateDate or DateTimeOriginal
        // using FileModifyDate (e.g. MPG/MPEG with no embedded date tags).
        let remainingAfterPass2 = remainingAfterPass1.filter { !pass2Renamed.keys.contains($0.url.path) }
        let fmdExpr = #"-FileName<${FileModifyDate}_%03.c"# + descriptionExpr + #".%e"#
        let fileArgs3 = remainingAfterPass2.map(\.url.path)
        progressHandler?(5.0 / 6.0, "Renaming pass 3/3 (FileModifyDate)...")
        let pass3 = runWriteTool(with: ["-v", "-m", "-if", "!$CreateDate&&!$DateTimeOriginal", fmdExpr] + dateFmt + fileArgs3)
        let pass3Renamed = Self.parseRenamedPaths(from: pass3.output)

        // Merge path mappings from all passes
        var pathMapping: [String: String] = [:]
        for (k, v) in pass1Renamed { pathMapping[k] = v }
        for (k, v) in pass2Renamed { pathMapping[k] = v }
        for (k, v) in pass3Renamed { pathMapping[k] = v }

        let anyOutput = [pass1.output, pass2.output, pass3.output]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let combinedSuccess = pass1.success && pass2.success && pass3.success

        // Fallback: if regex parsing found nothing but a rename succeeded,
        // try to detect new filenames by scanning the directory.
        if pathMapping.isEmpty && !inputs.isEmpty && combinedSuccess {
            for input in inputs {
                let parent = input.url.deletingLastPathComponent()
                if let contents = try? FileManager.default.contentsOfDirectory(at: parent,
                    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    let newURLs = contents.filter { newURL in
                        guard newURL.lastPathComponent != input.url.lastPathComponent else { return false }
                        return !pathMapping.values.contains(newURL.path)
                    }
                    if let newURL = newURLs.first {
                        pathMapping[input.url.path] = newURL.path
                    }
                }
            }
        }

        return RenameResult(success: combinedSuccess, output: anyOutput, pathMapping: pathMapping)
    }

    /// Renames unwritable files (AVI, MPEG) using FileManager and in-memory metadata.
    /// Since ExifTool cannot write to RIFF/AVI or MPEG containers, we generate the
    /// target filename in Swift from the in-memory DateTimeOriginal/Description values
    /// and perform a filesystem rename.
    private static func renameUnwritableFiles(_ inputs: [RenameInput]) -> RenameResult {
        var pathMapping: [String: String] = [:]
        var outputs: [String] = []
        var allSucceeded = true

        // Group by parent directory so the counter is per-directory (matches ExifTool behaviour)
        let grouped = Dictionary(grouping: inputs) { $0.url.deletingLastPathComponent().path }

        for (_, group) in grouped {
            var counter = 0
            for input in group {
                guard !input.dateTimeOriginal.isEmpty else {
                    outputs.append("Skipping \(input.url.lastPathComponent): no date value available.")
                    allSucceeded = false
                    continue
                }

                guard let dateStr = Self.formatDateForRename(input.dateTimeOriginal) else {
                    outputs.append("Skipping \(input.url.lastPathComponent): invalid date format '\(input.dateTimeOriginal)'.")
                    allSucceeded = false
                    continue
                }

                let descStr = Self.sanitizeDescriptionForRename(input.description)
                let ext = input.url.pathExtension
                let parent = input.url.deletingLastPathComponent()

                // Build the new filename: {date}_{counter}{description}.{ext}
                let newFilename = "\(dateStr)_\(String(format: "%03d", counter))\(descStr).\(ext)"
                var finalURL = parent.appendingPathComponent(newFilename)

                // Handle collision by incrementing counter
                var attempts = 0
                while FileManager.default.fileExists(atPath: finalURL.path)
                        && finalURL.path != input.url.path
                        && attempts < 1000 {
                    counter += 1
                    let retryFilename = "\(dateStr)_\(String(format: "%03d", counter))\(descStr).\(ext)"
                    finalURL = parent.appendingPathComponent(retryFilename)
                    attempts += 1
                }

                // Skip if the file is already named correctly
                if finalURL.path == input.url.path {
                    outputs.append("'\(input.url.path)' already named correctly.")
                    counter += 1
                    continue
                }

                do {
                    try FileManager.default.moveItem(at: input.url, to: finalURL)
                    pathMapping[input.url.path] = finalURL.path
                    outputs.append("'\(input.url.path)' -> '\(finalURL.path)'")
                } catch {
                    outputs.append("Error renaming \(input.url.lastPathComponent): \(error.localizedDescription)")
                    allSucceeded = false
                }

                counter += 1
            }
        }

        let combined = outputs.joined(separator: "\n")
        return RenameResult(success: allSucceeded, output: combined, pathMapping: pathMapping)
    }

    /// Parses ExifTool verbose `-v` output for `'old' -> 'new'` rename lines.
    /// ExifTool outputs lines like:
    ///   `'/Volumes/.../file.MOV' --> '/Volumes/.../renamed.MOV'`
    /// The arrow is `-->` (three dashes + greater-than), not `->`.
    private static func parseRenamedPaths(from output: String) -> [String: String] {
        var pathMapping: [String: String] = [:]
        guard !output.isEmpty else { return pathMapping }
        let pattern = #"'([^']+)'\s*-+>\s*'([^']+)'"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsRange = NSRange(output.startIndex..<output.endIndex, in: output)
            let matches = regex.matches(in: output, options: [], range: nsRange)
            for match in matches {
                if match.numberOfRanges == 3,
                   let oldRange = Range(match.range(at: 1), in: output),
                   let newRange = Range(match.range(at: 2), in: output) {
                    pathMapping[String(output[oldRange])] = String(output[newRange])
                }
            }
        }
        return pathMapping
    }

    /// Shared input formatter for parsing ExifTool date strings.
    private static let renameInputFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// Shared output formatter for formatting dates in rename filenames.
    private static let renameOutputFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy_MM_dd_HHMM"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// Formats an ExifTool date string ("yyyy:MM:dd HH:mm:ss") to the rename
    /// date format ("yyyy_MM_dd_HHMM").
    private static func formatDateForRename(_ dateString: String) -> String? {
        guard let date = renameInputFormatter.date(from: dateString) else { return nil }
        return renameOutputFormatter.string(from: date)
    }

    /// Sanitises a description string for use in filenames.
    /// Matches ExifTool's behaviour: removes single quotes, replaces
    /// non-alphanumeric sequences with underscores, trims underscores,
    /// and prepends "_ " if non-empty.
    private static func sanitizeDescriptionForRename(_ desc: String) -> String {
        guard !desc.isEmpty else { return "" }
        var result = desc
        // Remove single quotes
        result = result.replacingOccurrences(of: "'", with: "")
        // Replace sequences of non-letter/non-number characters with underscore
        result = result.replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "_", options: .regularExpression)
        // Remove leading/trailing underscores
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !result.isEmpty else { return "" }
        return "_ \(result)"
    }

    // MARK: - Media Type Helpers

    /// Set of known video file extensions.
    /// Shared across the app — `FileListViewModel` uses this as the single
    /// source of truth for video extension detection (see Design #3).
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm",
        "ts", "mts", "m2ts", "3gp", "3g2", "ogv", "mxf", "mpg", "mpeg"
    ]

    /// Video extensions that use QuickTime containers (MP4/MOV/M4V).
    /// These support `-QuickTime:CreationDate` for date writes.
    private static let quickTimeExtensions: Set<String> = [
        "mp4", "mov", "m4v"
    ]

    /// Video extensions that ExifTool cannot write to (RIFF/AVI, MPEG container limitations).
    /// These files can be read but not modified by ExifTool.
    private static let unwritableVideoExtensions: Set<String> = [
        "avi", "mpg", "mpeg"
    ]

    /// Returns true if the file extension belongs to a video format that ExifTool
    /// cannot write to (e.g. AVI/RIFF containers).
    static func isUnwritableVideo(_ url: URL) -> Bool {
        unwritableVideoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Splits a list of URLs into image, QuickTime video, and other video buckets
    /// based on file extension.
    ///
    /// QuickTime videos (mp4, mov, m4v) use `-QuickTime:CreationDate` for date writes.
    /// Other videos (avi, mkv, wmv, etc.) use generic `-DateTimeOriginal` tags.
    ///
    /// - Parameter urls: The file URLs to split.
    /// - Returns: A tuple of (imageURLs, quickTimeURLs, otherVideoURLs).
    private static func splitByMediaType(_ urls: [URL]) -> (images: [URL], quickTimeVideos: [URL], otherVideos: [URL]) {
        var images: [URL] = []
        var quickTimeVideos: [URL] = []
        var otherVideos: [URL] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if quickTimeExtensions.contains(ext) {
                quickTimeVideos.append(url)
            } else if videoExtensions.contains(ext) {
                otherVideos.append(url)
            } else {
                images.append(url)
            }
        }
        return (images, quickTimeVideos, otherVideos)
    }
}

// MARK: - JSON Decoding

/// Decoding struct for readDateTimeOriginal fallback — needs both
/// DateTimeOriginal and CreateDate to implement the video fallback.
private struct DateTimeFallbackOutput: Decodable {
    let sourceFile: String
    let dateTimeOriginal: String?
    let createDate: String?

    enum CodingKeys: String, CodingKey {
        case sourceFile = "SourceFile"
        case dateTimeOriginal = "DateTimeOriginal"
        case createDate = "CreateDate"
    }
}

/// Internal JSON output shape from ExifTool's `-json` mode.
/// Only fields we care about are decoded; ExifTool may return many more.
///
/// Fields added for video support:
///   - Duration (format: "0:02:30" or seconds for images/videos)
///   - ImageWidth, ImageHeight (pixel dimensions — reported by ExifTool for both images and videos)
private struct FullExifToolOutput: Decodable {
    let sourceFile: String
    let dateTimeOriginal: String?
    let createDate: String?
    let modifyDate: String?
    let fileModifyDate: String?
    let description: String?
    let imageDescription: String?
    let captionAbstract: String?
    let subject: [String]?
    let keywords: [String]?
    let lastKeywordXMP: [String]?
    let duration: String?
    let imageWidth: String?
    let imageHeight: String?

    enum CodingKeys: String, CodingKey {
        case sourceFile = "SourceFile"
        case dateTimeOriginal = "DateTimeOriginal"
        case createDate = "CreateDate"
        case modifyDate = "ModifyDate"
        case fileModifyDate = "FileModifyDate"
        case description = "Description"
        case imageDescription = "ImageDescription"
        case captionAbstract = "Caption-Abstract"
        case subject = "Subject"
        case keywords = "Keywords"
        case lastKeywordXMP = "LastKeywordXMP"
        case duration = "Duration"
        case imageWidth = "ImageWidth"
        case imageHeight = "ImageHeight"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceFile = try container.decode(String.self, forKey: .sourceFile)
        dateTimeOriginal = try container.decodeIfPresent(String.self, forKey: .dateTimeOriginal)
        createDate = try container.decodeIfPresent(String.self, forKey: .createDate)
        modifyDate = try container.decodeIfPresent(String.self, forKey: .modifyDate)
        fileModifyDate = try container.decodeIfPresent(String.self, forKey: .fileModifyDate)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        imageDescription = try container.decodeIfPresent(String.self, forKey: .imageDescription)
        captionAbstract = try container.decodeIfPresent(String.self, forKey: .captionAbstract)
        if let subjects = try? container.decode([String].self, forKey: .subject) {
            subject = subjects
        } else if let subjectString = try? container.decode(String.self, forKey: .subject) {
            subject = [subjectString]
        } else {
            subject = nil
        }
        if let keywordsList = try? container.decode([String].self, forKey: .keywords) {
            keywords = keywordsList
        } else if let keywordString = try? container.decode(String.self, forKey: .keywords) {
            keywords = [keywordString]
        } else {
            keywords = nil
        }
        if let xmpList = try? container.decode([String].self, forKey: .lastKeywordXMP) {
            lastKeywordXMP = xmpList
        } else if let xmpString = try? container.decode(String.self, forKey: .lastKeywordXMP) {
            lastKeywordXMP = [xmpString]
        } else {
            lastKeywordXMP = nil
        }
        // Duration can be a String like "0:02:30" or a number (seconds),
        // so decode generically
        if let durationStr = try? container.decode(String.self, forKey: .duration) {
            duration = durationStr
        } else if let durationNum = try? container.decode(Double.self, forKey: .duration) {
            // Convert seconds to HH:MM:SS format for display
            let hours = Int(durationNum) / 3600
            let minutes = (Int(durationNum) % 3600) / 60
            let seconds = Int(durationNum) % 60
            duration = String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            duration = nil
        }
        if let w = try? container.decode(Int.self, forKey: .imageWidth) {
            imageWidth = "\(w)"
        } else if let w = try? container.decode(String.self, forKey: .imageWidth) {
            imageWidth = w
        } else {
            imageWidth = nil
        }
        if let h = try? container.decode(Int.self, forKey: .imageHeight) {
            imageHeight = "\(h)"
        } else if let h = try? container.decode(String.self, forKey: .imageHeight) {
            imageHeight = h
        } else {
            imageHeight = nil
        }
    }
}