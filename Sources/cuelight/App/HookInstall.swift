// HookInstall.swift -- reading and writing the agents' config files.
// The merges themselves live in Core/HookMerge.swift, where they can be tested.

import Foundation

enum Hooks {
    /// Absolute path into the bundle. A bare `cuelight` would depend on whatever PATH
    /// an agent happens to run hooks with, which is not ours to assume.
    static var executable: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    static func url(for spec: AgentSpec) -> URL {
        homeRoot.appendingPathComponent(spec.configPath)
    }

    private static func load(_ spec: AgentSpec) -> [String: Any] {
        guard let data = try? Data(contentsOf: url(for: spec)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private static func write(_ settings: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// One-time backup before the first write, so a bad merge is always recoverable.
    /// Never overwritten: a second write must not replace a good copy with a broken one.
    private static func backupOnce(_ url: URL) {
        let backup = url.appendingPathExtension("cuelight-backup")
        guard FileManager.default.fileExists(atPath: url.path),
              !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: url, to: backup)
    }

    static func installed(_ spec: AgentSpec) -> Bool {
        if spec.flavor == .opencodePlugin {
            return OpencodePlugin.isOurs(at: OpencodePlugin.url(home: homeRoot))
        }
        return HookMerge.installed(spec, in: load(spec), executable: executable)
    }

    static func install(_ spec: AgentSpec) throws {
        if spec.flavor == .opencodePlugin {
            let url = OpencodePlugin.url(home: homeRoot)
            if !OpencodePlugin.isOurs(at: url) { backupOnce(url) }
            try OpencodePlugin.install(into: homeRoot, executable: executable)
            return
        }
        let url = url(for: spec)
        let settings = load(spec)
        // Only a file without our hooks is worth a backup: installing twice must not
        // litter a copy of our own output next to every agent config.
        if !HookMerge.installed(spec, in: settings, executable: executable) {
            backupOnce(url)
        }
        try write(HookMerge.install(spec, into: settings, executable: executable), to: url)
    }

    static func remove(_ spec: AgentSpec) throws {
        if spec.flavor == .opencodePlugin {
            OpencodePlugin.remove(from: homeRoot)
            return
        }
        // An agent with no config file has nothing to remove, and removing must not
        // create the very file it was asked to leave alone.
        let target = url(for: spec)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try write(HookMerge.remove(spec, from: load(spec)), to: target)
    }

    /// Called on launch: re-points hooks that are already ours at this bundle's path.
    /// It never installs what was not already ours -- installing is a deliberate menu
    /// or CLI action -- but a moved bundle must not be left behind pointing at
    /// something that is no longer installed.
    static func repointInstalled() {
        for spec in AgentSpec.all {
            if spec.flavor == .opencodePlugin {
                let url = OpencodePlugin.url(home: homeRoot)
                guard OpencodePlugin.isOurs(at: url) else { continue }
                let current = try? String(contentsOf: url, encoding: .utf8)
                guard current != OpencodePlugin.template(executable: executable) else { continue }
                try? install(spec)
                continue
            }
            let settings = load(spec)
            guard HookMerge.containsOurs(spec, in: settings),
                  !HookMerge.installed(spec, in: settings, executable: executable) else {
                continue
            }
            try? install(spec)
        }
    }
}
