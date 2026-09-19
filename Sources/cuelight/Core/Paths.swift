// Paths.swift -- where cuelight keeps its state, and how it reports on itself.

import Foundation

/// CUELIGHT_HOME is a test and verification seam: it moves *every* path -- the config
/// directory and each agent's config file -- into a scratch home, so the tests and the
/// smoke commands can run without touching a real ~/.claude or ~/.config.
var homeRoot: URL = ProcessInfo.processInfo.environment["CUELIGHT_HOME"]
    .map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser

/// Mutable so tests can point it at a scratch directory.
var configRoot: URL = homeRoot.appendingPathComponent(".config/cuelight", isDirectory: true)

var sessionsDir: URL { configRoot.appendingPathComponent("sessions", isDirectory: true) }
var configFile: URL { configRoot.appendingPathComponent("config.json") }

func ensureDirs() {
    try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
}

/// Appends a line to ~/.config/cuelight/diagnostics.log. Permission problems are
/// invisible from outside the app, so it keeps its own account of what it can see.
func diagnose(_ message: String) {
    ensureDirs()
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp)  \(message)\n"
    let url = configRoot.appendingPathComponent("diagnostics.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}
