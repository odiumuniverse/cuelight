// Process.swift -- finding the agent process that owns a hook.
//
// Every agent names its process differently and several rewrite their title, so the
// match is against the executable path and the names come from the spec, not from here.

import Darwin
import Foundation

func parentOf(_ pid: pid_t) -> pid_t? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

/// Executable path, not `p_comm`: agents rewrite their process title (Claude Code uses
/// its version number, so the short name tells you nothing). The path stays honest.
func executablePath(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    return written > 0 ? String(cString: buffer) : ""
}

private let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"]

/// A hook runs as a short-lived child, usually under a shell, so getppid() dies at once
/// and would prune the session immediately. Walk up to the agent's process instead.
///
/// A candidate matches when any `/`-component of the executable path contains it
/// (lowercased): a native install lives under `.../claude/versions/<version>`, so a
/// directory carries the agent's name even though the version-named executable does not.
///
/// Returns 0 when it cannot be identified: that means "TTL only, no pid check".
func agentAncestor(matching names: [String]) -> pid_t {
    var pid = getppid()
    var firstNonShell: pid_t = 0

    for _ in 0..<8 {
        guard let parent = parentOf(pid) else { break }
        let path = executablePath(pid)
        let name = (path as NSString).lastPathComponent

        let components = path.lowercased().split(separator: "/")
        if names.contains(where: { candidate in
            components.contains { $0.contains(candidate) }
        }) {
            return pid
        }
        // Fallback for installs launched through node or a wrapper: the first ancestor
        // that is not a shell is whatever spawned the hook, which is the agent.
        if firstNonShell == 0, !shellNames.contains(name), !name.isEmpty {
            firstNonShell = pid
        }
        if parent <= 1 { break }
        pid = parent
    }
    return firstNonShell
}
