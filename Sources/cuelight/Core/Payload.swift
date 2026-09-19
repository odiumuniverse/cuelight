// Payload.swift -- reading what an agent's hook sent us on stdin.
//
// The shapes differ per agent (see AgentSpec), and a value may be a plain string or an
// array of strings. These helpers normalise that so the hook path deals in one shape:
// an absent session id means "record nothing but still answer", and an absent cwd means
// the project is simply unknown.

import Foundation

/// The first key with a usable value wins. For an array, the first non-empty element.
func payloadString(_ json: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let text = json[key] as? String, !text.isEmpty { return text }
        if let list = json[key] as? [String], let first = list.first, !first.isEmpty {
            return first
        }
    }
    return nil
}

func payloadSessionID(_ json: [String: Any], keys: [String]) -> String? {
    payloadString(json, keys: keys)
}

func payloadCwd(_ json: [String: Any], keys: [String]) -> String? {
    payloadString(json, keys: keys)
}

/// The opencode plugin sends its own pid; every other agent's hook has to find its
/// process by walking ancestors. A plausible pid is a positive Int that fits pid_t.
func payloadPID(_ json: [String: Any]) -> pid_t? {
    guard let pid = json["pid"] as? Int, pid > 0, pid <= Int(Int32.max) else { return nil }
    return pid_t(pid)
}
