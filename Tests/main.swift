// tests.swift -- assert-based checks over Core/. No framework, no fixtures.
//   swiftc -O Sources/cuelight/Core/*.swift Tests/main.swift -o build/tests && ./build/tests

import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ what: String,
           file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if condition {
        print("  ok   \(what)")
    } else {
        failures += 1
        print("  FAIL \(what)   (\(file):\(line))")
    }
}

func equal<T: Equatable>(_ got: T, _ want: T, _ what: String,
                         file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if got == want {
        print("  ok   \(what)")
    } else {
        failures += 1
        print("  FAIL \(what)")
        print("       got:  \(got)")
        print("       want: \(want)   (\(file):\(line))")
    }
}

func section(_ name: String) { print("\n\(name)") }

/// Every table-driven test walks AgentSpec.all, so one lookup helper with a loud
/// failure keeps the tests readable without force-unwraps.
func spec(_ id: String) -> AgentSpec {
    if let found = AgentSpec.find(id) { return found }
    checks += 1
    failures += 1
    print("  FAIL no agent '\(id)'")
    return AgentSpec.all[0]
}

// Work in a scratch directory: never touch the user's real config.
let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("cuelight-tests-\(getpid())")
configRoot = scratch
ensureDirs()
defer { try? FileManager.default.removeItem(at: scratch) }

// MARK: - keyboard selection
//
// "Empty means all" is the tricky part: the menu shows ticks, the config stores a list,
// and the two disagree about what "everything" looks like.

section("selection")

let both = ["Internal", "Magic"]

equal(Selection.toggle("Magic", current: [], drivable: both), ["Internal"],
      "unticking one of two, starting from 'all', leaves the other")

equal(Selection.toggle("Magic", current: ["Internal"], drivable: both), [],
      "ticking the second collapses back to 'all'")

equal(Selection.toggle("Internal", current: ["Internal"], drivable: both), ["Internal"],
      "unticking the last selected keyboard is refused, the light must stay drivable")

equal(Selection.toggle("Internal", current: [], drivable: ["Internal"]), [],
      "with a single keyboard attached, unticking it is refused")

equal(Selection.toggle("MX Keys", current: [], drivable: both), [],
      "toggling a keyboard that is not attached changes nothing")

equal(Selection.toggle("Magic", current: ["Internal", "Unplugged"], drivable: both), [],
      "a stale name in the config is dropped, and the result collapses to 'all'")

// MARK: - config round trip

section("config")

var cfg = Config(keyboards: ["Magic"])
cfg.save()
equal(Config.load(), cfg, "config survives a save/load round trip")

check(Config(keyboards: []).selects("anything"), "empty selection means every keyboard")
check(Config(keyboards: ["Magic"]).selects("Magic"), "a named keyboard is selected")
check(!Config(keyboards: ["Magic"]).selects("Internal"), "an unnamed keyboard is not")

// A config written before idleCapSeconds existed must still load, or upgrading would
// silently reset the user's keyboard selection.
try? #"{"keyboards":["Magic"]}"#.write(to: configFile, atomically: true, encoding: .utf8)
equal(Config.load().keyboards, ["Magic"], "a config predating a new field still loads")
equal(Config.load().idleCap, 300, "and the new field falls back to its default")
check(Config.load().blinkTimeout == .forever,
      "a config without a blink timeout blinks until answered, as it always did")

// MARK: - blink timeout parsing

section("blink timeout")

check(BlinkTimeout.parse("5m") == .after(300), "minutes are read as minutes")
check(BlinkTimeout.parse("90s") == .after(90), "seconds are read as seconds")
check(BlinkTimeout.parse("1h") == .after(3600), "hours are read as hours")
check(BlinkTimeout.parse("600") == .after(600), "a bare number is seconds, as stored")
check(BlinkTimeout.parse(" 10M ") == .after(600), "case and surrounding space do not matter")
check(BlinkTimeout.parse("always") == .forever, "'always' is the no-timeout spelling")
check(BlinkTimeout.parse("0") == .forever, "zero means forever, not a zero-length blink")
check(BlinkTimeout.parse("-5m") == nil, "a negative duration is refused")
check(BlinkTimeout.parse("soon") == nil, "nonsense is refused rather than defaulted")
check(BlinkTimeout.parse("") == nil, "an empty string is refused")

equal(BlinkTimeout.after(300).label, "5 min", "a round number of minutes reads as minutes")
equal(BlinkTimeout.after(90).label, "90s", "an odd duration keeps its seconds")
equal(BlinkTimeout.forever.label, "Always", "forever has a name the menu can show")

// The menu writes seconds back into the config, so the presets must survive the trip.
for preset in BlinkTimeout.presets {
    var stored = Config()
    stored.blinkTimeoutSeconds = preset.seconds
    check(stored.blinkTimeout == preset, "the '\(preset.label)' preset round trips through config")
}

try? FileManager.default.removeItem(at: configFile)
equal(Config.load(), Config(), "a missing config file loads defaults rather than failing")

// MARK: - which events blink

section("blinking events")

var blinkChoice = Config()
equal(blinkChoice.blinksOn, defaultBlinkingEvents,
      "a config without the field uses the historical default")
equal(blinkChoice.blinksOn, [.stop, .notify], "which is stop and notify, nothing else")

blinkChoice.blinkingEvents = []
check(blinkChoice.blinksOn.isEmpty, "an explicit empty list means nothing blinks, a real choice")

blinkChoice.blinkingEvents = ["prompt"]
equal(blinkChoice.blinksOn, [.prompt], "the list is what is stored, not a selection convention")

blinkChoice.blinkingEvents = ["prompt", "bogus", "stop"]
equal(blinkChoice.blinksOn, [.prompt, .stop], "an unknown stored string is dropped, the rest survive")

blinkChoice.blinkingEvents = ["notify"]
blinkChoice.save()
equal(Config.load().blinksOn, [.notify], "the choice round trips through save/load")

// An old config predates the field entirely, and must keep the old behaviour.
try? #"{"keyboards":["Magic"]}"#.write(to: configFile, atomically: true, encoding: .utf8)
equal(Config.load().blinksOn, defaultBlinkingEvents, "an upgraded config changes nothing")

var toggled = Config()
toggled.toggleBlinking(.prompt)
equal(toggled.blinksOn, [.stop, .notify, .prompt], "ticking an event adds it")
check(toggled.blinkingEvents == ["notify", "prompt", "stop"], "and the stored list is sorted")
toggled.toggleBlinking(.prompt)
equal(toggled.blinksOn, [.stop, .notify], "unticking removes it again")

// MARK: - blink decision

section("blink decision")

let now = Date()
func session(_ id: String, _ event: SessionEvent, pid: pid_t = 0,
             at: Date = Date(), agent: String = "claude") -> Session {
    Session(id: id, pid: pid, event: event, at: at, agent: agent)
}

check(!shouldBlink(sessions: []), "no sessions, no blinking")
check(shouldBlink(sessions: [session("a", .stop)]), "a finished turn blinks")
check(shouldBlink(sessions: [session("a", .notify)]), "a permission prompt blinks")
check(!shouldBlink(sessions: [session("a", .prompt)]), "work in flight does not blink")
check(shouldBlink(sessions: [session("a", .prompt), session("b", .stop)]),
      "OR across windows: one waiting session is enough")
check(!shouldBlink(sessions: [session("a", .prompt), session("b", .prompt)]),
      "several busy sessions still do not blink")

check(shouldBlink(sessions: [session("a", .prompt)], events: [.prompt]),
      "work in flight blinks when the user asks it to")
check(!shouldBlink(sessions: [session("a", .stop)], events: []),
      "an empty choice never blinks, even with a session waiting")

// With a timeout, the lamp gives up on a session that has been waiting too long. The
// session is not touched: staleness is a separate question, tested below.
let waitingFor: (TimeInterval) -> [Session] = { [session("a", .stop, at: now.addingTimeInterval(-$0))] }

check(shouldBlink(sessions: waitingFor(3600), timeout: .forever, now: now),
      "without a timeout, an hour of waiting still blinks")
check(shouldBlink(sessions: waitingFor(60), timeout: .after(300), now: now),
      "inside the timeout, a waiting session blinks")
check(!shouldBlink(sessions: waitingFor(301), timeout: .after(300), now: now),
      "past the timeout, the lamp goes dark")
check(!shouldBlink(sessions: waitingFor(300), timeout: .after(300), now: now),
      "the timeout is exclusive: exactly at the limit is already dark")
check(shouldBlink(sessions: [session("a", .stop, at: now.addingTimeInterval(-3600)),
                             session("b", .stop, at: now.addingTimeInterval(-10))],
                  timeout: .after(300), now: now),
      "OR still holds under a timeout: one fresh session keeps the lamp lit")

// MARK: - staleness
//
// The requirement is that a kill -9'd terminal cannot leave the lamp blinking.

section("staleness")

let dead: (pid_t) -> Bool = { _ in false }
let living: (pid_t) -> Bool = { _ in true }

check(isStale(session("a", .stop, pid: 4242), alive: dead),
      "a session whose process is gone is stale")
check(!isStale(session("a", .stop, pid: 4242), alive: living),
      "a session whose process lives is kept")
check(!isStale(session("a", .stop, pid: 0), alive: dead),
      "pid 0 means unknown, so the pid check must not fire")
check(isStale(session("a", .stop, pid: 0, at: now.addingTimeInterval(-staleTTL - 1)),
              now: now, alive: dead),
      "an unidentified session older than the TTL is stale")
check(!isStale(session("a", .stop, pid: 0, at: now.addingTimeInterval(-60)),
               now: now, alive: dead),
      "a recent unidentified session is kept")

// MARK: - session files

section("session files")

record(session: "s1", event: .stop, pid: 1234, agent: "claude")
record(session: "s2", event: .prompt, pid: 0, agent: "cursor")
equal(readSessions().count, 2, "both session files are read back")
check(readSessions().contains { $0.id == "s1" && $0.event == .stop }, "event survives the round trip")

record(session: "s1", event: .prompt, pid: 1234, agent: "claude")
check(readSessions().contains { $0.id == "s1" && $0.event == .prompt },
      "recording again overwrites the event rather than adding a session")

equal(readSessions().first { $0.id == "s2" }?.agent, "cursor",
      "the agent survives the round trip")

// Files written before multi-agent support have three lines, not four.
try? "0\n\(Date().timeIntervalSince1970)\nstop\n".write(
    to: sessionsDir.appendingPathComponent("oldstyle"), atomically: true, encoding: .utf8)
equal(readSessions().first { $0.id == "oldstyle" }?.agent, "claude",
      "a three-line session file reads as Claude's")

forget("s1")
equal(readSessions().count, 2, "forgetting removes exactly one session")

try? "garbage".write(to: sessionsDir.appendingPathComponent("broken"),
                     atomically: true, encoding: .utf8)
equal(readSessions().count, 2, "an unparseable file is ignored, not crashed on")
try? FileManager.default.removeItem(at: sessionsDir.appendingPathComponent("broken"))
try? FileManager.default.removeItem(at: sessionsDir.appendingPathComponent("oldstyle"))

equal(safeSessionID("../../etc/passwd"), "_/_/etc/passwd".replacingOccurrences(of: "/", with: "_"),
      "a session id cannot escape its directory")

// MARK: - event log

section("event log")

let day: TimeInterval = 24 * 3600
let noon = Date(timeIntervalSince1970: 1_752_926_400)   // 2025-07-19 12:00 UTC

logEvent(session: "s1", event: .prompt, project: "cuelight", agent: "claude", at: noon)
logEvent(session: "s1", event: .stop, project: "cuelight", agent: "claude", at: noon + 30)
logEvent(session: "s2", event: .notify, project: "topscan", agent: "gemini", at: noon + 60)

let logged = readEvents(from: noon - day, to: noon + day)
equal(logged.count, 3, "every appended event is read back")
equal(logged.map(\.e), [.prompt, .stop, .notify], "events come back in time order")
equal(logged.first?.p, "cuelight", "the project survives the round trip")
equal(logged.first?.a, "claude", "the agent survives the round trip")

equal(readEvents(from: noon + 40, to: noon + day).count, 1,
      "the window excludes events outside it")
equal(readEvents(from: noon + 10 * 365 * day).count, 0,
      "a window with no data reads as empty, not as everything")

// A line written before the agent field existed must still decode, so an upgrade does
// not lose the history accrued so far.
let logFile = eventsDir.appendingPathComponent(monthFile(for: noon))
if let handle = try? FileHandle(forWritingTo: logFile) {
    handle.seekToEndOfFile()
    let legacyLine = "{\"t\":\(noon.timeIntervalSince1970),\"s\":\"s3\",\"e\":\"stop\","
        + "\"p\":\"old\"}\n"
    handle.write(Data(legacyLine.utf8))
    handle.write(Data("{\"t\":1,\"s\":\"tor\n".utf8))
    try? handle.close()
}
let withLegacy = readEvents(from: noon - day, to: noon + day)
equal(withLegacy.count, 4, "a line without the agent field still decodes")
equal(withLegacy.first { $0.s == "s3" }?.a, nil, "and reads back with no agent")
equal(readEvents(from: noon - day, to: noon + day).count, 4,
      "a torn line is skipped rather than costing the whole report")

equal(monthFile(for: noon), "2025-07.jsonl", "log files are named by month")
equal(monthsSpanned(from: noon, to: noon + 30 * day), ["2025-07.jsonl", "2025-08.jsonl"],
      "a window spanning a month boundary reads both files")

equal(projectName(cwd: "/Users/someone/work/acme-secret"), "acme-secret",
      "only the last path component is kept, never the full path")
equal(projectName(cwd: nil), "unknown", "a hook without a cwd still logs")
equal(projectName(cwd: "/"), "unknown", "the root directory has no useful name")

// MARK: - statistics

section("statistics")

func event(_ session: String, _ kind: SessionEvent, _ offset: TimeInterval,
           project: String = "cuelight", agent: String? = nil) -> LoggedEvent {
    LoggedEvent(t: noon.timeIntervalSince1970 + offset, s: session, e: kind, p: project, a: agent)
}

let cap: TimeInterval = 300

let oneTurn = summarise([event("a", .prompt, 0), event("a", .stop, 60),
                         event("a", .prompt, 90)], cap: cap)
equal(oneTurn.totals.worked, 60, "prompt to stop is the agent working")
equal(oneTurn.totals.waiting, 30, "stop to prompt is the agent waiting for you")
equal(oneTurn.sessions, 1, "one session id is one session")

equal(summarise([event("a", .notify, 0), event("a", .prompt, 45)], cap: cap).totals.blocked, 45,
      "notify to the next event is time blocked on a permission prompt")

let lunch = summarise([event("a", .stop, 0), event("a", .prompt, 3600)], cap: cap)
equal(lunch.totals.waiting, 0, "a gap over the cap is not counted as waiting")
equal(lunch.totals.away, 3600, "it is reported as away instead of vanishing")

let crashed = summarise([event("a", .prompt, 0), event("a", .stop, 7200)], cap: cap)
equal(crashed.totals.worked, 0,
      "the cap applies to working time too: a killed session cannot gift you two hours")

let interleaved = summarise([event("a", .prompt, 0), event("b", .prompt, 10),
                             event("a", .stop, 60), event("b", .stop, 100)], cap: cap)
equal(interleaved.totals.worked, 150, "sessions are paired separately, not by arrival order")
equal(interleaved.sessions, 2, "both sessions are counted")

let mixed = summarise([event("a", .prompt, 0, project: "topscan"),
                       event("a", .stop, 120, project: "topscan"),
                       event("b", .prompt, 0), event("b", .stop, 30)], cap: cap)
equal(mixed.projects.map(\.name), ["topscan", "cuelight"],
      "projects are listed busiest first")
equal(mixed.projects.first?.totals.worked, 120, "time lands on the right project")

equal(summarise([event("a", .stop, 0)], cap: cap).totals, Totals(),
      "a single event brackets no gap and contributes nothing")

equal(formatDuration(45), "45s", "under a minute is shown in seconds")
equal(formatDuration(90), "1m", "minutes are truncated, not rounded up to an hour")
equal(formatDuration(3600 + 12 * 60), "1h 12m", "hours and minutes")
equal(formatDuration(3600 + 5 * 60), "1h 05m", "minutes are padded, so columns line up")

// MARK: - periods and formats

section("periods and formats")

check(Period.all.start(now: noon) == nil, "'all time' has no lower bound, so every log is read")
equal(Period.week.start(now: noon), noon.addingTimeInterval(-7 * day),
      "a week is a rolling window, not a calendar one")
equal(Period.allCases.map(\.rawValue), ["week", "month", "year", "all"],
      "the periods the picker offers are the periods the flags accept")

let sample = summarise([event("a", .prompt, 0, project: "topscan"),
                        event("a", .stop, 120, project: "topscan"),
                        event("a", .prompt, 180, project: "topscan")], cap: cap)

let markdown = renderMarkdown(sample, label: "last 7 days", cap: cap)
check(markdown.contains("| worked | 2m |"), "markdown carries the headline totals")
check(markdown.contains("| topscan | 2m | 1m |"), "markdown carries the per-project rows")
check(markdown.contains("### cuelight — last 7 days"), "markdown names the app, not one agent")

let json = renderJSON(sample, period: .week, now: noon, cap: cap)
check(json.contains("\"worked\" : 120"), "JSON reports whole seconds")
check(json.contains("\"idleCapSeconds\" : 300"), "JSON says which cap produced the numbers")
check(json.contains("\"name\" : \"topscan\""), "JSON carries the project breakdown")

let table = renderText([Summary(label: "last 7 days", report: sample)],
                       projects: sample, cap: cap)
check(table.contains("waiting on you 1m"), "the table carries the headline totals")
check(table.contains("1 session"), "a single session is not pluralised")

// MARK: - agent table

section("agent table")

equal(AgentSpec.all.count, 6, "six agents are supported")
equal(Set(AgentSpec.all.map(\.id)).count, 6, "agent ids are unique")

for agent in AgentSpec.all {
    let arguments = agent.events.map(\.argument)
    check(arguments.contains("prompt"), "\(agent.id) reports work in flight")
    check(arguments.contains("stop"), "\(agent.id) reports a finished turn")
    check(agent.events.allSatisfy { ["prompt", "stop", "notify", "end"].contains($0.argument) },
          "\(agent.id) only uses the canonical arguments")
    check(agent.hook(for: "no-such-event") == nil, "\(agent.id) ignores an unknown raw event")
    check(AgentSpec.find(agent.id)?.id == agent.id, "find round-trips \(agent.id)")
    check(!agent.configPath.hasPrefix("/"),
          "\(agent.id) stores a path relative to the home root")
}

check(AgentSpec.find("no-such-agent") == nil, "an unknown agent id is not found")

// MARK: - reply contract

section("hook reply contract")

func replyJSON(_ agent: String, _ raw: String) -> [String: Any]? {
    guard let reply = spec(agent).hook(for: raw)?.reply, !reply.isEmpty,
          let json = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
    else { return nil }
    return json
}

for agent in AgentSpec.all {
    for hook in agent.events where !hook.reply.isEmpty {
        check((try? JSONSerialization.jsonObject(with: Data(hook.reply.utf8))) != nil,
              "\(agent.id) \(hook.raw) replies with valid JSON")
    }
}

equal(replyJSON("antigravity", "PreToolUse")?["decision"] as? String, "allow",
      "Antigravity's blocked question is allowed through")
equal(replyJSON("antigravity", "Stop")?["decision"] as? String, "allow",
      "Antigravity's Stop is allowed through")
equal(spec("cursor").events.map(\.reply), ["{}", "{}", "{}"],
      "every Cursor hook replies with an empty object")
equal(spec("claude").events.map(\.reply), ["", "", "", "", ""],
      "Claude's hooks print nothing, stdout would be injected as context")
equal(spec("gemini").defaultReply, "", "Gemini's hooks print nothing on an unknown event")
equal(spec("antigravity").defaultReply, "{}", "Antigravity's unknown event still gets JSON")
equal(spec("cursor").defaultReply, "{}", "Cursor's unknown event still gets JSON")

// MARK: - payload normalisation

section("payload normalisation")

let claude = spec("claude")
equal(payloadSessionID(["session_id": "abc"], keys: claude.sessionKeys), "abc",
      "Claude's session id is read from session_id")
equal(payloadCwd(["cwd": "/w/proj"], keys: claude.cwdKeys), "/w/proj",
      "Claude's cwd is read from cwd")
equal(projectName(cwd: payloadCwd(["cwd": "/w/proj"], keys: claude.cwdKeys)), "proj",
      "only the project basename is kept")
equal(payloadSessionID([:], keys: claude.sessionKeys), nil,
      "a missing session id is nil, not a guess")
equal(payloadCwd([:], keys: claude.cwdKeys), nil, "a missing cwd is nil")
equal(projectName(cwd: nil), "unknown", "and the project is simply unknown")

let gemini = spec("gemini")
equal(payloadSessionID(["session_id": "g1"], keys: gemini.sessionKeys), "g1",
      "Gemini uses the same payload shape as Claude")

let codex = spec("codex")
equal(payloadSessionID(["session_id": "x1"], keys: codex.sessionKeys), "x1",
      "Codex uses the same payload shape as Claude")

let antigravity = spec("antigravity")
equal(payloadSessionID(["conversationId": "c1"], keys: antigravity.sessionKeys), "c1",
      "Antigravity's session id is read from conversationId")
equal(payloadCwd(["workspacePaths": ["/w/proj", "/w/other"]], keys: antigravity.cwdKeys),
      "/w/proj", "Antigravity's workspace array takes the first path")
equal(projectName(cwd: payloadCwd(["workspacePaths": ["/w/proj"]], keys: antigravity.cwdKeys)),
      "proj", "and the project basename comes out")

let cursor = spec("cursor")
equal(payloadSessionID(["conversation_id": "c2"], keys: cursor.sessionKeys), "c2",
      "Cursor's session id is read from conversation_id")
equal(payloadCwd(["workspace_roots": ["/w/proj"]], keys: cursor.cwdKeys), "/w/proj",
      "Cursor's workspace array takes the first path")

let opencode = spec("opencode")
equal(payloadPID(["pid": 4242]).map(Int.init), 4242, "the opencode plugin's pid is read back")
equal(payloadPID(["pid": -1]), nil, "a negative pid is refused")
equal(payloadPID(["pid": "4242"]), nil, "a string pid is refused")
equal(payloadPID([:]), nil, "an absent pid is nil, so the ancestor walk runs")

equal(payloadSessionID(["session_id": ""], keys: ["session_id"]), nil,
      "an empty string is not a session id")
equal(payloadSessionID(["session_id": ["a", "b"]], keys: ["session_id"]), "a",
      "an array value takes the first element")
equal(payloadCwd(["workspacePaths": [""]], keys: ["workspacePaths"]), nil,
      "an empty first element yields nothing rather than an empty project")

// MARK: - hook merging
//
// This one writes to the user's settings.json in production, so it gets the most care.
// Every flavour is tested with foreign content, because a merge that drops someone
// else's hooks is worse than no merge at all.

section("hook merging: claude")

func nestedCommands(_ settings: [String: Any], _ event: String) -> [String] {
    let hooks = settings["hooks"] as? [String: Any] ?? [:]
    let groups = hooks[event] as? [[String: Any]] ?? []
    return groups.flatMap {
        ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
    }
}

let foreignClaude: [String: Any] = [
    "model": "opus",
    "hooks": [
        "Stop": [["hooks": [["type": "command", "command": "someone-elses-hook.sh"]]]],
        "PreToolUse": [["hooks": [["type": "command", "command": "another.sh"]]]],
    ],
]

let installedClaude = HookMerge.install(claude, into: foreignClaude,
                                        executable: "/Applications/cuelight.app/x")

check(installedClaude["model"] as? String == "opus", "unrelated top-level keys are preserved")
check(nestedCommands(installedClaude, "Stop").contains("someone-elses-hook.sh"),
      "a foreign hook on an event we also use is preserved")
check(nestedCommands(installedClaude, "Stop").contains { isOurCommand($0) },
      "our hook is added alongside it")
check(nestedCommands(installedClaude, "Stop").contains { $0.contains("hook claude stop") },
      "the command carries the agent id")
check(nestedCommands(installedClaude, "PreToolUse") == ["another.sh"],
      "an event we do not use is left completely alone")
check(HookMerge.installed(claude, in: installedClaude, executable: "/Applications/cuelight.app/x"),
      "install is detected afterwards")

let twice = HookMerge.install(claude, into: installedClaude,
                              executable: "/Applications/cuelight.app/x")
equal(nestedCommands(twice, "Stop").filter { isOurCommand($0) }.count, 1,
      "installing twice does not duplicate our hook")

let moved = HookMerge.install(claude, into: installedClaude, executable: "/new/path/cuelight")
equal(nestedCommands(moved, "Stop").filter { isOurCommand($0) }.count, 1,
      "a moved bundle replaces the old entry instead of adding a second")
check(nestedCommands(moved, "Stop").contains { $0.contains("/new/path/cuelight") },
      "the replacement points at the new location")
check(nestedCommands(moved, "Stop").contains("someone-elses-hook.sh"),
      "moving still preserves foreign hooks")

let removedClaude = HookMerge.remove(claude, from: installedClaude)
check(!nestedCommands(removedClaude, "Stop").contains { isOurCommand($0) },
      "remove takes our hook out")
check(nestedCommands(removedClaude, "Stop").contains("someone-elses-hook.sh"),
      "remove leaves foreign hooks in place")
check(!HookMerge.installed(claude, in: removedClaude, executable: "/Applications/cuelight.app/x"),
      "removal is detected")
check((removedClaude["hooks"] as? [String: Any])?["Notification"] == nil,
      "an event that held only our hook is dropped entirely")

let virgin = HookMerge.remove(claude, from: ["model": "opus"])
check(virgin["hooks"] == nil, "removing from settings without hooks does not invent a hooks key")
equal(virgin["model"] as? String, "opus", "and does not touch anything else")

check(!claude.events.contains { $0.raw == "SubagentStop" },
      "SubagentStop stays unhooked, or subagents would blink for the main agent")

section("hook merging: gemini")

let geminiSettings = HookMerge.install(
    gemini,
    into: [
        "theme": "dark",
        "hooks": [
            "enabled": true,
            "BeforeAgent": [[
                "matcher": "chat",
                "hooks": [["name": "someone", "type": "command",
                           "command": "foreign.sh", "timeout": 9]],
            ]],
            "SessionStart": [[
                "matcher": "*",
                "hooks": [["name": "someone-else", "type": "command",
                           "command": "session-start.sh", "timeout": 9]],
            ]],
        ],
    ],
    executable: "/x/cuelight")

let geminiHooks = geminiSettings["hooks"] as? [String: Any] ?? [:]
check(geminiSettings["theme"] as? String == "dark", "other top-level keys are untouched")
check(geminiHooks["enabled"] as? Bool == true, "non-event keys of the hooks object are untouched")
check((geminiHooks["BeforeAgent"] as? [[String: Any]])?.contains {
    ($0["matcher"] as? String) == "chat"
} == true, "a foreign matcher group is never replaced")

func geminiNamedEntry(_ settings: [String: Any], _ event: String,
                      _ name: String) -> [String: Any]? {
    let hooks = settings["hooks"] as? [String: Any] ?? [:]
    let groups = hooks[event] as? [[String: Any]] ?? []
    return groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
        .first { ($0["name"] as? String) == name }
}

equal(geminiNamedEntry(geminiSettings, "AfterAgent", "cuelight-stop")?["timeout"] as? Int, 5000,
      "our gemini entry is named and carries a timeout in milliseconds")
check((geminiNamedEntry(geminiSettings, "AfterAgent", "cuelight-stop")?["type"] as? String)
      == "command", "our gemini entry is a command handler")
check(HookMerge.installed(gemini, in: geminiSettings, executable: "/x/cuelight"),
      "gemini install is detected")

let geminiTwice = HookMerge.install(gemini, into: geminiSettings, executable: "/x/cuelight")
equal(nestedCommands(geminiTwice, "AfterAgent").filter { isOurCommand($0) }.count, 1,
      "installing gemini twice does not duplicate our hook")
equal(nestedCommands(geminiTwice, "BeforeAgent").filter { $0 == "foreign.sh" }.count, 1,
      "and does not duplicate the foreign one either")

let geminiRemoved = HookMerge.remove(gemini, from: geminiSettings)
equal(nestedCommands(geminiRemoved, "AfterAgent"), [],
      "removing ours drops the event key that held only our hook")
equal(nestedCommands(geminiRemoved, "SessionStart"), ["session-start.sh"],
      "events we never touch keep their foreign hooks")
check(nestedCommands(geminiRemoved, "BeforeAgent").contains("foreign.sh"),
      "the foreign gemini hook survives remove")
check((geminiRemoved["hooks"] as? [String: Any])?["enabled"] as? Bool == true,
      "and the hooks object keeps its non-event keys")

section("hook merging: antigravity")

let foreignAntigravity: [String: Any] = [
    "herdr": ["PreInvocation": [["command": "bash herdr.sh", "timeout": 10,
                                 "type": "command"]]],
]

/// Antigravity mixes direct handler lists with matcher groups, so the collector has to
/// look in both places.
func antigravityCommands(_ group: [String: Any], _ event: String) -> [String] {
    let entries = group[event] as? [[String: Any]] ?? []
    return entries.flatMap { entry -> [String] in
        if let nested = entry["hooks"] as? [[String: Any]] {
            return nested.compactMap { $0["command"] as? String }
        }
        return [entry["command"] as? String].compactMap { $0 }
    }
}

let antigravitySettings = HookMerge.install(antigravity, into: foreignAntigravity,
                                            executable: "/x/cuelight")
check(antigravitySettings["herdr"] != nil, "the foreign herdr group is preserved")
let group = antigravitySettings["cuelight"] as? [String: Any] ?? [:]

let preInvocation = group["PreInvocation"] as? [[String: Any]] ?? []
check(preInvocation.first?["hooks"] == nil,
      "PreInvocation takes a direct handler list, not the nested shape")
check((preInvocation.first?["type"] as? String) == "command", "and it is still a handler")
equal(preInvocation.first?["timeout"] as? Int, 5, "with the agreed timeout")

let preToolUse = group["PreToolUse"] as? [[String: Any]] ?? []
equal(preToolUse.first?["matcher"] as? String, "ask_question",
      "PreToolUse is watched only for ask_question")
check(antigravityCommands(group, "Stop").contains { $0.contains("hook antigravity stop") },
      "Stop is wired to the canonical stop argument")
check(HookMerge.installed(antigravity, in: antigravitySettings, executable: "/x/cuelight"),
      "antigravity install is detected")
check(HookMerge.containsOurs(antigravity, in: antigravitySettings),
      "containsOurs sees our group")
check(!HookMerge.installed(antigravity, in: antigravitySettings, executable: "/moved/cuelight"),
      "a moved bundle is not installed at the old path")

let antigravityRemoved = HookMerge.remove(antigravity, from: antigravitySettings)
check(antigravityRemoved["cuelight"] == nil, "remove deletes our group")
check(antigravityRemoved["herdr"] != nil, "and leaves the foreign one")

section("hook merging: codex")

let codexSettings = HookMerge.install(codex, into: ["description": "my hooks"],
                                      executable: "/x/cuelight")
let codexHooks = codexSettings["hooks"] as? [String: Any] ?? [:]
check(codexSettings["description"] as? String == "my hooks",
      "the optional top-level description is preserved")
let codexStop = codexHooks["Stop"] as? [[String: Any]] ?? []
check(!codexStop.isEmpty, "codex events are written")
equal(codexStop.first?["matcher"] as? String, nil, "codex entries have no matcher")
let codexEntry = (codexStop.first?["hooks"] as? [[String: Any]])?.first
equal(codexEntry?["timeout"] as? Int, 5, "codex entries carry a timeout")
check(HookMerge.installed(codex, in: codexSettings, executable: "/x/cuelight"),
      "codex install is detected")
equal(nestedCommands(HookMerge.remove(codex, from: codexSettings), "Stop"), [],
      "removing takes our codex entry out")

section("hook merging: cursor")

let cursorSettings = HookMerge.install(
    cursor,
    into: ["version": 1, "hooks": ["stop": [["command": "foreign-cursor.sh", "timeout": 3]]]],
    executable: "/x/cuelight")
equal(cursorSettings["version"] as? Int, 1, "the version is preserved")
func cursorCommands(_ settings: [String: Any], _ event: String) -> [String] {
    let hooks = settings["hooks"] as? [String: Any] ?? [:]
    return (hooks[event] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
}
check(cursorCommands(cursorSettings, "stop").contains("foreign-cursor.sh"),
      "a foreign cursor hook survives")
check(cursorCommands(cursorSettings, "stop").contains { isOurCommand($0) },
      "our cursor hook is appended to the same array")
equal(cursorCommands(cursorSettings, "stop").filter { isOurCommand($0) }.count, 1,
      "installing cursor twice does not duplicate our hook")
check(HookMerge.installed(cursor, in: cursorSettings, executable: "/x/cuelight"),
      "cursor install is detected")

let cursorRemoved = HookMerge.remove(cursor, from: cursorSettings)
equal(cursorCommands(cursorRemoved, "stop"), ["foreign-cursor.sh"],
      "remove strips only ours and keeps the foreign entry")
equal(cursorRemoved["version"] as? Int, 1, "and never drops the version")

let versionless = HookMerge.install(cursor, into: [:], executable: "/x/cuelight")
equal(versionless["version"] as? Int, 1, "a versionless file gains a version")

// MARK: - command recognition

section("command recognition")

check(isOurCommand("\"/Applications/cuelight.app/Contents/MacOS/cuelight\" hook claude stop"),
      "a quoted bundle path is ours")
check(isOurCommand("cuelight hook stop"), "a bare command is ours")
check(!isOurCommand("someone-elses-hook.sh"), "a foreign command is not ours")
check(!isOurCommand("/opt/homebrew/bin/something-else"), "another tool is not ours")

let foreignStop: [String: Any] = [
    "hooks": ["Stop": [["hooks": [["type": "command",
                                   "command": "someone-elses-hook.sh"]]]]],
]
check(!HookMerge.containsOurs(claude, in: foreignStop),
      "a foreign hook is not mistaken for ours")

// MARK: - opencode plugin

section("opencode plugin")

let pluginHome = scratch.appendingPathComponent("opencode-home", isDirectory: true)
let pluginURL = OpencodePlugin.url(home: pluginHome)
let pluginExecutable = "/Applications/cuelight.app/Contents/MacOS/cuelight"

check(!OpencodePlugin.isOurs(at: pluginURL), "no plugin file means not installed")
try? OpencodePlugin.install(into: pluginHome, executable: pluginExecutable)
check(OpencodePlugin.isOurs(at: pluginURL), "installing writes a file we recognise")

let pluginText = (try? String(contentsOf: pluginURL, encoding: .utf8)) ?? ""
check(pluginText.hasPrefix(OpencodePlugin.marker), "the marker is the first line")
check(pluginText.contains(pluginExecutable), "the template points at the executable")
check(pluginText.contains("[\"hook\", \"opencode\", rawEvent]"),
      "the spawn args call this binary's hook command")
for raw in opencode.events.map(\.raw) {
    check(pluginText.contains("\"\(raw)\""), "the template forwards \(raw)")
}
check(!pluginText.contains("\"session.updated\""),
      "raw events we do not need are not forwarded")
check(!pluginText.contains("\"message.updated\""),
      "streaming updates are not forwarded, one process per token would be a flood")
check(pluginText.contains("parentID"), "child sessions are tracked")
check(pluginText.contains("process.pid"), "the plugin sends its own pid")

// A user's own file at the same path is not ours to delete.
try? "// my own opencode plugin".write(to: pluginURL, atomically: true, encoding: .utf8)
OpencodePlugin.remove(from: pluginHome)
check(FileManager.default.fileExists(atPath: pluginURL.path),
      "remove leaves a foreign file at the same path alone")

try? OpencodePlugin.template(executable: pluginExecutable)
    .write(to: pluginURL, atomically: true, encoding: .utf8)
OpencodePlugin.remove(from: pluginHome)
check(!FileManager.default.fileExists(atPath: pluginURL.path),
      "remove deletes our own file")

// MARK: -

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("PASS")
