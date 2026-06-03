import Foundation

// ===== DIAGNOSTIC: Test if the ExifToolService fix works =====

print("=== DIAGNOSTIC 1: JSON Decoding ===")
let jsonString = """
[{
  "SourceFile": "/Volumes/T7_BLUE/Photos_Library/2008/11 November - Vals, Beach, Sunset/20090616-1447-005.JPG",
  "DateTimeOriginal": "2008:11:28 20:37:05",
  "CreateDate": "2008:11:28 20:37:05",
  "ModifyDate": "2008:11:28 20:37:05"
}]
"""

let decoder = JSONDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase

struct TestOutput: Decodable {
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
}

do {
    let data = jsonString.data(using: .utf8)!
    let result = try decoder.decode([TestOutput].self, from: data)
    print("  ✅ Decoded successfully!")
    print("  DateTimeOriginal: \(result[0].dateTimeOriginal ?? "nil")")
    print("  CreateDate:       \(result[0].createDate ?? "nil")")
    print("  ModifyDate:       \(result[0].modifyDate ?? "nil")")
    print("  SourceFile:       \(result[0].sourceFile)")
} catch {
    print("  ❌ Decoding failed: \(error)")
}

print("")
print("=== DIAGNOSTIC 2: Working Directory Check ===")

// Get the directory of the diagnostic script
let cwd = FileManager.default.currentDirectoryPath
print("Current working directory: \(cwd)")

// Check if the test file exists
let testFile = "/Volumes/T7_BLUE/Photos_Library/2008/11 November - Vals, Beach, Sunset/20090616-1447-005.JPG"
print("Test file exists: \(FileManager.default.fileExists(atPath: testFile))")

// Check what exiftool returns from the app's perspective
print("")
print("=== DIAGNOSTIC 3: ExifTool direct call ===")
let pipe = Pipe()
let process = Process()
process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/exiftool")
process.arguments = ["-json", "-DateTimeOriginal", "-CreateDate", "-ModifyDate", testFile]
process.standardOutput = pipe
process.standardError = FileHandle.nullDevice
try? process.run()
process.waitUntilExit()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
let output = String(data: data, encoding: .utf8) ?? "EMPTY"
print("Exit code: \(process.terminationStatus)")
print("Output:")
print(output)

// Now decode it
if let jsonData = output.data(using: .utf8) {
    do {
        let entries = try decoder.decode([TestOutput].self, from: jsonData)
        for entry in entries {
            print("  -> SourceFile: \(entry.sourceFile)")
            print("  -> DateTimeOriginal: \(entry.dateTimeOriginal ?? "nil")")
            print("  -> CreateDate: \(entry.createDate ?? "nil")")
            print("  -> ModifyDate: \(entry.modifyDate ?? "nil")")
        }
    } catch {
        print("  ❌ Could not decode exiftool output: \(error)")
    }
}

print("")
print("=== DIAGNOSTIC 4: What the app receives (NSItemProvider URL) ===")
// If the user drags from Finder, the URL comes from NSItemProvider
// which can give different URL representations. Let's check what works.
let fromFileURL = URL(fileURLWithPath: testFile)
let fromStringURL = URL(string: "file:///Volumes/T7_BLUE/Photos_Library/2008/11%20November%20-%20Vals,%20Beach,%20Sunset/20090616-1447-005.JPG")

print("fileURLWithPath URL: \(fromFileURL.absoluteString)")
print("URL(string:) URL:    \(fromStringURL?.absoluteString ?? "nil")")

if let fromString = fromStringURL {
    print("Equality: \(fromFileURL == fromString)")
    print("Path equality: \(fromFileURL.path == fromString.path)")
    
    // Test the fix approach
    let pathLookup = [fromString.standardizedFileURL.path: fromString]
    let entryPath = (testFile as NSString).standardizingPath
    print("Fix - lookup key:   \(fromString.standardizedFileURL.path)")
    print("Fix - entry path:   \(entryPath)")
    print("Fix - matches:      \(pathLookup[entryPath] != nil)")
}