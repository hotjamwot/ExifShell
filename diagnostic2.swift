import Foundation

// Simulate exactly what ExifToolService.runReadTool does
// with a real file to see what happens

print("=== DIAGNOSTIC: Simulating exiftool Process call ===")

// Use a file that exists - you'll need to update this
let filePaths = CommandLine.arguments.dropFirst()
guard !filePaths.isEmpty else {
    print("ERROR: Provide a file path as argument")
    print("Usage: swift diagnostic2.swift /path/to/your/file.jpg")
    exit(1)
}

let filePath = filePaths.first!
print("File: \(filePath)")
print("File exists: \(FileManager.default.fileExists(atPath: filePath))")

// Run exiftool like the app does
let args = ["-json", "-DateTimeOriginal", "-CreateDate", "-ModifyDate", filePath]
print("Args: \(args)")

let process = Process()
process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/exiftool")
process.arguments = args

let outPipe = Pipe()
let errPipe = Pipe()  // Capture stderr too!
process.standardOutput = outPipe
process.standardError = errPipe

var terminationStatus: Int32 = -1
do {
    try process.run()
    process.waitUntilExit()
    terminationStatus = process.terminationStatus
    
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    
    let stdout = String(data: outData, encoding: .utf8) ?? "NIL"
    let stderr = String(data: errData, encoding: .utf8) ?? "NIL"
    
    print("Exit code: \(terminationStatus)")
    print("STDOUT (\(outData.count) bytes):")
    if outData.isEmpty {
        print("  [EMPTY]")
    } else {
        print("  \(stdout)")
    }
    print("STDERR (\(errData.count) bytes):")
    if errData.isEmpty {
        print("  [EMPTY]")
    } else {
        print("  \(stderr)")
    }
    
    // Try to decode
    if !outData.isEmpty {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        struct TestOutput: Decodable {
            let sourceFile: String
            let dateTimeOriginal: String?
            let createDate: String?
            let modifyDate: String?
            enum CodingKeys: String, CodingKey {
                case sourceFile = "SourceFile"
                case dateTimeOriginal = "DateTimeOriginal"
                case createDate = "CreateDate"
                case modifyDate = "ModifyDate"
            }
        }
        if let json = try? decoder.decode([TestOutput].self, from: outData) {
            print("DECODED: \(json.count) entries")
            for entry in json {
                print("  SourceFile: \(entry.sourceFile)")
                print("  DateTimeOriginal: '\(entry.dateTimeOriginal ?? "nil")'")
                print("  CreateDate: '\(entry.createDate ?? "nil")'")
                print("  ModifyDate: '\(entry.modifyDate ?? "nil")'")
            }
        } else {
            print("DECODE FAILED - trying plain JSON parse...")
            if let jsonObj = try? JSONSerialization.jsonObject(with: outData) {
                print("  JSON parsed: \(jsonObj)")
            } else {
                print("  Not valid JSON at all")
                print("  Raw stdout: '\(stdout)'")
            }
        }
    }
} catch {
    print("Process launch failed: \(error)")
}