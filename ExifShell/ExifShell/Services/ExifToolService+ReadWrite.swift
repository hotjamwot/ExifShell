import Foundation

// ============================================================================
// ExifToolService + Read/Write
// ============================================================================
// Extension containing all read and write metadata operations, plus
// sanitise. Separated from the core ExifToolService so the main file
// stays focused on infrastructure (path resolution, process runners,
// result types).
//
// Contains:
//   - FileMetadata / DateSource        — result types for metadata reads
//   - readDateTimeOriginal()           — single-file and batch reads
//   - readAllMetadata()                — full metadata batch read
//   - writeDateTimeOriginal()          — batch date write (images + videos)
//   - writeDescription()               — batch description write
//   - sanitise()                       — normalise date formats
//   - DateTimeFallbackOutput           — JSON decoder for readDateTimeOriginal
//   - FullExifToolOutput               — JSON decoder for readAllMetadata
//
// Types consumed:
//   - ExifToolService (ExifShell/Services/ExifToolService.swift)
//
// Used by:
//   - FileListViewModel (ExifShell/ViewModels/FileListViewModel.swift)
// ============================================================================

extension ExifToolService {

    // MARK: - FileMetadata / DateSource

    /// A bundle of all metadata fields we care about for a single file.
    struct FileMetadata {
        let dateTimeOriginal: String?
        let createDate: String?
        let modifyDate: String?
        let description: String?
        let imageDescription: String?
        let captionAbstract: String?
        /// The XMP Dublin Core description (e.g. `XMP-dc:Description`).
        /// HEIC/HEIF files store descriptions here rather than in EXIF ImageDescription.
        let xmpDescription: String?
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
        /// Camera make (e.g. "Apple", "FUJIFILM", "Canon").
        let cameraMake: String?
        /// Camera model (e.g. "iPhone 15 Pro", "X-T3", "DIGITAL IXUS v").
        let cameraModel: String?
        /// The actual file type detected by ExifTool (e.g. "JPEG", "HEIC", "PNG").
        /// Used to detect files whose suffix doesn't match their real content type.
        let fileType: String?
        /// The correct file extension for the actual content type (e.g. "jpg").
        /// Used to detect suffix mismatches and suggest corrections.
        let fileTypeExtension: String?
    }

    /// Indicates which ExifTool tag provided the dateTimeOriginal value.
    enum DateSource: String {
        case dateTimeOriginal
        case createDate
        case fileModifyDate
    }

    // MARK: - JSON Decoding

    /// Creates an empty FileMetadata value (all nil) for use as error/default sentinel.
    static func emptyMetadata() -> FileMetadata {
        FileMetadata(
            dateTimeOriginal: nil, createDate: nil, modifyDate: nil,
            description: nil, imageDescription: nil, captionAbstract: nil, xmpDescription: nil, subject: nil,
            keywords: nil, lastKeywordXMP: nil,
            duration: nil, imageWidth: nil, imageHeight: nil,
            fileModifyDate: nil, dateSource: nil,
            cameraMake: nil, cameraModel: nil,
            fileType: nil, fileTypeExtension: nil
        )
    }


    /// Decoding struct for readDateTimeOriginal fallback — needs both
    /// DateTimeOriginal and CreateDate to implement the video fallback.
    struct DateTimeFallbackOutput: Decodable {
        let sourceFile: String
        let dateTimeOriginal: String?
        let createDate: String?
        let quickTimeCreationDate: String?

        enum CodingKeys: String, CodingKey {
            case sourceFile = "SourceFile"
            case dateTimeOriginal = "DateTimeOriginal"
            case createDate = "CreateDate"
            case quickTimeCreationDate = "CreationDate"
        }
    }

    /// Internal JSON output shape from ExifTool's `-json` mode.
    /// Only fields we care about are decoded; ExifTool may return many more.
    ///
    /// Simple string fields use auto-synthesised Codable via `Core`.
    /// Fields with multiple possible types (String-or-array, String-or-number)
    /// are decoded manually via property wrappers.
    struct FullExifToolOutput: Decodable {
        // MARK: - Auto-synthesised fields
        struct Core: Decodable {
            let sourceFile: String
            let dateTimeOriginal: String?
            let createDate: String?
            let modifyDate: String?
            let fileModifyDate: String?
            let description: String?
            let imageDescription: String?
            let captionAbstract: String?
            let xmpDescription: String?
            let quickTimeCreationDate: String?
            let cameraMake: String?
            let cameraModel: String?
            let quickTimeMake: String?
            let quickTimeModel: String?
            let fileType: String?
            let fileTypeExtension: String?

            enum CodingKeys: String, CodingKey {
                case sourceFile = "SourceFile"
                case dateTimeOriginal = "DateTimeOriginal"
                case createDate = "CreateDate"
                case modifyDate = "ModifyDate"
                case fileModifyDate = "FileModifyDate"
                case description = "Description"
                case imageDescription = "ImageDescription"
                case captionAbstract = "Caption-Abstract"
                case xmpDescription = "XMP-dc:Description"
                case quickTimeCreationDate = "CreationDate"
                case cameraMake = "Make"
                case cameraModel = "Model"
                case quickTimeMake = "QuickTime:Make"
                case quickTimeModel = "QuickTime:Model"
                case fileType = "FileType"
                case fileTypeExtension = "FileTypeExtension"
            }
        }

        /// Decodes either a `[String]` or a single flat `String`.
        @FlexibleStringArray var subject: [String]?
        @FlexibleStringArray var keywords: [String]?
        @FlexibleStringArray var lastKeywordXMP: [String]?

        /// Decodes either a `String` or a `Double` (seconds → HH:MM:SS).
        @FlexibleDuration var duration: String?

        /// Decodes either an `Int` or a `String`.
        @FlexibleString var imageWidth: String?
        @FlexibleString var imageHeight: String?

        let core: Core

        private enum CodingKeys: String, CodingKey {
            case subject = "Subject"
            case keywords = "Keywords"
            case lastKeywordXMP = "LastKeywordXMP"
            case duration = "Duration"
            case imageWidth = "ImageWidth"
            case imageHeight = "ImageHeight"
        }

        init(from decoder: Decoder) throws {
            self.core = try Core(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            _subject = try container.decodeIfPresent(FlexibleStringArray.self, forKey: .subject)
                ?? FlexibleStringArray(wrappedValue: nil)
            _keywords = try container.decodeIfPresent(FlexibleStringArray.self, forKey: .keywords)
                ?? FlexibleStringArray(wrappedValue: nil)
            _lastKeywordXMP = try container.decodeIfPresent(FlexibleStringArray.self, forKey: .lastKeywordXMP)
                ?? FlexibleStringArray(wrappedValue: nil)
            _duration = try container.decodeIfPresent(FlexibleDuration.self, forKey: .duration)
                ?? FlexibleDuration(wrappedValue: nil)
            _imageWidth = try container.decodeIfPresent(FlexibleString.self, forKey: .imageWidth)
                ?? FlexibleString(wrappedValue: nil)
            _imageHeight = try container.decodeIfPresent(FlexibleString.self, forKey: .imageHeight)
                ?? FlexibleString(wrappedValue: nil)
        }
    }

    // MARK: - Flexible Decoding Property Wrappers

    /// Decodes `[String]?` from either a `[String]` JSON array or a flat `String`.
    @propertyWrapper
    struct FlexibleStringArray: Decodable {
        var wrappedValue: [String]?

        init(wrappedValue: [String]?) {
            self.wrappedValue = wrappedValue
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let array = try? container.decode([String].self) {
                wrappedValue = array
            } else if let single = try? container.decode(String.self) {
                wrappedValue = [single]
            } else {
                wrappedValue = nil
            }
        }
    }

    /// Decodes `String?` from either a `String` value or an `Int`.
    @propertyWrapper
    struct FlexibleString: Decodable {
        var wrappedValue: String?

        init(wrappedValue: String?) {
            self.wrappedValue = wrappedValue
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self) {
                wrappedValue = str
            } else if let int = try? container.decode(Int.self) {
                wrappedValue = "\(int)"
            } else {
                wrappedValue = nil
            }
        }
    }

    /// Decodes `String?` from either a `String` (e.g. "0:02:30") or
    /// a `Double` (seconds) which gets converted to HH:MM:SS format.
    @propertyWrapper
    struct FlexibleDuration: Decodable {
        var wrappedValue: String?

        init(wrappedValue: String?) {
            self.wrappedValue = wrappedValue
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self) {
                wrappedValue = str
            } else if let num = try? container.decode(Double.self) {
                let hours = Int(num) / 3600
                let minutes = (Int(num) % 3600) / 60
                let seconds = Int(num) % 60
                wrappedValue = String(format: "%d:%02d:%02d", hours, minutes, seconds)
            } else {
                wrappedValue = nil
            }
        }
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

        let result = runReadTool(with: ["-json", "-DateTimeOriginal", "-CreateDate", "-QuickTime:CreationDate"] + urls.map(\.path))
        guard !result.stdoutData.isEmpty,
              let json = try? decoder.decode([DateTimeFallbackOutput].self, from: result.stdoutData) else {
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, nil as String?) })
        }

        let pathLookup: [String: URL] = Dictionary(uniqueKeysWithValues: urls.map {
            ($0.standardizedFileURL.path, $0)
        })

        var results: [URL: String?] = [:]
        for entry in json {
            let entryPath = (entry.sourceFile as NSString).standardizingPath
            if let originalURL = pathLookup[entryPath] {
                let rawDate = entry.quickTimeCreationDate ?? entry.dateTimeOriginal ?? entry.createDate
                results[originalURL] = rawDate.flatMap(ExifToolService.normalizeToExifDate)
            }
        }
        for url in urls {
            if !results.keys.contains(url) { results[url] = nil }
        }
        return results
    }

    // MARK: - Full Metadata Read (Batch)

    /// The list of ExifTool tags requested in `readAllMetadata`.
    /// Extracted to a static let so the tag set is visible in one place
    /// and not re-allocated on every import batch.
    private static let readAllTags: [String] = [
        "-json",
        "-DateTimeOriginal",
        "-QuickTime:CreationDate",
        "-CreateDate",
        "-ModifyDate",
        "-FileModifyDate",
        "-Description",
        "-ImageDescription",
        "-Caption-Abstract",
        "-XMP-dc:Description",
        "-Subject",
        "-Keywords",
        "-LastKeywordXMP",
        "-Duration",
        "-ImageWidth",
        "-ImageHeight",
        "-Make",
        "-Model",
        "-QuickTime:Make",
        "-QuickTime:Model",
        "-FileType",
        "-FileTypeExtension"
    ]

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

        let result = runReadTool(with: Self.readAllTags + urls.map(\.path))

        guard !result.stdoutData.isEmpty,
              let json = try? decoder.decode([FullExifToolOutput].self, from: result.stdoutData) else {
            return Dictionary(uniqueKeysWithValues: urls.map { ($0, emptyMetadata()) })
        }

        let pathLookup: [String: URL] = Dictionary(uniqueKeysWithValues: urls.map {
            ($0.standardizedFileURL.path, $0)
        })

        var results: [URL: FileMetadata] = [:]
        for entry in json {
            let entryPath = (entry.core.sourceFile as NSString).standardizingPath
            guard let originalURL = pathLookup[entryPath] else { continue }
            let dateSource: ExifToolService.DateSource?
            let dto: String?
            if let qtcValue = entry.core.quickTimeCreationDate {
                dto = ExifToolService.normalizeToExifDate(qtcValue)
                dateSource = .dateTimeOriginal
            } else if let dtoValue = entry.core.dateTimeOriginal {
                dto = ExifToolService.normalizeToExifDate(dtoValue)
                dateSource = .dateTimeOriginal
            } else if let cdValue = entry.core.createDate {
                dto = ExifToolService.normalizeToExifDate(cdValue)
                dateSource = .createDate
            } else if let fmdValue = entry.core.fileModifyDate {
                dto = ExifToolService.normalizeToExifDate(fmdValue)
                dateSource = .fileModifyDate
            } else {
                dto = nil
                dateSource = nil
            }
            results[originalURL] = FileMetadata(
                dateTimeOriginal: dto,
                createDate: entry.core.createDate,
                modifyDate: entry.core.modifyDate,
                description: entry.core.description,
                imageDescription: entry.core.imageDescription,
                captionAbstract: entry.core.captionAbstract,
                xmpDescription: entry.core.xmpDescription,
                subject: entry.subject?.joined(separator: ", "),
                keywords: entry.keywords?.joined(separator: ", "),
                lastKeywordXMP: entry.lastKeywordXMP?.joined(separator: ", "),
                duration: entry.duration,
                imageWidth: entry.imageWidth,
                imageHeight: entry.imageHeight,
                fileModifyDate: entry.core.fileModifyDate,
                dateSource: dateSource,
                cameraMake: entry.core.cameraMake ?? entry.core.quickTimeMake,
                cameraModel: entry.core.cameraModel ?? entry.core.quickTimeModel,
                fileType: entry.core.fileType,
                fileTypeExtension: entry.core.fileTypeExtension
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

        let (imageURLs, quickTimeURLs, otherVideoURLs) = splitByMediaType(urls)

        var allSucceeded = true
        var outputs: [String] = []

        if !imageURLs.isEmpty {
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
            let args: [String] = [
                "-overwrite_original",
                "-m",
                "-QuickTime:CreationDate=\(value)",
                "-CreateDate=\(value)",
                "-ModifyDate=\(value)",
                "-MediaCreateDate=\(value)",
                "-MediaModifyDate=\(value)",
                "-TrackCreateDate=\(value)",
                "-TrackModifyDate=\(value)"
            ] + quickTimeURLs.map(\.path)
            let result = runWriteTool(with: args)
            if !result.success { allSucceeded = false }
            if !result.output.isEmpty { outputs.append(result.output) }
        }

        if !otherVideoURLs.isEmpty {
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

    /// Writes only `QuickTime:CreationDate` to QuickTime video files, without
    /// setting `-DateTimeOriginal=`. This is used by the sanitise Phase 1
    /// pre-write to avoid creating XMP-style DateTimeOriginal tags in
    /// QuickTime containers (which ExifTool reads back in ISO 8601 format,
    /// e.g. "2011-03-16T11:55:13+00:00", defeating the sanitise).
    ///
    /// - Parameters:
    ///   - value: The date string to write (e.g. "2011:03:16 11:55:13").
    ///   - urls: The QuickTime file URLs to apply the change to.
    /// - Returns: A WriteResult with success status and captured output/error.
    static func writeQuickTimeCreationDate(_ value: String, to urls: [URL]) -> WriteResult {
        guard !urls.isEmpty else {
            return WriteResult(success: false, output: "No files provided.")
        }
        if let error = missingToolError {
            return WriteResult(success: false, output: error)
        }
        let args: [String] = [
            "-overwrite_original",
            "-m",
            "-QuickTime:CreationDate=\(value)",
            "-CreateDate=\(value)",
            "-ModifyDate=\(value)",
            "-MediaCreateDate=\(value)",
            "-MediaModifyDate=\(value)",
            "-TrackCreateDate=\(value)",
            "-TrackModifyDate=\(value)"
        ] + urls.map(\.path)
        return runWriteTool(with: args)
    }

    /// Writes a description value to all description-related tags.
    /// For regular images: Description, ImageDescription, Caption-Abstract.
    /// For HEIC/HEIF images: Description + XMP-dc:Description (HEIC containers
    /// don't properly support the EXIF ImageDescription tag — the description
    /// must be written to the XMP namespace instead).
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

        // Split HEIC/HEIF out of the image bucket — they need XMP-dc:Description
        // instead of EXIF ImageDescription / IPTC Caption-Abstract.
        let heicURLs = imageURLs.filter { isHEIC($0) }
        let regularImageURLs = imageURLs.filter { !isHEIC($0) }

        var allSucceeded = true
        var outputs: [String] = []

        if !regularImageURLs.isEmpty {
            let args = [
                "-overwrite_original",
                "-m",
                "-Description=\(value)",
                "-ImageDescription=\(value)",
                "-Caption-Abstract=\(value)"
            ] + regularImageURLs.map(\.path)
            let result = runWriteTool(with: args)
            if !result.success { allSucceeded = false }
            if !result.output.isEmpty { outputs.append(result.output) }
        }

        if !heicURLs.isEmpty {
            // NOTE: We deliberately do NOT write `-Description=\(value)` here.
            // The `Description` shortcut writes to ALL tags it maps to (including
            // EXIF:ImageDescription if the HEIC has an EXIF block). This can
            // create an empty/stale EXIF:ImageDescription that later shadows
            // XMP-dc:Description when the shortcut is read back. Writing only
            // the explicit XMP tag avoids this ambiguity entirely.
            let args = [
                "-overwrite_original",
                "-m",
                "-XMP-dc:Description=\(value)"
            ] + heicURLs.map(\.path)
            let result = runWriteTool(with: args)
            if !result.success { allSucceeded = false }
            if !result.output.isEmpty { outputs.append(result.output) }
        }

        if !allVideoURLs.isEmpty {
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
        let anyEmpty = regularImageURLs.isEmpty && heicURLs.isEmpty && allVideoURLs.isEmpty
        return WriteResult(success: allSucceeded || anyEmpty, output: combined)
    }

    // MARK: - Sanitise

    /// Sanitises files by normalising date formats to proper EXIF/QuickTime
    /// format (`YYYY:MM:DD HH:MM:SS`), propagating dates across all date tags,
    /// clearing offset time tags (images), and syncing descriptions.
    ///
    /// This is designed for files that have XMP-style ISO 8601 dates
    /// (e.g. `2010-03-27T01:40:19+00:00`) which the app's date formatter
    /// cannot parse, causing the Offset feature to skip them silently.
    ///
    /// **For images:**
    ///   - Normalises DateTimeOriginal via `DateFmt`
    ///   - Propagates to CreateDate, ModifyDate
    ///   - Clears OffsetTime, OffsetTimeOriginal, OffsetTimeDigitized
    ///   - Syncs Description → ImageDescription, Caption-Abstract
    ///
    /// **For videos:**
    ///   - Normalises QuickTime:CreationDate via `DateFmt`
    ///   - Propagates to CreateDate, ModifyDate
    ///   - Syncs Description (no offset tags — not applicable)
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

        let (imageURLs, quickTimeURLs, otherVideoURLs) = splitByMediaType(urls)
        let allVideoURLs = quickTimeURLs + otherVideoURLs

        // Split HEIC/HEIF out of the image bucket — they need XMP-dc:Description
        // instead of EXIF ImageDescription / IPTC Caption-Abstract.
        let heicURLs = imageURLs.filter { isHEIC($0) }
        let regularImageURLs = imageURLs.filter { !isHEIC($0) }

        var allSucceeded = true
        var outputs: [String] = []

        if !regularImageURLs.isEmpty {
            let args: [String] = [
                "-overwrite_original",
                "-m",
                #"-DateTimeOriginal<${DateTimeOriginal;DateFmt("%Y:%m:%d %H:%M:%S")}"#,
                "-CreateDate<DateTimeOriginal",
                "-ModifyDate<DateTimeOriginal",
                "-OffsetTime=",
                "-OffsetTimeOriginal=",
                "-OffsetTimeDigitized=",
                "-ImageDescription<Description",
                "-Caption-Abstract<Description"
            ] + regularImageURLs.map(\.path)
            let result = runWriteTool(with: args)
            if !result.success { allSucceeded = false }
            if !result.output.isEmpty { outputs.append(result.output) }
        }

        if !heicURLs.isEmpty {
            // NOTE: We deliberately do NOT sync Description → XMP-dc:Description here.
            // The `Description` shortcut tag in ExifTool resolves differently
            // depending on what other tags exist in the container. For HEIC files
            // with an EXIF block present (e.g. empty ImageDescription), the shortcut
            // resolves to EXIF:ImageDescription, NOT XMP-dc:Description — so
            // `-XMP-dc:Description<Description` would copy an EMPTY value into
            // XMP-dc:Description, wiping out the description just written by Save.
            // The description only lives in one place for HEIC (XMP-dc:Description)
            // so there is nothing to sync.
            let args: [String] = [
                "-overwrite_original",
                "-m",
                #"-DateTimeOriginal<${DateTimeOriginal;DateFmt("%Y:%m:%d %H:%M:%S")}"#,
                "-CreateDate<DateTimeOriginal",
                "-ModifyDate<DateTimeOriginal",
                "-OffsetTime=",
                "-OffsetTimeOriginal=",
                "-OffsetTimeDigitized="
            ] + heicURLs.map(\.path)
            let result = runWriteTool(with: args)
            if !result.success { allSucceeded = false }
            if !result.output.isEmpty { outputs.append(result.output) }
        }

        if !allVideoURLs.isEmpty {
            if !quickTimeURLs.isEmpty {
                let args: [String] = [
                    "-overwrite_original",
                    "-m",
                    #"-QuickTime:CreationDate<${QuickTime:CreationDate;DateFmt("%Y:%m:%d %H:%M:%S")}"#,
                    "-CreateDate<QuickTime:CreationDate",
                    "-ModifyDate<QuickTime:CreationDate",
                    "-MediaCreateDate<QuickTime:CreationDate",
                    "-MediaModifyDate<QuickTime:CreationDate",
                    "-TrackCreateDate<QuickTime:CreationDate",
                    "-TrackModifyDate<QuickTime:CreationDate"
                ] + quickTimeURLs.map(\.path)
                let result = runWriteTool(with: args)
                if !result.success { allSucceeded = false }
                if !result.output.isEmpty { outputs.append(result.output) }
            }
            if !otherVideoURLs.isEmpty {
                let args: [String] = [
                    "-overwrite_original",
                    "-m",
                    #"-DateTimeOriginal<${DateTimeOriginal;DateFmt("%Y:%m:%d %H:%M:%S")}"#,
                    "-CreateDate<DateTimeOriginal",
                    "-ModifyDate<DateTimeOriginal"
                ] + otherVideoURLs.map(\.path)
                let result = runWriteTool(with: args)
                if !result.success { allSucceeded = false }
                if !result.output.isEmpty { outputs.append(result.output) }
            }
        }

        let combined = outputs.joined(separator: "\n")
        let anyEmpty = regularImageURLs.isEmpty && heicURLs.isEmpty && allVideoURLs.isEmpty
        return WriteResult(success: allSucceeded || anyEmpty, output: combined)
    }
}