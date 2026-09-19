// Sessions.swift -- what the hooks told us, and what it means for the light.

import Foundation

/// What a hook last told us about a session. The raw values are written to the event
/// log on disk, so they never change. `end` is deliberately not a case: it exists to
/// forget a session, not to record an event.
enum SessionEvent: String, Codable {
    case prompt   // work handed to the agent, or a tool just ran
    case stop     // the agent finished its turn, the ball is yours
    case notify   // the agent is blocked on a permission prompt
}

/// The events that blink out of the box. Config.blinksOn can choose a different set;
/// a choice there does not change what any event means.
let defaultBlinkingEvents: Set<SessionEvent> = [.stop, .notify]

/// Milliseconds, alternating on/off starting with on: a double pulse, mostly dark.
let blinkPattern = [120, 120, 120, 900]

/// Backstop for sessions we could not tie to a process. The pid check does the real work.
let staleTTL: TimeInterval = 12 * 3600

struct Session: Equatable {
    let id: String
    let pid: pid_t
    let event: SessionEvent
    let at: Date
    let agent: String

    static func == (a: Session, b: Session) -> Bool { a.id == b.id && a.event == b.event }
}

func readSessions() -> [Session] {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: sessionsDir, includingPropertiesForKeys: nil) else { return [] }
    return files.compactMap { url in
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count >= 3,
              let pid = pid_t(lines[0]),
              let stamp = TimeInterval(lines[1]),
              let event = SessionEvent(rawValue: lines[2]) else { return nil }
        // Files written before multi-agent support have no fourth line; the only agent
        // that wrote them is `claude`.
        let agent = lines.count > 3 && !lines[3].isEmpty ? lines[3] : "claude"
        return Session(id: url.lastPathComponent, pid: pid, event: event,
                       at: Date(timeIntervalSince1970: stamp), agent: agent)
    }
}

func isAlive(_ pid: pid_t) -> Bool {
    pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
}

/// A session is stale when its process is gone, or when it outlived the TTL. This is
/// what stops a kill -9'd terminal from blinking forever.
func isStale(_ session: Session, now: Date = Date(),
             alive: (pid_t) -> Bool = isAlive) -> Bool {
    if session.pid != 0 && !alive(session.pid) { return true }
    return now.timeIntervalSince(session.at) > staleTTL
}

func pruneSessions() {
    for session in readSessions() where isStale(session) {
        try? FileManager.default.removeItem(at: sessionsDir.appendingPathComponent(session.id))
    }
}

func record(session: String, event: SessionEvent, pid: pid_t, agent: String) {
    ensureDirs()
    let body = "\(pid)\n\(Date().timeIntervalSince1970)\n\(event.rawValue)\n\(agent)\n"
    try? body.write(to: sessionsDir.appendingPathComponent(session),
                    atomically: true, encoding: .utf8)
}

func forget(_ session: String) {
    try? FileManager.default.removeItem(at: sessionsDir.appendingPathComponent(session))
}

/// session_id ends up as a filename.
func safeSessionID(_ raw: String) -> String {
    raw.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "..", with: "_")
}

/// Aggregation across windows is OR: any session needing you lights the lamp.
///
/// `events` is which events count as "needing you" this run -- it comes from the
/// user's Blink on choice, defaulting to the historical stop/notify pair. With a
/// timeout, a session stops counting once it has been waiting longer than it. The
/// session itself is left alone -- it is still waiting, and `status` and the menu still
/// say so; only the light gives up. The next hook event rewrites `at`, so answering one
/// window and leaving another re-arms the timer for the one you touched.
func shouldBlink(sessions: [Session], events: Set<SessionEvent> = defaultBlinkingEvents,
                 timeout: BlinkTimeout = .forever, now: Date = Date()) -> Bool {
    sessions.contains { session in
        guard events.contains(session.event) else { return false }
        guard let limit = timeout.seconds else { return true }
        return now.timeIntervalSince(session.at) < limit
    }
}
