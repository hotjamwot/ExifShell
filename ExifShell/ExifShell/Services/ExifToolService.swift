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
// Types referenced:
//   - ImageFile (for the data model layer; service is decoupled via URL keys)
//   - FileListViewModel (calls this service, doesn't import it directly)
//   - ExifToolOutput, FullExifToolOutput (private JSON decoders)
//
// Commands used (see AI_CONTEXT.md for full list):
//   Read:    exiftool -json -TAG1 -TAG2 <files...>
//   Write:   exiftool -overwrite_original -TAG=VALUE <files...>
//   Sanitise: exiftool [...] '-DateTimeOriginal<${...}' <files...>
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
            // still producing valid JSON on stdout. We trust stdout data.
            return ReadResult(success: process.terminationStatus == 0, stdoutData: data)
        } catch {
            return ReadResult(success: false, stdoutData: Data())
        }
    }

    /// Runs exiftool for a **write** operation (captures both stdout and stderr
    /// as text for error reporting).
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

            return WriteResult(success: process.terminationStatus == 0, output: combined)
        } catch {
            return WriteResult(success: false, output: error.localizedDescription)
        }
    }

    /// Creates an empty FileMetadata value (all nil) for use as error/default sentinel.
    private static func emptyMetadata() -> FileMetadata {
        FileMetadata(
            dateTimeOriginal: nil, createDate: nil, modifyDate: nil,
            description: nil, imageDescription: nil, captionAbstract: nil, subject: nil,
            keywords: nil, lastKeywordXMP: nil
        )
    }

    // MARK: - Read

    /// Reads `DateTimeOriginal` from a single file using `exiftool -json`.
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
    /// - Parameter urls: The file URLs to read from.
    /// - Returns: A dictionary mapping each URL to its DateTimeOriginal (or nil if missing/error).
    static func readDateTimeOriginal(from urls: [URL]) -> [URL: String?] {
        guard !urls.isEmpty else { return [:] }
        guard missingToolError == nil else {
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as String?) })
        }

        let result = runReadTool(with: ["-json", "-DateTimeOriginal"] + urls.map(\.path))
        guard !result.stdoutData.isEmpty,
              let json = try? decoder.decode([ExifToolOutput].self, from: result.stdoutData) else {
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as String?) })
        }

        var results: [URL: String?] = [:]
        for entry in json {
            results[URL(fileURLWithPath: entry.sourceFile)] = entry.dateTimeOriginal
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
    }

    /// Reads all supported metadata fields from multiple files in a **single** ExifTool invocation.
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
            "-Description",
            "-ImageDescription",
            "-Caption-Abstract",
            "-Subject",
            "-Keywords",
            "-LastKeywordXMP"
        ] + urls.map(\.path)

        let result = runReadTool(with: args)

        // If stdout is empty but we had no error, all files simply have no metadata
        guard !result.stdoutData.isEmpty,
              let json = try? decoder.decode([FullExifToolOutput].self, from: result.stdoutData) else {
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, emptyMetadata()) })
        }

        var results: [URL: FileMetadata] = [:]
        for entry in json {
            let url = URL(fileURLWithPath: entry.sourceFile)
            results[url] = FileMetadata(
                dateTimeOriginal: entry.dateTimeOriginal,
                createDate: entry.createDate,
                modifyDate: entry.modifyDate,
                description: entry.description,
                imageDescription: entry.imageDescription,
                captionAbstract: entry.captionAbstract,
                subject: entry.subject?.joined(separator: ", "),
                keywords: entry.keywords?.joined(separator: ", "),
                lastKeywordXMP: entry.lastKeywordXMP?.joined(separator: ", ")
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

    /// Writes `DateTimeOriginal` to one or more files in a single ExifTool call.
    ///
    /// Important: ExifTool expects arguments in the form `-TAGNAME=VALUE`.
    /// When the VALUE contains spaces, we must pass it as a single `argv` entry
    /// with the value properly quoted inside the argument string.
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

        // Build the tag=value argument. Explicitly target EXIF:DateTimeOriginal
        // to ensure we write the EXIF tag and not a derived/copied variant.
        let tagArg = "-EXIF:DateTimeOriginal=\(value)"
        // -m ignores minor errors/warnings like MakerNotes offset issues,
        // so one file with a non-critical warning doesn't block the whole batch.
        let args = ["-overwrite_original", "-m", tagArg] + urls.map(\.path)
        return runWriteTool(with: args)
    }

    /// Writes a description value to all description-related EXIF tags
    /// (Description, ImageDescription, Caption-Abstract) in a single ExifTool call.
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

        // -m ignores minor errors/warnings like MakerNotes offset issues,
        // so one file with a non-critical warning doesn't block the whole batch.
        let args = [
            "-overwrite_original",
            "-m",
            "-Description=\(value)",
            "-ImageDescription=\(value)",
            "-Caption-Abstract=\(value)"
        ] + urls.map(\.path)
        return runWriteTool(with: args)
    }

    /// Result of a rename operation, including a mapping of old path → new path.
    struct RenameResult {
        let success: Bool
        let output: String
        /// Maps each original file path to its new path after renaming.
        /// Only populated on success — empty on failure.
        let pathMapping: [String: String]
    }

    /// Renames files using their metadata according to the pattern:
    /// `{DateTimeOriginal}_{###}_{Description}.{ext}`
    ///
    /// This runs the equivalent of:
    /// ```
    /// exiftool -v -m "-FileName<${DateTimeOriginal}_%03.c_${Description;...}.%e" \
    ///     -d "%Y_%m_%d_%H%M" <files...>
    /// ```
    ///
    /// With `-v` (verbose) ExifTool outputs lines like:
    /// `'old/path/file.jpg' -> 'new/path/file.jpg'`
    /// which we parse to build the path mapping for the caller.
    ///
    /// - Parameter urls: The file URLs to rename.
    /// - Returns: A RenameResult with success status, output, and a path mapping.
    static func renameFiles(_ urls: [URL]) -> RenameResult {
        guard !urls.isEmpty else {
            return RenameResult(success: false, output: "No files provided.", pathMapping: [:])
        }
        if let error = missingToolError {
            return RenameResult(success: false, output: error, pathMapping: [:])
        }

        let expression = #"-FileName<${DateTimeOriginal}_%03.c_${Description;if($_){s/'\''//g;s/[^\p{L}\p{N}]+/_/g;s/^_+|_+$//g}}.%e"#
        let args = ["-v", "-m", expression, "-d", "%Y_%m_%d_%H%M"] + urls.map(\.path)
        let writeResult = runWriteTool(with: args)

        // Parse verbose output for "old_path -> new_path" lines
        var pathMapping: [String: String] = [:]
        if writeResult.success {
            let pattern = #"'([^']+)'\s*->\s*'([^']+)'"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let nsRange = NSRange(writeResult.output.startIndex..<writeResult.output.endIndex, in: writeResult.output)
                let matches = regex.matches(in: writeResult.output, options: [], range: nsRange)
                for match in matches {
                    if match.numberOfRanges == 3,
                       let oldRange = Range(match.range(at: 1), in: writeResult.output),
                       let newRange = Range(match.range(at: 2), in: writeResult.output) {
                        pathMapping[String(writeResult.output[oldRange])] = String(writeResult.output[newRange])
                    }
                }
            }

            // Fallback: if regex parsing found nothing but rename succeeded,
            // try to detect new filenames by scanning the directory.
            if pathMapping.isEmpty && !urls.isEmpty {
                for originalURL in urls {
                    let parent = originalURL.deletingLastPathComponent()
                    if let contents = try? FileManager.default.contentsOfDirectory(at: parent,
                        includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        let newURLs = contents.filter { newURL in
                            guard newURL.lastPathComponent != originalURL.lastPathComponent else { return false }
                            return !pathMapping.values.contains(newURL.path)
                        }
                        if let newURL = newURLs.first {
                            pathMapping[originalURL.path] = newURL.path
                        }
                    }
                }
            }
        }

        return RenameResult(success: writeResult.success, output: writeResult.output, pathMapping: pathMapping)
    }

    /// Runs a full sanitise on the given files:
    ///   - Normalises DateTimeOriginal format
    ///   - Copies DateTimeOriginal → CreateDate, ModifyDate
    ///   - Clears OffsetTime, OffsetTimeOriginal, OffsetTimeDigitized
    ///   - Copies Description → ImageDescription, Caption-Abstract
    ///
    /// This is equivalent to the user's shell command:
    /// ```
    /// exiftool -overwrite_original \
    ///   '-DateTimeOriginal<${DateTimeOriginal;DateFmt("%Y:%m:%d %H:%M:%S")}' \
    ///   '-CreateDate<DateTimeOriginal' \
    ///   '-ModifyDate<DateTimeOriginal' \
    ///   -OffsetTime= \
    ///   -OffsetTimeOriginal= \
    ///   -OffsetTimeDigitized= \
    ///   '-ImageDescription<Description' \
    ///   '-Caption-Abstract<Description' \
    ///   <files...>
    /// ```
    ///
    /// - Parameter urls: The file URLs to sanitise.
    /// - Returns: A WriteResult with success status and captured output/error.
    static func sanitise(_ urls: [URL]) -> WriteResult {
        guard !urls.isEmpty else {
            return WriteResult(success: false, output: "No files provided.")
        }
        if let error = missingToolError {
            return WriteResult(success: false, output: error)
        }

        let args: [String] = [
            "-overwrite_original",
            #"-DateTimeOriginal<${DateTimeOriginal;DateFmt("%Y:%m:%d %H:%M:%S")}"#,
            "-CreateDate<DateTimeOriginal",
            "-ModifyDate<DateTimeOriginal",
            "-OffsetTime=",
            "-OffsetTimeOriginal=",
            "-OffsetTimeDigitized=",
            "-ImageDescription<Description",
            "-Caption-Abstract<Description"
        ] + urls.map(\.path)
        return runWriteTool(with: args)
    }
}

// MARK: - JSON Decoding

private struct ExifToolOutput: Decodable {
    let sourceFile: String
    let dateTimeOriginal: String?

    enum CodingKeys: String, CodingKey {
        case sourceFile = "SourceFile"
        case dateTimeOriginal = "DateTimeOriginal"
    }
}

/// Internal JSON output shape from ExifTool's `-json` mode.
/// Only fields we care about are decoded; ExifTool may return many more.
private struct FullExifToolOutput: Decodable {
    let sourceFile: String
    let dateTimeOriginal: String?
    let createDate: String?
    let modifyDate: String?
    let description: String?
    let imageDescription: String?
    let captionAbstract: String?
    let subject: [String]?
    let keywords: [String]?
    let lastKeywordXMP: [String]?

    enum CodingKeys: String, CodingKey {
        case sourceFile = "SourceFile"
        case dateTimeOriginal = "DateTimeOriginal"
        case createDate = "CreateDate"
        case modifyDate = "ModifyDate"
        case description = "Description"
        case imageDescription = "ImageDescription"
        case captionAbstract = "Caption-Abstract"
        case subject = "Subject"
        case keywords = "Keywords"
        case lastKeywordXMP = "LastKeywordXMP"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceFile = try container.decode(String.self, forKey: .sourceFile)
        dateTimeOriginal = try container.decodeIfPresent(String.self, forKey: .dateTimeOriginal)
        createDate = try container.decodeIfPresent(String.self, forKey: .createDate)
        modifyDate = try container.decodeIfPresent(String.self, forKey: .modifyDate)
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
    }
}