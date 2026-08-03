import Foundation

// ============================================================================
// ExifToolService + Rename
// ============================================================================
// Extension containing all rename-related functionality. Separated from the
// core ExifToolService so the main file (<800 lines) stays focused on
// read/write/sanitise operations and shared infrastructure.
//
// Contains:
//   - RenameResult, RenameInput (public types)
//   - renameFiles()              — public entry point
//   - renameWritableFiles()       — ExifTool-based rename for supported formats
//   - renameUnwritableFiles()     — FileManager-based rename for AVI/MPEG
//   - detectTagCategories()       — pre-sorts files by tag availability
//   - computeExpectedRenameURL()  — fallback path mapping computation
//   - parseRenamedPaths()         — regex parser for ExifTool -v output
//   - DateTagCategory             — enum for pre-sort categories
//   - renameInputFormatter / renameOutputFormatter / formatDateForRename
//   - sanitizeDescriptionForRename()
// ============================================================================

extension ExifToolService {

    // MARK: - Rename

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
    /// Instead of running 3 blind ExifTool passes (filtered by `-if`), we first
    /// detect which files have which tags via a single ExifTool read, then
    /// dispatch **only** the passes needed. For a batch where every file has
    /// CreateDate (the common case), this means 1 ExifTool process instead of 3.
    ///
    /// Path mapping is built from ExifTool's `-v` output and validated against
    /// the filesystem. Unwritable formats (AVI, MPEG) are renamed via FileManager
    /// using in-memory metadata, since ExifTool cannot write to those containers.
    ///
    /// - Parameters:
    ///   - inputs: The file inputs (URL + metadata) to rename.
    ///   - progressHandler: Optional closure called after each pass with progress
    ///     in [0,1] and a message describing the current pass.
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

    /// Groups writable files by which date tag is available on disk.
    ///
    /// Runs a single ExifTool read to detect whether each file has
    /// `CreateDate`, `DateTimeOriginal`, or neither (→ `FileModifyDate`).
    /// This lets the rename pipeline dispatch only the passes that are
    /// actually needed, instead of blindly running all 3 passes for every batch.
    ///
    /// - Parameter inputs: The file inputs to classify.
    /// - Returns: A dictionary grouping file inputs by their date tag category.
    private static func detectTagCategories(_ inputs: [RenameInput]) -> [DateTagCategory: [RenameInput]] {
        let urls = inputs.map(\.url)
        let result = runReadTool(with: ["-json", "-CreateDate", "-DateTimeOriginal"] + urls.map(\.path))

        // If the read failed for any reason, fall back to treating all files
        // as CreateDate — this means the rename will work as it always has,
        // just without the optimisation.
        guard !result.stdoutData.isEmpty,
              let json = try? decoder.decode([DateTimeFallbackOutput].self, from: result.stdoutData) else {
            return [.createDate: inputs]
        }

        // Build a path-keyed lookup from inputs
        let pathLookup: [String: RenameInput] = Dictionary(uniqueKeysWithValues: inputs.map {
            ($0.url.standardizedFileURL.path, $0)
        })

        var grouped: [DateTagCategory: [RenameInput]] = [:]

        for entry in json {
            let entryPath = (entry.sourceFile as NSString).standardizingPath
            guard let input = pathLookup[entryPath] else { continue }

            let category: DateTagCategory
            if let cd = entry.createDate, !cd.isEmpty {
                category = .createDate
            } else if let dto = entry.dateTimeOriginal, !dto.isEmpty {
                category = .dateTimeOriginal
            } else {
                category = .fileModifyDate
            }
            grouped[category, default: []].append(input)
        }

        return grouped
    }

    /// Which date tag to use as the source for a file's rename filename.
    private enum DateTagCategory: String {
        case createDate
        case dateTimeOriginal
        case fileModifyDate
    }

    /// Renames writable files using ExifTool, with passes tuned to only the
    /// tag categories that actually exist in the input batch.
    ///
    /// Instead of always running 3 blind passes (filtered by `-if`), we first
    /// detect which files have which tags via a single ExifTool read, then
    /// dispatch **only** the passes needed. For a batch where every file has
    /// CreateDate (the common case), this means 1 ExifTool process instead of 3.
    ///
    /// Path mapping is built from ExifTool's `-v` output and validated against
    /// the filesystem. If regex parsing misses a mapping (unlikely with stable
    /// ExifTool output), the expected filename is computed in Swift as a fallback.
    ///
    /// - Parameters:
    ///   - inputs: The file inputs to rename.
    ///   - progressHandler: Optional closure called after each pass with progress
    ///     in [0,1] and a message. progressHandler is called once per active pass,
    ///     so e.g. 2 passes gives calls at ~0.25 and ~0.75.
    private static func renameWritableFiles(_ inputs: [RenameInput],
                                             progressHandler: ((Double, String) -> Void)? = nil) -> RenameResult {
        // Regular images use the Description shortcut (resolves to EXIF/IPTC/XMP).
        // HEIC/HEIF files must use XMP-dc:Description explicitly because the
        // Description shortcut can resolve to an empty EXIF:ImageDescription
        // when the HEIC has an EXIF block, producing files without the description
        // in the renamed filename.
        let descriptionExpr = #"${Description;if($_){s/'\''//g;s/[^\p{L}\p{N}]+/_/g;s/^_+|_+$//g;$_="_".$_}}"#
        let xmpDescriptionExpr = #"${XMP-dc:Description;if($_){s/'\''//g;s/[^\p{L}\p{N}]+/_/g;s/^_+|_+$//g;$_="_".$_}}"#
        let dateFmt = ["-d", "%Y_%m_%d_%H%M"]

        // Step 1: Detect which tag category each file falls into, so we only
        // run passes for groups that actually have files.
        let categories = detectTagCategories(inputs)
        let totalActivePasses = categories.count
        var passIndex = 0

        var pathMapping: [String: String] = [:]
        var allOutputs: [String] = []
        var allSucceeded = true

        // Mapping from tag category → ExifTool date tag variable and progress label
        let passConfig: [(category: DateTagCategory, tag: String, label: String)] = [
            (.createDate,       "CreateDate",        "CreateDate"),
            (.dateTimeOriginal, "DateTimeOriginal",  "DateTimeOriginal"),
            (.fileModifyDate,   "FileModifyDate",    "FileModifyDate"),
        ]

        for (category, tag, label) in passConfig {
            guard let categoryInputs = categories[category], !categoryInputs.isEmpty else { continue }

            // Split HEIC/HEIF out of the category — they need XMP-dc:Description
            // instead of the ambiguous Description shortcut.
            let heicCategoryInputs = categoryInputs.filter { isHEIC($0.url) }
            let regularCategoryInputs = categoryInputs.filter { !isHEIC($0.url) }

            // Run the pass for regular files (if any) using the Description shortcut.
            if !regularCategoryInputs.isEmpty {
                passIndex += 1
                let expr = #"-FileName<${"# + tag + #"}_%03.c"# + descriptionExpr + #".%e"#
                let passResult = Self.runRenamePass(
                    expr: expr,
                    dateFmt: dateFmt,
                    inputs: regularCategoryInputs,
                    label: label,
                    passIndex: passIndex,
                    totalPasses: totalActivePasses,
                    progressHandler: progressHandler
                )
                for (k, v) in passResult.validatedMapping { pathMapping[k] = v }
                if !passResult.output.isEmpty { allOutputs.append(passResult.output) }
                if !passResult.success { allSucceeded = false }
            }

            // Run the pass for HEIC files (if any) using XMP-dc:Description.
            if !heicCategoryInputs.isEmpty {
                passIndex += 1
                let expr = #"-FileName<${"# + tag + #"}_%03.c"# + xmpDescriptionExpr + #".%e"#
                let passResult = Self.runRenamePass(
                    expr: expr,
                    dateFmt: dateFmt,
                    inputs: heicCategoryInputs,
                    label: "\(label) (HEIC)",
                    passIndex: passIndex,
                    totalPasses: totalActivePasses,
                    progressHandler: progressHandler
                )
                for (k, v) in passResult.validatedMapping { pathMapping[k] = v }
                if !passResult.output.isEmpty { allOutputs.append(passResult.output) }
                if !passResult.success { allSucceeded = false }
            }
        }

        let combinedOutput = allOutputs.joined(separator: "\n")
        return RenameResult(success: allSucceeded, output: combinedOutput, pathMapping: pathMapping)
    }

    /// Runs a single rename pass for a group of files sharing the same expression.
    /// Validates the parsed path mapping against the filesystem and computes
    /// Swift-side fallback mappings when regex parsing misses a rename.
    private static func runRenamePass(
        expr: String,
        dateFmt: [String],
        inputs: [RenameInput],
        label: String,
        passIndex: Int,
        totalPasses: Int,
        progressHandler: ((Double, String) -> Void)?
    ) -> (validatedMapping: [String: String], output: String, success: Bool) {
        let fileArgs = inputs.map(\.url.path)

        progressHandler?(
            Double(passIndex - 1) / Double(max(totalPasses, 1)),
            "Renaming pass \(passIndex)/\(totalPasses) (\(label))..."
        )

        let passResult = runWriteTool(with: ["-v", "-m", expr] + dateFmt + fileArgs)
        let passRenamed = Self.parseRenamedPaths(from: passResult.output)

        // Validate: every claimed new path must actually exist on disk.
        // Remove mappings where the target file doesn't exist (regex false positive).
        var validatedMapping: [String: String] = [:]
        for (oldPath, newPath) in passRenamed {
            if FileManager.default.fileExists(atPath: newPath) {
                validatedMapping[oldPath] = newPath
            }
        }

        // For files in this group whose old path is not in the validated
        // mapping (regex failed or path was invalid), compute the expected
        // new filename in Swift and check if it exists on disk.
        for input in inputs {
            guard !validatedMapping.keys.contains(input.url.path) else { continue }
            // If the old path still exists, the file was not renamed — skip it
            guard !FileManager.default.fileExists(atPath: input.url.path) else { continue }

            if let expectedURL = computeExpectedRenameURL(for: input, tag: "") {
                if FileManager.default.fileExists(atPath: expectedURL.path) {
                    validatedMapping[input.url.path] = expectedURL.path
                }
            }
        }

        return (validatedMapping, passResult.output, passResult.success)
    }

    /// Computes the expected rename destination URL for a file by using the
    /// in-memory DateTimeOriginal value (which was synced to all tags during
    /// Save) and replicating ExifTool's naming pattern `${Tag}_{###}{description}.{ext}`
    /// with a per-directory counter.
    ///
    /// ExifTool assigns counters starting from 0 per directory in the order
    /// files appear in the arguments. We replicate this by reading existing
    /// files in the directory that match the expected pattern to determine
    /// what the counter would be for this file.
    ///
    /// - Parameters:
    ///   - input: The file rename input.
    ///   - tag: The ExifTool tag name (unused — date comes from in-memory value).
    /// - Returns: The expected destination URL, or nil if it can't be computed.
    private static func computeExpectedRenameURL(for input: RenameInput, tag: String) -> URL? {
        // Parse in-memory date using the same format as ExifTool's `-d` option.
        let dateValue: String
        if let formattedDate = Self.formatDateForRename(input.dateTimeOriginal) {
            dateValue = formattedDate
        } else {
            return nil
        }

        let parent = input.url.deletingLastPathComponent()
        let ext = input.url.pathExtension
        let descStr = Self.sanitizeDescriptionForRename(input.description)

        // Build a regex to count existing files that match the expected pattern
        // for this date+description+extension combination.
        let escapedDate = NSRegularExpression.escapedPattern(for: dateValue)
        let escapedDesc = NSRegularExpression.escapedPattern(for: descStr)
        let escapedExt = NSRegularExpression.escapedPattern(for: ext)
        let pattern = "^\(escapedDate)_\\d{3}\(escapedDesc)\\.\(escapedExt)$"

        let counter: Int
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let existingFiles = (try? FileManager.default.contentsOfDirectory(at: parent,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            counter = existingFiles.filter { url in
                let name = url.lastPathComponent
                return regex.firstMatch(in: name, options: [],
                    range: NSRange(location: 0, length: name.utf16.count)) != nil
            }.count
        } else {
            counter = 0
        }

        let newFilename = "\(dateValue)_\(String(format: "%03d", counter))\(descStr).\(ext)"
        return parent.appendingPathComponent(newFilename)
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
    /// and prepends "_" if non-empty.
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
        return "_\(result)"
    }
}