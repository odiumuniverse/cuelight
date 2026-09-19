// HookMerge.swift -- merging our hook entries into an agent's config without losing
// anyone else's.
//
// One engine per on-disk shape, all pure functions over parsed JSON. The App layer
// owns the files (reading, writing, backups); keeping the merge here is what lets the
// tests exercise every shape without touching a real config directory.
//
// Two properties hold in every engine:
//   * strip-before-add -- a bundle that moved must leave one entry, not two;
//   * nothing foreign is dropped -- only commands satisfying isOurCommand.
//
// An agent's config belongs to the user and usually holds unrelated hooks, so every
// write is a merge, never a replacement.

import Foundation

enum HookMerge {
    static func install(_ spec: AgentSpec, into settings: [String: Any],
                        executable: String) -> [String: Any] {
        switch spec.flavor {
        case .claudeSettings, .codexHooks:
            return installNested(spec, into: settings, executable: executable)
        case .geminiSettings:
            return installGemini(spec, into: settings, executable: executable)
        case .antigravityHooks:
            return installAntigravity(spec, into: settings, executable: executable)
        case .cursorHooks:
            return installCursor(spec, into: settings, executable: executable)
        case .opencodePlugin:
            return settings   // a JS file; OpencodePlugin owns install and remove
        }
    }

    static func remove(_ spec: AgentSpec, from settings: [String: Any]) -> [String: Any] {
        switch spec.flavor {
        case .claudeSettings, .geminiSettings, .codexHooks, .cursorHooks:
            return removeFromHooksObject(spec, from: settings)
        case .antigravityHooks:
            // Ours is exactly the `cuelight` group; the file is a map of groups and
            // every other group is the user's.
            var settings = settings
            settings.removeValue(forKey: "cuelight")
            return settings
        case .opencodePlugin:
            return settings
        }
    }

    static func installed(_ spec: AgentSpec, in settings: [String: Any],
                          executable: String) -> Bool {
        switch spec.flavor {
        case .opencodePlugin:
            return false   // the App decides this one from the marker inside the file
        case .antigravityHooks:
            guard let group = settings["cuelight"] as? [String: Any] else { return false }
            return spec.events.allSatisfy { event in
                commands(group[event.raw]).contains { $0.contains(executable) }
            }
        default:
            let hooks = settings["hooks"] as? [String: Any] ?? [:]
            return spec.events.allSatisfy { event in
                commands(hooks[event.raw]).contains { $0.contains(executable) }
            }
        }
    }

    /// True when one of our events already carries one of our commands, at any path.
    /// Re-pointing keys off this: it has to recognise a bundle that has since moved,
    /// or the launch-time re-point would install a second set instead of moving ours.
    static func containsOurs(_ spec: AgentSpec, in settings: [String: Any]) -> Bool {
        switch spec.flavor {
        case .opencodePlugin:
            return false
        case .antigravityHooks:
            guard let group = settings["cuelight"] as? [String: Any] else { return false }
            return spec.events.contains { event in
                commands(group[event.raw]).contains(where: isOurCommand)
            }
        default:
            let hooks = settings["hooks"] as? [String: Any] ?? [:]
            return spec.events.contains { event in
                commands(hooks[event.raw]).contains(where: isOurCommand)
            }
        }
    }
}

// MARK: - shared helpers

private extension HookMerge {
    /// The absolute path is quoted: the agents usually run hooks through a shell, and
    /// the bundle may sit under a path with spaces. The agent id is part of the
    /// command, so one binary can serve all six.
    static func command(_ spec: AgentSpec, executable: String, argument: String) -> String {
        "\"\(executable)\" hook \(spec.id) \(argument)"
    }

    static func isOurs(_ entry: [String: Any]) -> Bool {
        guard let command = entry["command"] as? String else { return false }
        return isOurCommand(command)
    }

    /// Every leaf `command` string an event stores, for both the nested
    /// `{"hooks": [...]}` shape and the direct-handler shape Antigravity and Cursor use.
    /// A group with no `hooks` key is treated as a leaf entry itself.
    static func commands(_ value: Any?) -> [String] {
        guard let groups = value as? [[String: Any]] else { return [] }
        return groups.flatMap { group -> [String] in
            if let nested = group["hooks"] as? [[String: Any]] {
                return nested.compactMap { $0["command"] as? String }
            }
            return [group["command"] as? String].compactMap { $0 }
        }
    }

    /// One event's stored groups, with our entries removed. A group left empty is
    /// dropped, so a foreign key that held only our hook disappears with it.
    static func stripped(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            guard var entries = group["hooks"] as? [[String: Any]] else {
                return isOurs(group) ? nil : group
            }
            entries.removeAll(where: isOurs)
            if entries.isEmpty { return nil }
            var updated = group
            updated["hooks"] = entries
            return updated
        }
    }

    /// Claude Code and Codex both wrap handlers in `{"hooks": [...]}`; the difference
    /// is that Codex entries carry an explicit timeout.
    static func installNested(_ spec: AgentSpec, into settings: [String: Any],
                              executable: String) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in spec.events {
            var groups = stripped(hooks[event.raw] as? [[String: Any]] ?? [])
            var entry: [String: Any] = [
                "type": "command",
                "command": command(spec, executable: executable, argument: event.argument),
            ]
            if spec.flavor == .codexHooks { entry["timeout"] = 5 }
            groups.append(["hooks": [entry]])
            hooks[event.raw] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    /// Gemini CLI wraps handlers like Claude does, but each group carries a matcher
    /// and each handler a name, so ours is appended to whatever is already there
    /// rather than replacing the event.
    static func installGemini(_ spec: AgentSpec, into settings: [String: Any],
                              executable: String) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in spec.events {
            var groups = stripped(hooks[event.raw] as? [[String: Any]] ?? [])
            groups.append([
                "matcher": "*",
                "hooks": [[
                    "name": "cuelight-\(event.argument)",
                    "type": "command",
                    "command": command(spec, executable: executable, argument: event.argument),
                    // Gemini reads this in milliseconds (its default is 60000), unlike
                    // the seconds every other agent's timeout field uses.
                    "timeout": 5000,
                ]],
            ])
            hooks[event.raw] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    /// Antigravity's file is a top-level map of named groups. Ours is the `cuelight`
    /// group; every other group (there really is a `herdr` one out there) is left
    /// exactly as found.
    static func installAntigravity(_ spec: AgentSpec, into settings: [String: Any],
                                   executable: String) -> [String: Any] {
        var settings = settings
        var group: [String: Any] = [:]
        for event in spec.events {
            let handler: [String: Any] = [
                "type": "command",
                "command": command(spec, executable: executable, argument: event.argument),
                "timeout": 5,
            ]
            // PreInvocation and Stop take a direct handler list; the tool events take
            // matcher groups. Both appear in the wild, which is why the shape is not
            // uniform.
            switch event.raw {
            case "PreInvocation", "Stop":
                group[event.raw] = [handler]
            case "PreToolUse":
                group[event.raw] = [["matcher": "ask_question", "hooks": [handler]]]
            default:
                group[event.raw] = [["matcher": "*", "hooks": [handler]]]
            }
        }
        settings["cuelight"] = group
        return settings
    }

    /// Cursor appends bare handler objects to an event array -- no `type`, no nested
    /// `hooks` wrapper -- and versioned the file.
    static func installCursor(_ spec: AgentSpec, into settings: [String: Any],
                              executable: String) -> [String: Any] {
        var settings = settings
        // Keep the version the user's file has; add `1` if a file somehow lacks it.
        // Never drop it: Cursor refuses a versionless hooks file.
        if settings["version"] == nil { settings["version"] = 1 }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in spec.events {
            var entries = stripped(hooks[event.raw] as? [[String: Any]] ?? [])
            entries.append([
                "command": command(spec, executable: executable, argument: event.argument),
                "timeout": 5,
            ])
            hooks[event.raw] = entries
        }
        settings["hooks"] = hooks
        return settings
    }

    static func removeFromHooksObject(_ spec: AgentSpec,
                                      from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for event in spec.events {
            guard let groups = hooks[event.raw] as? [[String: Any]] else { continue }
            let remaining = stripped(groups)
            if remaining.isEmpty { hooks.removeValue(forKey: event.raw) }
            else { hooks[event.raw] = remaining }
        }
        // Never invent keys that were not there: removing the last of ours from a
        // file with no hooks at all leaves it without a hooks object too.
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") }
        else { settings["hooks"] = hooks }
        return settings
    }
}
