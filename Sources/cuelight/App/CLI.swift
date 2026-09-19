// CLI.swift -- the face cuelight shows when it is given arguments.

import Foundation
import IOKit
import IOKit.hid

func cliDevices(namesOnly: Bool) {
    let config = Config.load()
    let keyboards = HID.enumerate()
    if namesOnly {
        // Consumed by shell completion: one name per line, nothing else.
        for keyboard in keyboards where keyboard.drivable { print(keyboard.name) }
        return
    }
    guard !keyboards.isEmpty else { print("no keyboards found"); return }
    print(config.keyboards.isEmpty
          ? "blinking on: all keyboards"
          : "blinking on: \(config.keyboards.joined(separator: ", "))")
    print("")
    for keyboard in keyboards {
        let mark = keyboard.drivable ? (config.selects(keyboard.name) ? "[x]" : "[ ]") : "[-]"
        print("\(mark) \(keyboard.name)")
        print("    vid=\(keyboard.vendor) pid=\(keyboard.product) " +
              "transport=\(keyboard.transport) capsLED=\(keyboard.drivable ? "yes" : "no")")
    }
}

func cliTest(_ query: String) {
    let matches = HID.enumerate().filter {
        query.isEmpty || $0.name.lowercased().contains(query.lowercased())
    }
    guard !matches.isEmpty else {
        print("no keyboard matching '\(query)'")
        exit(1)
    }
    for keyboard in matches {
        guard let element = keyboard.element else {
            print("\(keyboard.name): no caps LED, cannot be driven")
            continue
        }
        guard IOHIDDeviceOpen(keyboard.device, 0) == kIOReturnSuccess else {
            print("\(keyboard.name): open failed")
            continue
        }
        print("\(keyboard.name): LED on for 3s, watch it")
        // Re-assert: a single write fades on some Bluetooth keyboards.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            IOHIDDeviceSetValue(keyboard.device, element,
                IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 1))
            Thread.sleep(forTimeInterval: 0.05)
        }
        IOHIDDeviceSetValue(keyboard.device, element,
            IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0))
        IOHIDDeviceClose(keyboard.device, 0)
    }
}

func cliStatus() {
    let sessions = readSessions()
    guard !sessions.isEmpty else { print("no sessions tracked"); return }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    let blinking = Config.load().blinksOn
    for session in sessions.sorted(by: { $0.at < $1.at }) {
        let state = blinking.contains(session.event) ? "BLINKING" : "quiet"
        let process = session.pid == 0
            ? "pid unknown"
            : (isAlive(session.pid) ? "pid \(session.pid)" : "pid \(session.pid) DEAD")
        print("\(session.id)  \(session.agent)  \(session.event.rawValue)  " +
              "\(formatter.string(from: session.at))  \(process)  \(state)")
    }
}

/// `cuelight blink` reports, `cuelight blink <value>` sets. The running app picks the
/// change up within a second; nothing needs restarting.
func cliBlink(_ argument: String?) {
    var config = Config.load()

    guard let argument, !argument.isEmpty else {
        switch config.blinkTimeout {
        case .forever:
            print("blinking until answered")
        case .after(let seconds):
            print("blinking for \(config.blinkTimeout.label) (\(Int(seconds))s), "
                  + "then dark until the next event")
        }
        return
    }

    guard let timeout = BlinkTimeout.parse(argument) else {
        print("cannot read '\(argument)' as a duration; try 5m, 30m, 90s, 1h or always")
        exit(2)
    }

    config.blinkTimeoutSeconds = timeout.seconds
    config.save()
    print(timeout == .forever
          ? "blinking until answered"
          : "blinking for \(timeout.label) after a session starts waiting")
}

// MARK: - stats

/// Where a card goes when the picker writes one, and when `--card` is given no path.
private func defaultCardPath(_ period: Period) -> URL {
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withFullDate]
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/cuelight-\(period.rawValue)-"
                                + "\(stamp.string(from: Date())).png")
}

private func writeCard(_ report: Report, period: Period, cap: TimeInterval, to url: URL) {
    guard let png = Card.png(report, label: period.label, cap: cap) else {
        print("could not render the card")
        exit(1)
    }
    do {
        try png.write(to: url)
        print("wrote \(url.path)")
    } catch {
        print("could not write \(url.path): \(error.localizedDescription)")
        exit(1)
    }
}

private func copyToClipboard(_ text: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
    let pipe = Pipe()
    task.standardInput = pipe
    guard (try? task.run()) != nil else { print(text); return }
    pipe.fileHandleForWriting.write(Data(text.utf8))
    try? pipe.fileHandleForWriting.close()
    task.waitUntilExit()
}

func cliStats(_ arguments: [String]) {
    let cap = Config.load().idleCap
    let now = Date()

    if arguments.contains("-i") || arguments.contains("--pick") {
        statsPicker(cap: cap, now: now)
        return
    }

    let period = arguments.compactMap(Period.init(rawValue:)).first
    let card = arguments.contains("--card")
    let json = arguments.contains("--json")
    let markdown = arguments.contains("--md")

    // Bare `cuelight stats` is the two-window view; anything else is one window.
    guard period != nil || card || json || markdown else {
        print(statsText(now: now, cap: cap))
        return
    }

    let chosen = period ?? .week
    let report = chosen.report(now: now, cap: cap)

    if card {
        let explicit = arguments.drop { $0 != "--card" }.dropFirst().first
        let url = explicit.map { URL(fileURLWithPath: $0) } ?? defaultCardPath(chosen)
        writeCard(report, period: chosen, cap: cap, to: url)
    } else if json {
        print(renderJSON(report, period: chosen, now: now, cap: cap))
    } else if markdown {
        print(renderMarkdown(report, label: chosen.label, cap: cap))
    } else {
        print(renderText([Summary(label: chosen.label, report: report)],
                         projects: report, cap: cap))
    }
}

/// Two lists: what to report on, and where to send it. The format follows from the
/// destination -- markdown is for pasting, a PNG is for sharing, a table is for looking
/// at now.
private func statsPicker(cap: TimeInterval, now: Date) {
    guard Term.interactive else {
        print(statsText(now: now, cap: cap))
        return
    }
    guard let periodIndex = choose("Period", Period.allCases.map(\.label)) else { return }
    let period = Period.allCases[periodIndex]

    guard let destination = choose("Send to",
                                   ["show it here", "copy as markdown", "save a PNG card"])
    else { return }

    let report = period.report(now: now, cap: cap)
    switch destination {
    case 0:
        print(renderText([Summary(label: period.label, report: report)],
                         projects: report, cap: cap))
    case 1:
        copyToClipboard(renderMarkdown(report, label: period.label, cap: cap))
        print("copied \(period.label) to the clipboard")
    default:
        writeCard(report, period: period, cap: cap, to: defaultCardPath(period))
    }
}

/// Hooks pipe their JSON on stdin. Read it to EOF first and unconditionally -- the
/// agent may be waiting for the pipe to close -- then print the reply and exit 0 on
/// every path. For Cursor and Antigravity a non-empty reply is parsed as a decision, so
/// nothing here may print a diagnostic before the reply or fail with a non-zero status:
/// a broken hook would block a shell command or abort a run. A malformed or unknown
/// payload is simply ignored.
func cliHook(_ agent: String, _ raw: String) {
    let data = FileHandle.standardInput.readDataToEndOfFile()

    // Unknown agent or event still gets a reply: `{}` if even the agent is unknown.
    let spec = AgentSpec.find(agent)
    let hook = spec?.hook(for: raw)
    let reply = hook?.reply ?? spec?.defaultReply ?? "{}"

    /// Every exit goes through here, so the reply cannot be skipped by a failure path.
    func finish() -> Never {
        if !reply.isEmpty { print(reply) }
        exit(0)
    }

    guard let spec, let hook else { finish() }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawSession = payloadSessionID(json, keys: spec.sessionKeys),
          !rawSession.isEmpty else { finish() }

    let session = safeSessionID(rawSession)
    if hook.argument == "end" {
        forget(session)
        finish()
    }
    guard let event = SessionEvent(rawValue: hook.argument) else { finish() }

    // The opencode plugin sends its own pid; elsewhere the ancestor walk finds the
    // agent. 0 means "unknown", which degrades to the TTL check.
    let pid = spec.providesPID ? (payloadPID(json) ?? agentAncestor(matching: spec.processNames))
                               : agentAncestor(matching: spec.processNames)
    record(session: session, event: event, pid: pid, agent: spec.id)
    logEvent(session: session, event: event,
             project: projectName(cwd: payloadCwd(json, keys: spec.cwdKeys)),
             agent: spec.id)
    finish()
}

// MARK: - hooks

/// `cuelight hooks` prints what to merge by hand; `install` and `remove` do the merge
/// through the same App API the menu uses, so the two can never drift apart.
func cliHooks(_ arguments: [String]) {
    guard let verb = arguments.first else {
        printHookConfigs()
        return
    }
    guard verb == "install" || verb == "remove" else {
        print("unknown hooks command: \(verb)\n")
        print(usage)
        exit(2)
    }

    let target = arguments.count > 1 ? arguments[1] : "all"
    let specs = target == "all" ? AgentSpec.all : [AgentSpec.find(target)].compactMap { $0 }
    guard !specs.isEmpty else {
        print("unknown agent: \(target)")
        print("agents: \(AgentSpec.all.map(\.id).joined(separator: ", ")) | all")
        exit(2)
    }

    for spec in specs {
        do {
            if verb == "install" { try Hooks.install(spec) } else { try Hooks.remove(spec) }
            print("\(verb == "install" ? "installed" : "removed") \(spec.id) — \(spec.name)")
        } catch {
            print("could not \(verb) \(spec.id): \(error.localizedDescription)")
            exit(1)
        }
    }
}

/// The by-hand path: for every agent, the file to edit and the exact JSON (or JS) to
/// put in it, built by the same merge engine the menu calls.
private func printHookConfigs() {
    let encoder: (Any) -> String = { value in
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
    for spec in AgentSpec.all {
        print("\(spec.id) — \(spec.name)")
        if spec.flavor == .opencodePlugin {
            print("  file: ~/\(spec.configPath)")
            print(OpencodePlugin.template(executable: Hooks.executable))
        } else {
            print("  merge into ~/\(spec.configPath):")
            print(encoder(HookMerge.install(spec, into: [:], executable: Hooks.executable)))
        }
        print("")
    }
}

let usage = """
cuelight -- Caps Lock LED indicator for the coding agents you run

  cuelight                     run the menu bar app
  cuelight devices             list keyboards and which ones blink
  cuelight devices --names     names only, for shell completion
  cuelight test <keyboard>     light a keyboard for 3s
  cuelight status              show tracked sessions
  cuelight blink               show how long the lamp blinks for
  cuelight blink <duration>    5m | 30m | 90s | 1h | always
  cuelight stats               time spent, today and over the last 7 days
  cuelight stats <period>      week | month | year | all
  cuelight stats -i            pick a period and a destination with the arrow keys
  cuelight stats … --json      the same numbers, for scripts
  cuelight stats … --md        a markdown table, for pasting
  cuelight stats … --card [f]  a PNG card, for sharing
  cuelight show                bring the menu bar icon back after hiding it
  cuelight hooks               print each agent's hook config, to install by hand
  cuelight hooks install <id>  install hooks: \(AgentSpec.all.map(\.id).joined(separator: " | ")) | all
  cuelight hooks remove <id>   remove them again
  cuelight hook <agent> <event>  internal: called by the hooks themselves

config: ~/.config/cuelight/config.json
"""
