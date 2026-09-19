// Menu.swift -- the menu bar item and everything reachable from it.

import AppKit
import Foundation
import ServiceManagement

let githubURL = "https://github.com/odiumuniverse/cuelight"
let showNotification = "com.odiumuniverse.cuelight.show"

/// The events the lamp can be told to react to, in menu order, with working-language
/// names rather than the raw values. Off by default: only "Turn finished" and
/// "Permission prompt" are ticked in a fresh install.
private let blinkEventChoices: [(event: SessionEvent, label: String)] = [
    (.stop, "Turn finished"),       // what the README calls "waiting on you"
    (.notify, "Permission prompt"), // what the README calls "blocked"
    (.prompt, "Work in flight"),    // on turns the lamp into a busy light
]

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let registry = KeyboardRegistry()
    private var blinker: Blinker!
    private var accessAtLaunch = InputMonitoring.granted
    private var relaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureDirs()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capslock",
                                           accessibilityDescription: "cuelight")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Ask on launch: without this the keyboards silently look LED-less.
        if !InputMonitoring.granted { InputMonitoring.request() }

        // The privacy database keys on the code signature, and an ad-hoc signature
        // changes with every build -- so a grant given to yesterday's build does not
        // apply today. Record what we actually see, so diagnosing does not rely on
        // guessing from the outside.
        diagnose("launched from \(Bundle.main.bundlePath)")
        diagnose("input monitoring: \(InputMonitoring.description)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            let inventory = self?.registry.inventory() ?? []
            diagnose("keyboards seen: \(inventory.count), " +
                     "drivable: \(inventory.filter(\.drivable).count)")
            for keyboard in inventory {
                diagnose("  \(keyboard.name): capsLED=\(keyboard.drivable)")
            }
        }

        // `cuelight show` brings a hidden icon back from the command line.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showIcon),
            name: Notification.Name(showNotification), object: nil)

        // Hooks are installed by hand, from the Agent hooks submenu or `cuelight hooks
        // install`. All launch does is re-point hooks that are already ours at this
        // bundle: a moved app must not leave a dead path behind.
        Hooks.repointInstalled()

        registry.start()
        blinker = Blinker(registry: registry)
        blinker.start()

        // An Input Monitoring change only reaches a fresh process. Granting it while we
        // run would otherwise leave the app permanently broken-looking, so restart.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !self.relaunching,
                  InputMonitoring.granted != self.accessAtLaunch else { return }
            self.relaunching = true
            self.relaunch()
        }
    }

    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to be gone before reopening, or macOS reactivates it
        // instead of starting the replacement.
        task.arguments = ["-c", "sleep 1; open \"\(Bundle.main.bundlePath)\""]
        try? task.run()
        blinker?.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        blinker?.stop()
    }

    // Rebuilt on every open: keyboards come and go, and so does the waiting state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = Config.load()

        // Without Input Monitoring the keyboards look like they have no LED, so lead
        // with the real reason instead of letting the list mislead.
        guard InputMonitoring.granted else {
            let problem = NSMenuItem(title: "Input Monitoring is off", action: nil,
                                     keyEquivalent: "")
            problem.isEnabled = false
            menu.addItem(problem)

            let explain = NSMenuItem(title: "cuelight cannot reach the LEDs without it",
                                     action: nil, keyEquivalent: "")
            explain.isEnabled = false
            menu.addItem(explain)
            menu.addItem(.separator())

            let fix = NSMenuItem(title: "Open Privacy settings…",
                                 action: #selector(openInputMonitoring), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
            menu.addItem(.separator())

            let quit = NSMenuItem(title: "Quit cuelight", action: #selector(quit),
                                  keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
            return
        }

        // Counted by what "waiting" has always meant, not by the Blink on choice: a
        // ticked-off event still means the agent needs you, it just does not blink.
        let waiting = readSessions().filter { defaultBlinkingEvents.contains($0.event) }.count
        let header = NSMenuItem(
            title: waiting == 0 ? "No session waiting"
                                : "\(waiting) session\(waiting == 1 ? "" : "s") waiting",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let keyboardHeader = NSMenuItem(title: "Blink on keyboards", action: nil,
                                        keyEquivalent: "")
        keyboardHeader.isEnabled = false
        menu.addItem(keyboardHeader)

        let inventory = registry.inventory()
        if inventory.isEmpty {
            let none = NSMenuItem(title: "no keyboards detected", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for keyboard in inventory {
            let item = NSMenuItem(title: keyboard.name, action: #selector(toggleKeyboard(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = keyboard.name
            if keyboard.drivable {
                item.state = config.selects(keyboard.name) ? .on : .off
            } else {
                // No caps LED: nothing to drive, so do not pretend it is a choice.
                item.action = nil
                item.title = "\(keyboard.name) — no caps LED"
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(blinkForItem(config: config))
        menu.addItem(blinkOnItem(config: config))
        menu.addItem(.separator())

        let stats = NSMenuItem(title: "Statistics…", action: #selector(openStats),
                               keyEquivalent: "")
        stats.target = self
        menu.addItem(stats)
        menu.addItem(.separator())

        menu.addItem(agentHooksItem())

        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLogin(_:)),
                               keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let hide = NSMenuItem(title: "Hide icon", action: #selector(hideIcon),
                              keyEquivalent: "h")
        hide.target = self
        hide.toolTip = "Keeps blinking. Launch cuelight again, or run `cuelight show`, "
            + "to bring the icon back."
        menu.addItem(hide)

        let github = NSMenuItem(title: "Visit GitHub", action: #selector(openGitHub),
                                keyEquivalent: "")
        github.target = self
        menu.addItem(github)

        let quit = NSMenuItem(title: "Quit cuelight", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// AppKit closes a menu as soon as an item is chosen. For tick boxes that is the
    /// wrong feel -- you want to see the tick land, and tick a second keyboard without
    /// reopening. Reopening immediately is the only way to keep a stock NSMenu up.
    private func reopenMenu() {
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    @objc private func toggleKeyboard(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var config = Config.load()
        let drivable = registry.inventory().filter(\.drivable).map(\.name)
        config.keyboards = Selection.toggle(name, current: config.keyboards, drivable: drivable)
        config.save()
        registry.reopen()
        reopenMenu()
    }

    /// No reopenMenu here, unlike the keyboard ticks: this is a one-of-four choice, so
    /// there is nothing to pick next.
    @objc private func setBlinkTimeout(_ sender: NSMenuItem) {
        var config = Config.load()
        config.blinkTimeoutSeconds = sender.representedObject as? TimeInterval
        config.save()
    }

    /// Like the keyboard ticks, this one reopens: the point of the submenu is to tick
    /// several events in one visit.
    @objc private func toggleBlinkingEvent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let event = SessionEvent(rawValue: raw) else { return }
        var config = Config.load()
        config.toggleBlinking(event)
        config.save()
        reopenMenu()
    }

    @objc private func toggleHooks(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let spec = AgentSpec.find(id) else { return }
        do {
            if Hooks.installed(spec) { try Hooks.remove(spec) } else { try Hooks.install(spec) }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not update ~/\(spec.configPath)"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
        reopenMenu()
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("cuelight: login item toggle failed: \(error)")
        }
        reopenMenu()
    }

    @objc private func openStats() {
        StatsWindow.shared.show()
    }

    @objc private func openInputMonitoring() {
        InputMonitoring.request()      // no-op once the user has answered once
        InputMonitoring.openSettings()
    }

    /// Hiding only takes the icon out of the menu bar. The blinking is the point of the
    /// app, so it keeps running.
    @objc private func hideIcon() {
        statusItem.isVisible = false
    }

    @objc private func showIcon() {
        statusItem.isVisible = true
    }

    /// Launching an already-running app does not start a second copy, it reopens this
    /// one -- which is how a hidden icon comes back.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        showIcon()
        return true
    }

    @objc private func openGitHub() {
        if let url = URL(string: githubURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func quit() {
        blinker.stop()
        NSApp.terminate(nil)
    }
}

// MARK: - submenu builders
//
// Kept out of the class body so the menu builder stays one flat, readable run of
// construction and every submenu can be reasoned about on its own.

extension AppDelegate {
    /// A submenu rather than four more rows: the keyboard list is already the long
    /// part of this menu, and the timeout is set once and then forgotten.
    fileprivate func blinkForItem(config: Config) -> NSMenuItem {
        let blinkFor = NSMenuItem(title: "Blink for", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        for preset in BlinkTimeout.presets {
            let item = NSMenuItem(title: preset.label, action: #selector(setBlinkTimeout(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = preset.seconds     // nil means forever
            item.state = preset == config.blinkTimeout ? .on : .off
            choices.addItem(item)
        }
        // A hand-edited config can hold a value no preset offers. Show it rather than
        // leaving the submenu with nothing ticked.
        if !BlinkTimeout.presets.contains(config.blinkTimeout) {
            let custom = NSMenuItem(title: config.blinkTimeout.label, action: nil,
                                    keyEquivalent: "")
            custom.state = .on
            choices.addItem(custom)
        }
        blinkFor.submenu = choices
        return blinkFor
    }

    /// Which events count as "needs you" is a separate choice from how long the lamp
    /// blinks for, so it is a sibling submenu. Unticking everything is a real choice
    /// here (the lamp just never lights); see Config.blinksOn.
    fileprivate func blinkOnItem(config: Config) -> NSMenuItem {
        let blinkOn = NSMenuItem(title: "Blink on", action: nil, keyEquivalent: "")
        let events = NSMenu()
        for choice in blinkEventChoices {
            let item = NSMenuItem(title: choice.label,
                                  action: #selector(toggleBlinkingEvent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.event.rawValue
            item.state = config.blinksOn.contains(choice.event) ? .on : .off
            events.addItem(item)
        }
        blinkOn.submenu = events
        return blinkOn
    }

    /// Manual only: installing hooks is a deliberate choice, never something the app
    /// does to an agent behind your back. Each item shows one agent's state.
    fileprivate func agentHooksItem() -> NSMenuItem {
        let agentHooks = NSMenuItem(title: "Agent hooks", action: nil, keyEquivalent: "")
        let agents = NSMenu()
        for spec in AgentSpec.all {
            let item = NSMenuItem(title: spec.name, action: #selector(toggleHooks(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = spec.id
            item.toolTip = "~/\(spec.configPath)"
            item.state = Hooks.installed(spec) ? .on : .off
            agents.addItem(item)
        }
        agentHooks.submenu = agents
        return agentHooks
    }
}
