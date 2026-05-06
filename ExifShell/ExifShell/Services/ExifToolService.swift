import Foundation

/// Service for reading and writing image metadata via ExifTool.
/// All metadata logic is delegated to ExifTool — this is just a shell wrapper.
enum ExifToolService {

    // MARK: - ExifTool Path Resolution

    /// Resolved path to the `exiftool` binary.
    /// Searches common installation locations so the app works regardless
    /// of whether it's launched via `swift run`, Xcode, or as a bundled .app.
    /// (Xcode does not inherit your shell PATH, which is the most common
    /// reason for ExifTool to appear missing.)
    private static let exifToolPath: String = {
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
        // Fallback: ask `which` in case it's somewhere unusual.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "exiftool"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !path.isEmpty {
                    return path
                }
            }
        } catch {}
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

        if missingToolError != nil {
            // Return all-nil so callers still get complete results
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as String?) })
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exifToolPath)
        process.arguments = [
            "-json",
            "-DateTimeOriginal"
        ] + urls.map(\.path)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as String?) })
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty else {
                return Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as String?) })
            }

            let json = try decoder.decode([ExifToolOutput].self, from: data)

            // Build lookup by SourceFile (filesystem path)
            var results: [URL: String?] = [:]
            for entry in json {
                let url = URL(fileURLWithPath: entry.sourceFile)
                results[url] = entry.dateTimeOriginal
            }
            // Ensure every input URL has an entry (default to nil if ExifTool skipped it)
            for url in urls {
                if !results.keys.contains(url) {
                    results[url] = nil
                }
            }
            return results
        } catch {
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as String?) })
        }
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
    }

    /// Reads all supported metadata fields from multiple files in a **single** ExifTool invocation.
    ///
    /// - Parameter urls: The file URLs to read from.
    /// - Returns: A dictionary mapping each URL to its FileMetadata.
    static func readAllMetadata(from urls: [URL]) -> [URL: FileMetadata] {
        guard !urls.isEmpty else { return [:] }

        if missingToolError != nil {
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, FileMetadata(
                dateTimeOriginal: nil, createDate: nil, modifyDate: nil,
                description: nil, imageDescription: nil, captionAbstract: nil
            )) })
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exifToolPath)
        process.arguments = [
            "-json",
            "-DateTimeOriginal",
            "-CreateDate",
            "-ModifyDate",
            "-Description",
            "-ImageDescription",
            "-Caption-Abstract"
        ] + urls.map(\.path)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return Dictionary(uniqueKeysWithValues: urls.map { ($0, FileMetadata(
                    dateTimeOriginal: nil, createDate: nil, modifyDate: nil,
                    description: nil, imageDescription: nil, captionAbstract: nil
                )) })
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty else {
                return Dictionary(uniqueKeysWithValues: urls.map { ($0, FileMetadata(
                    dateTimeOriginal: nil, createDate: nil, modifyDate: nil,
                    description: nil, imageDescription: nil, captionAbstract: nil
                )) })
            }

            let json = try decoder.decode([FullExifToolOutput].self, from: data)

            var results: [URL: FileMetadata] = [:]
            for entry in json {
                let url = URL(fileURLWithPath: entry.sourceFile)
                results[url] = FileMetadata(
                    dateTimeOriginal: entry.dateTimeOriginal,
                    createDate: entry.createDate,
                    modifyDate: entry.modifyDate,
                    description: entry.description,
                    imageDescription: entry.imageDescription,
                    captionAbstract: entry.captionAbstract
                )
            }
            for url in urls {
                if !results.keys.contains(url) {
                    results[url] = FileMetadata(
                        dateTimeOriginal: nil, createDate: nil, modifyDate: nil,
                        description: nil, imageDescription: nil, captionAbstract: nil
                    )
                }
            }
            return results
        } catch {
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, FileMetadata(
                dateTimeOriginal: nil, createDate: nil, modifyDate: nil,
                description: nil, imageDescription: nil, captionAbstract: nil
            )) })
        }
    }

    // MARK: - Write (Batch)

    /// Result of a write operation.
    struct WriteResult {
        let success: Bool
        let output: String
    }

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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exifToolPath)

        // Build the tag=value argument. Explicitly target EXIF:DateTimeOriginal
        // to ensure we write the EXIF tag and not a derived/copied variant.
        // Since Process passes each array element as a single argv entry,
        // the space in the value stays intact because it's all one string.
        let tagArg = "-EXIF:DateTimeOriginal=\(value)"

        var args = [
            "-overwrite_original",
            tagArg
        ]
        args.append(contentsOf: urls.map(\.path))
        process.arguments = args

        // Capture both stdout and stderr
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

            let success = process.terminationStatus == 0
            return WriteResult(success: success, output: success ? output : combined)
        } catch {
            return WriteResult(success: false, output: error.localizedDescription)
        }
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exifToolPath)

        var args: [String] = [
            "-overwrite_original",
            "-Description=\(value)",
            "-ImageDescription=\(value)",
            "-Caption-Abstract=\(value)"
        ]
        args.append(contentsOf: urls.map(\.path))
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

            let success = process.terminationStatus == 0
            return WriteResult(success: success, output: success ? output : combined)
        } catch {
            return WriteResult(success: false, output: error.localizedDescription)
        }
    }

    /// Renames files using their metadata according to the pattern:
    /// `{DateTimeOriginal}_{###}_{Description}.{ext}`
    ///
    /// This runs the equivalent of:
    /// ```
    /// exiftool -m "-FileName<${DateTimeOriginal}_%03.c_${Description;...}.%e" \
    ///     -d "%Y_%m_%d_%H%M" <files...>
    /// ```
    ///
    /// - Parameter urls: The file URLs to rename.
    /// - Returns: A WriteResult with success status and captured output/error.
    static func renameFiles(_ urls: [URL]) -> WriteResult {
        guard !urls.isEmpty else {
            return WriteResult(success: false, output: "No files provided.")
        }

        if let error = missingToolError {
            return WriteResult(success: false, output: error)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exifToolPath)

        let expression = #"-FileName<${DateTimeOriginal}_%03.c_${Description;if($_){s/'\''//g;s/[^\p{L}\p{N}]+/_/g;s/^_+|_+$//g}}.%e"#

        let args: [String] = [
            "-m",
            expression,
            "-d",
            "%Y_%m_%d_%H%M"
        ] + urls.map(\.path)
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

            let success = process.terminationStatus == 0
            return WriteResult(success: success, output: success ? output : combined)
        } catch {
            return WriteResult(success: false, output: error.localizedDescription)
        }
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exifToolPath)

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

            let success = process.terminationStatus == 0
            return WriteResult(success: success, output: success ? output : combined)
        } catch {
            return WriteResult(success: false, output: error.localizedDescription)
        }
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

private struct FullExifToolOutput: Decodable {
    let sourceFile: String
    let dateTimeOriginal: String?
    let createDate: String?
    let modifyDate: String?
    let description: String?
    let imageDescription: String?
    let captionAbstract: String?

    enum CodingKeys: String, CodingKey {
        case sourceFile = "SourceFile"
        case dateTimeOriginal = "DateTimeOriginal"
        case createDate = "CreateDate"
        case modifyDate = "ModifyDate"
        case description = "Description"
        case imageDescription = "ImageDescription"
        case captionAbstract = "Caption-Abstract"
    }
}