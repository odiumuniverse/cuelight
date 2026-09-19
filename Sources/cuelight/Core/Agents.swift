// Agents.swift -- the agents cuelight can watch, and the hooks each of them fires.
//
// All of it is data: one row per agent, read by the merge engines, the CLI hook path
// and the menu. Adding an agent is adding a row here, and the tests iterate
// AgentSpec.all, so a new row cannot silently skip the checks.

import Foundation

/// How an agent keeps its hook configuration, and therefore which merge engine owns it.
enum HookFlavor {
    case claudeSettings
    case geminiSettings
    case antigravityHooks
    case codexHooks
    case cursorHooks
    case opencodePlugin    // a JS file, not JSON at all
}

/// One hook we install: the agent's own raw event name, the canonical argument passed
/// back to `cuelight hook`, and the exact stdout that hook has to produce.
struct EventHook {
    let raw: String
    let argument: String   // "prompt" | "stop" | "notify" | "end"
    let reply: String      // "" means print nothing
}

struct AgentSpec {
    let id: String
    let name: String
    let flavor: HookFlavor
    let configPath: String     // relative to the home root: ".claude/settings.json"
    let events: [EventHook]
    let sessionKeys: [String]  // first present key wins
    let cwdKeys: [String]      // a string or an array of strings; arrays take the first
    let processNames: [String] // lowercase components to look for in an ancestor path
    let providesPID: Bool      // only opencode: its plugin sends process.pid
    let defaultReply: String   // printed when the agent or the event is unknown

    func hook(for raw: String) -> EventHook? {
        events.first { $0.raw == raw }
    }

    static func find(_ id: String) -> AgentSpec? {
        all.first { $0.id == id }
    }
}

/// True when a command string contains our name anywhere. Deliberately loose: it must
/// catch a moved bundle and the quoted paths agents write, not just one spelling.
func isOurCommand(_ command: String) -> Bool {
    command.contains(ourCommandName)
}

/// The one name a hook command can carry and still be ours. Nothing else counts.
let ourCommandName = "cuelight"

// MARK: - the table

extension AgentSpec {
    static let all: [AgentSpec] = [
        AgentSpec(
            id: "claude",
            name: "Claude Code",
            flavor: .claudeSettings,
            configPath: ".claude/settings.json",
            events: [
                EventHook(raw: "UserPromptSubmit", argument: "prompt", reply: ""),
                EventHook(raw: "Stop", argument: "stop", reply: ""),
                EventHook(raw: "Notification", argument: "notify", reply: ""),
                // A tool ran, so whatever a notification was blocking on is resolved.
                // Without this the lamp keeps blinking after you approve a permission
                // prompt, right up until your next message.
                EventHook(raw: "PostToolUse", argument: "prompt", reply: ""),
                EventHook(raw: "SessionEnd", argument: "end", reply: ""),
                // SubagentStop is deliberately absent: it is what keeps subagents from
                // blinking the light on behalf of the main agent.
            ],
            sessionKeys: ["session_id"],
            cwdKeys: ["cwd"],
            processNames: ["claude"],
            providesPID: false,
            defaultReply: ""
        ),
        AgentSpec(
            id: "opencode",
            name: "opencode",
            flavor: .opencodePlugin,
            configPath: ".config/opencode/plugins/cuelight.js",
            events: [
                EventHook(raw: "chat.message", argument: "prompt", reply: ""),
                EventHook(raw: "session.idle", argument: "stop", reply: ""),
                EventHook(raw: "permission.asked", argument: "notify", reply: ""),
                EventHook(raw: "question.asked", argument: "notify", reply: ""),
                // A reply or a rejection ends the block, exactly like a tool finishing.
                EventHook(raw: "permission.replied", argument: "prompt", reply: ""),
                EventHook(raw: "question.replied", argument: "prompt", reply: ""),
                EventHook(raw: "question.rejected", argument: "prompt", reply: ""),
                EventHook(raw: "session.deleted", argument: "end", reply: ""),
            ],
            sessionKeys: ["session_id"],
            cwdKeys: ["cwd"],
            processNames: ["opencode"],
            providesPID: true,
            defaultReply: ""
        ),
        AgentSpec(
            id: "gemini",
            name: "Gemini CLI",
            flavor: .geminiSettings,
            configPath: ".gemini/settings.json",
            events: [
                EventHook(raw: "BeforeAgent", argument: "prompt", reply: ""),
                EventHook(raw: "AfterAgent", argument: "stop", reply: ""),
                EventHook(raw: "Notification", argument: "notify", reply: ""),
                EventHook(raw: "AfterTool", argument: "prompt", reply: ""),
                EventHook(raw: "SessionEnd", argument: "end", reply: ""),
            ],
            sessionKeys: ["session_id"],
            cwdKeys: ["cwd"],
            processNames: ["gemini"],
            providesPID: false,
            defaultReply: ""
        ),
        AgentSpec(
            id: "antigravity",
            name: "Antigravity",
            flavor: .antigravityHooks,
            configPath: ".gemini/config/hooks.json",
            events: [
                EventHook(raw: "PreInvocation", argument: "prompt", reply: "{}"),
                EventHook(raw: "PostToolUse", argument: "prompt", reply: "{}"),
                // ask_question is the tool that blocks on the user, so it is the only
                // PreToolUse we watch. Answering "allow" keeps the question unblocked.
                EventHook(raw: "PreToolUse", argument: "notify", reply: #"{"decision":"allow"}"#),
                EventHook(raw: "Stop", argument: "stop", reply: #"{"decision":"allow"}"#),
            ],
            sessionKeys: ["conversationId"],
            cwdKeys: ["workspacePaths"],
            processNames: ["agy", "antigravity"],
            providesPID: false,
            defaultReply: "{}"
        ),
        AgentSpec(
            id: "codex",
            name: "Codex",
            flavor: .codexHooks,
            configPath: ".codex/hooks.json",
            events: [
                EventHook(raw: "UserPromptSubmit", argument: "prompt", reply: ""),
                EventHook(raw: "Stop", argument: "stop", reply: ""),
                EventHook(raw: "PermissionRequest", argument: "notify", reply: ""),
                EventHook(raw: "PostToolUse", argument: "prompt", reply: ""),
                EventHook(raw: "SessionEnd", argument: "end", reply: ""),
            ],
            sessionKeys: ["session_id"],
            cwdKeys: ["cwd"],
            processNames: ["codex"],
            providesPID: false,
            defaultReply: ""
        ),
        AgentSpec(
            id: "cursor",
            name: "Cursor",
            flavor: .cursorHooks,
            configPath: ".cursor/hooks.json",
            events: [
                EventHook(raw: "beforeSubmitPrompt", argument: "prompt", reply: "{}"),
                EventHook(raw: "stop", argument: "stop", reply: "{}"),
                EventHook(raw: "sessionEnd", argument: "end", reply: "{}"),
                // beforeShellExecution is deliberately not hooked: returning a
                // permission decision there would make cuelight the decider for every
                // shell command and could approve or block it. The cost is that a
                // mid-turn approval prompt does not light the lamp.
            ],
            sessionKeys: ["conversation_id"],
            cwdKeys: ["workspace_roots"],
            processNames: ["cursor-agent", "cursor"],
            providesPID: false,
            defaultReply: "{}"
        ),
    ]
}
