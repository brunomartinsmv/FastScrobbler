#!/usr/bin/env swift
// Tests for the Priority 1 & 3 fixes.
// Run with: swift scripts/run_tests.swift

import Foundation

let fileManager = FileManager.default
let scriptPath = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: URL(fileURLWithPath: fileManager.currentDirectoryPath)).standardizedFileURL
let scriptsDirectory = scriptPath.deletingLastPathComponent()
let sourceDirectory = scriptsDirectory.appendingPathComponent("run_tests", isDirectory: true)

let allSources = try fileManager.contentsOfDirectory(
    at: sourceDirectory,
    includingPropertiesForKeys: nil
)
.filter { $0.pathExtension == "swift" }
.sorted { lhs, rhs in
    if lhs.lastPathComponent == "Main.swift" { return false }
    if rhs.lastPathComponent == "Main.swift" { return true }
    return lhs.lastPathComponent < rhs.lastPathComponent
}

let temporaryDirectory = fileManager.temporaryDirectory
    .appendingPathComponent("fastscrobbler-run-tests-\(UUID().uuidString)", isDirectory: true)
try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: temporaryDirectory) }

let executable = temporaryDirectory.appendingPathComponent("run_tests")

func run(_ executablePath: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

let compileStatus = try run(
    "/usr/bin/env",
    ["swiftc"] + allSources.map(\.path) + ["-o", executable.path]
)
if compileStatus != 0 {
    exit(compileStatus)
}

let testStatus = try run(executable.path, [])
if testStatus != 0 {
    exit(testStatus)
}
