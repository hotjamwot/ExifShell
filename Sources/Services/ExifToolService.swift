import Foundation

/// Service for reading and writing image metadata via ExifTool.
/// All metadata logic is delegated to ExifTool — this is just a shell wrapper.
enum ExifToolService {

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: - Read

    /// Reads `DateTimeOriginal` from a file using `exiftool -json`.
    /// - Parameter url: The file URL to read from.
    /// - Returns: The raw DateTimeOriginal string, or nil if missing/error.
    static func readDateTimeOriginal(from url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "exiftool",
            "-json",
            "-DateTimeOriginal",
            url.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty else { return nil }

            let json = try decoder.decode([ExifToolOutput].self, from: data)
            return json.first?.dateTimeOriginal
        } catch {
            return nil
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        // Build the tag=value argument. Explicitly target EXIF:DateTimeOriginal
        // to ensure we write the EXIF tag and not a derived/copied variant.
        // Since Process passes each array element as a single argv entry,
        // the space in the value stays intact because it's all one string.
        let tagArg = "-EXIF:DateTimeOriginal=\(value)"

        var args = [
            "exiftool",
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