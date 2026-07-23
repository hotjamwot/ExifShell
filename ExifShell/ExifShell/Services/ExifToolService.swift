import Foundation

// ============================================================================
// ExifToolService
// ============================================================================
// Core infrastructure for all ExifTool CLI operations.
//
// This file contains the shared foundation used by all extension files:
//   - ExifTool path resolution (auto-detects Homebrew, MacPorts, etc.)
//   - JSON decoder
//   - ReadResult / WriteResult types
//   - runReadTool() / runWriteTool() — process runners
//   - availabilityError() — tool availability check
//
// Extension files:
//   +ReadWrite   — readDateTimeOriginal, readAllMetadata, writeDateTimeOriginal,
//                   writeDescription, sanitise, FileMetadata, DateSource, JSON decoders
//   +Extensions  — videoExtensions, splitByMediaType, isUnwritableVideo,
//                   parseErrorSummary
//   +Rename      — renameFiles, detectTagCategories, path mapping, rename helpers
//
// Design principles:
//   - All operations are static methods on `enum ExifToolService`
//   - All errors return nil/empty/default rather than throwing
//   - Batch reads: pass [URL], get [URL: T] back (single process call)
//   - Batch writes: pass [URL] with a shared value (single process call)
//   - exifToolPath auto-resolves at static init time, no PATH dependency
// ============================================================================

enum ExifToolService {

    // MARK: - ExifTool Path Resolution

    /// Resolved path to the `exiftool` binary.
    /// Searches common installation locations so the app works regardless
    /// of whether it's launched via `swift run`, Xcode, or as a bundled .app.
    /// Xcode can launch with a stripped PATH, so we resolve the binary directly
    /// from PATH entries and common Homebrew/Cellar locations rather than relying
    /// on an external `which` probe that can fail in-app.
    private static let exifToolPath: String = {
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)

        var candidates: [String] = []
        candidates.append(contentsOf: pathEntries.map { $0 + "/exiftool" })
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/exiftool",   // Apple Silicon Homebrew
            "/usr/local/bin/exiftool",      // Intel Homebrew
            "/usr/bin/exiftool",            // System install (rare)
            "/opt/local/bin/exiftool",      // MacPorts
            "/opt/homebrew/opt/exiftool/libexec/bin/exiftool",
            "/usr/local/opt/exiftool/libexec/bin/exiftool"
        ])

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        let cellarRoots = [
            "/opt/homebrew/Cellar/exiftool",
            "/usr/local/Cellar/exiftool"
        ]
        for root in cellarRoots {
            guard FileManager.default.fileExists(atPath: root) else { continue }
            if let versions = try? FileManager.default.contentsOfDirectory(atPath: root) {
                for version in versions.sorted().reversed() {
                    let candidate = "\(root)/\(version)/bin/exiftool"
                    if FileManager.default.isExecutableFile(atPath: candidate) {
                        return candidate
                    }
                }
            }
        }

        return ""  // Will be detected at operation time
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Returns an error message if exiftool was not found at startup.
    static var missingToolError: String? {
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
    struct ReadResult {
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
    static func runReadTool(with args: [String]) -> ReadResult {
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
    static func runWriteTool(with args: [String]) -> WriteResult {
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
}