//
//  ChatRuntime.swift
//  rounds
//
//  Per-chat state + streaming. Each chat owns its messages, live text, trace, sources,
//  warm process and task — so multiple chats stream in parallel with independent status.
//

import Foundation
import Observation

@MainActor
@Observable
final class ChatRuntime: Identifiable {
    let id: String
    private unowned let app: AppState

    var messages: [ChatMessage] = []
    var liveText = ""
    var trace: [String] = []
    var statusLine = ""
    var sources: [Source] = []
    var alert: RoundsAlert?
    var sourcesWarning: String?
    var isStreaming = false
    var sessionId: String?
    var generatedTitle: String?
    var liveTokens = 0          // output tokens this turn (live counter shown in the trace)
    private var tokenBase = 0   // tokens from completed messages this turn
    private var lastMsgTokens = 0
    var remoteControlOn = false // Claude Code Remote Control enabled for this chat's session
    private var warmRemote: String?   // the remote-control name the live warm session was started with

    private var warm: WarmSession?
    private var warmModel: RoundsModel?
    private var task: Task<Void, Never>?
    private var titling = false

    init(id: String, app: AppState) {
        self.id = id
        self.app = app
        self.messages = app.loadTranscript(id)
        self.sources = VaultStore.loadChatSources(id, app.vault)
        self.sessionId = app.chats.first { $0.id == id }?.sessionId
    }

    var title: String {
        if let t = generatedTitle, !t.isEmpty { return t }
        if let u = messages.first(where: { $0.role == .user })?.text { return String(u.prefix(60)) }
        return "New chat"
    }

    /// Name the chat from its content with a fast, cheap model call (no tools).
    func generateTitleIfNeeded() {
        guard generatedTitle == nil, !titling, messages.contains(where: { $0.role != .system }) else { return }
        titling = true
        Task {
            defer { titling = false }
            let convo = messages.prefix(4).map { "\($0.role.rawValue): \($0.text.prefix(300))" }.joined(separator: "\n")
            let prompt = "Give a concise 3–6 word title (no quotes, no trailing period) describing this health-app conversation. Reply with ONLY the title.\n\n\(convo)\n\nTitle:"
            var run = app.baseRun(prompt: prompt, policy: ToolPolicy(allowed: [], disallowed: ["Bash", "Task", "WebSearch", "ToolSearch", "Read", "Glob", "Grep", "WebFetch", "mcp__rounds-sources", "Write", "Edit"]), resume: nil)
            run.model = .haiku
            run.includePartial = false
            run.appendSystemPrompt = nil
            run.mcpConfigPath = nil
            run.effort = .default   // titling needs no extra reasoning
            var result = ""
            for await e in ClaudeEngine.stream(run) { if case .finished(let t, _, _, _) = e { result = t } }
            let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
                .components(separatedBy: "\n").first ?? ""
            if !clean.isEmpty {
                generatedTitle = String(clean.prefix(60))
                app.persistChat(id, messages, sources, sessionId, title: generatedTitle)
            }
        }
    }

    // MARK: chat turns

    func send(_ text: String, references: [Reference]) {
        let msg = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        if handleRoundsCommand(msg) { return }   // a Rounds-level command (e.g. /remote-control) — not for Claude
        app.checkRedFlags(msg)   // deterministic Principle-6 net, before the model
        guard !isStreaming else { app.toast = "This chat is still answering — use Stop to interrupt."; return }
        task = Task { await runTurn(msg, references) }
    }

    /// Rounds-level commands handled in-app (NOT sent to Claude). Returns true if it was one.
    /// Works from any chat, and from the Home ask box (which opens a new chat first).
    private func handleRoundsCommand(_ msg: String) -> Bool {
        let lower = msg.lowercased()
        let onCmds: Set<String> = ["/remote-control", "/remote control", "/remote", "/rc",
                                   "/remote-control on", "/remote on", "/rc on"]
        let offCmds: Set<String> = ["/remote-control off", "/remote control off", "/remote off", "/rc off"]
        guard onCmds.contains(lower) || offCmds.contains(lower) else { return false }
        let turnOn = onCmds.contains(lower)
        messages.append(ChatMessage(id: UUID().uuidString, role: .user, text: msg, timestamp: Date()))
        app.persistChat(id, messages, sources, sessionId, title: generatedTitle)
        setRemoteControl(turnOn)
        append(.system, turnOn
               ? "🛰️ Remote control is ON for this chat. Open it from the Claude app or claude.ai to drive the session remotely."
               : "Remote control is off for this chat.")
        return true
    }

    func stop() {
        task?.cancel()
        warm?.stop(); warm = nil; warmModel = nil
        isStreaming = false; statusLine = ""; liveText = ""
    }

    func modelChanged() { warm?.stop(); warm = nil; warmModel = nil; warmRemote = nil }

    /// Toggle Claude Code Remote Control for THIS chat. Restarts the warm session with
    /// `--remote-control` (resuming so context is kept) — then you connect to it from the Claude app
    /// or claude.ai. Off = a plain restart.
    func setRemoteControl(_ on: Bool) {
        guard remoteControlOn != on else { return }
        remoteControlOn = on
        warm?.stop(); warm = nil; warmModel = nil; warmRemote = nil
        ensureWarm()   // start it now so it connects to Remote Control immediately
        app.toast = on
            ? "Remote control on — open this chat from the Claude app or claude.ai to drive it."
            : "Remote control off."
    }

    private func ensureWarm() {
        let rc = remoteControlOn ? "rounds-\(id.prefix(8))" : nil
        if let w = warm, w.isAlive, warmModel == app.selectedModel, warmRemote == rc { return }
        warm?.stop()
        let w = WarmSession(model: app.selectedModel, config: app.chatRun(resume: sessionId, remoteControl: rc))
        do { try w.start(); warm = w; warmModel = app.selectedModel; warmRemote = rc } catch { warm = nil }
    }

    private func runTurn(_ msg: String, _ references: [Reference]) async {
        messages.append(ChatMessage(id: UUID().uuidString, role: .user, text: msg, timestamp: Date(), references: references))
        app.persistChat(id, messages, sources, sessionId, title: generatedTitle)   // shows in Recent immediately
        isStreaming = true
        statusLine = "Thinking…"; liveText = ""; trace = []
        defer { isStreaming = false; statusLine = ""; liveText = "" }

        ensureWarm()
        let firstTurn = (warm?.turnCount ?? 0) == 0
        let prompt = app.chatPrompt(msg, references: references, firstTurn: firstTurn)

        var (parsed, sid, ok): (ParsedTurn, String?, Bool)
        if let w = warm {
            (parsed, sid, ok) = await consume(w.send(prompt))
            if !ok {
                warm?.stop(); warm = nil
                let cold = app.chatPrompt(msg, references: references, firstTurn: true)
                (parsed, sid, ok) = await consume(ClaudeEngine.stream(app.chatRun(prompt: cold, resume: sessionId)))
            }
        } else {
            let cold = app.chatPrompt(msg, references: references, firstTurn: true)
            (parsed, sid, ok) = await consume(ClaudeEngine.stream(app.chatRun(prompt: cold, resume: sessionId)))
        }

        sessionId = warm?.sessionId ?? sid
        let answer = parsed.displayText.isEmpty ? liveText : parsed.displayText
        let finalText = answer.isEmpty ? "I couldn't complete that just now. Please try again." : answer
        messages.append(ChatMessage(id: UUID().uuidString, role: .assistant, text: finalText, timestamp: Date()))
        if !parsed.sources.isEmpty {
            sources = parsed.sources
            Analytics.track(.ranSearch(sourceCount: parsed.sources.count, topTier: parsed.sources.first?.trustTier ?? "none"))
        }
        alert = parsed.alert
        let clinical = parsed.turnMeta["is_clinical"] == true, refused = parsed.turnMeta["refused"] == true
        sourcesWarning = (clinical && parsed.sources.isEmpty && !refused)
            ? "This answer was marked clinical but came without sources. Treat it with caution and confirm with a clinician."
            : nil
        liveText = ""
        // The chat surfaced a NEW or revised next step — the app persists it (chat is read-only) so
        // it shows on the dashboard, and we attach it to this message so it renders inline as a card.
        if !parsed.hypotheses.isEmpty {
            let saved = app.persistChatHypotheses(parsed.hypotheses, sessionId: sessionId)
            if !saved.isEmpty, let idx = messages.lastIndex(where: { $0.role == .assistant }) {
                messages[idx].hypotheses = saved
            }
        }
        app.persistChat(id, messages, sources, sessionId, title: generatedTitle)
        generateTitleIfNeeded()
        // The brain asked to fix/translate/restatus a next-step card — apply it in the
        // background (chat is read-only; the app does the controlled write), then the dashboard refreshes.
        if !parsed.stepActions.isEmpty {
            let actions = parsed.stepActions
            Task { await app.applyStepActions(actions) }
        }
    }

    // MARK: next-steps generation (runs THROUGH this chat so it's a live, openable session)

    /// Drive a next-steps GENERATION run through this chat: seed the request immediately (so the
    /// chat appears and, if opened, shows live work — the trace + streaming text — instead of an
    /// empty/stale view), stream it, then finalize. The model writes the hypothesis files itself;
    /// we return the parsed turn so the caller can raise any alert. Appends to the transcript so a
    /// prior conversation isn't wiped.
    @discardableResult
    func runGeneration(_ run: ClaudeRun, userText: String, title: String, initialStatus: String) async -> ParsedTurn {
        messages.append(ChatMessage(id: UUID().uuidString, role: .user, text: userText, timestamp: Date()))
        generatedTitle = title
        app.persistChat(id, messages, sources, sessionId, title: title)   // visible in Recent at once
        isStreaming = true
        statusLine = initialStatus; liveText = ""; trace = []
        defer { isStreaming = false; statusLine = ""; liveText = "" }

        let (parsed, sid, _) = await consume(ClaudeEngine.stream(run))
        if let sid, !sid.isEmpty { sessionId = sid }
        let answer = parsed.displayText.isEmpty ? liveText : parsed.displayText
        let finalText = answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Updated your next steps — they're on your dashboard." : answer
        messages.append(ChatMessage(id: UUID().uuidString, role: .assistant, text: finalText, timestamp: Date()))
        if !parsed.sources.isEmpty { sources = parsed.sources }
        liveText = ""
        app.persistChat(id, messages, sources, sessionId, title: title)
        return parsed
    }

    // MARK: one-shot (used by intake into this chat's view)

    @discardableResult
    func runOneShot(_ run: ClaudeRun, initialStatus: String) async -> ParsedTurn {
        isStreaming = true
        statusLine = initialStatus; liveText = ""; trace = []
        defer { isStreaming = false; statusLine = ""; liveText = "" }
        let (parsed, sid, _) = await consume(ClaudeEngine.stream(run))
        if let sid, !sid.isEmpty { sessionId = sid }
        return parsed
    }

    /// Re-read this chat from disk. Used when a background pass rewrote the transcript while the
    /// chat was open — e.g. a next-steps regeneration refreshed the per-person "Next steps" chat.
    func reloadFromDisk() {
        guard !isStreaming else { return }
        messages = app.loadTranscript(id)
        sources = VaultStore.loadChatSources(id, app.vault)
        sessionId = app.chats.first { $0.id == id }?.sessionId
    }

    func append(_ role: ChatRole, _ text: String) {
        guard !text.isEmpty else { return }
        messages.append(ChatMessage(id: UUID().uuidString, role: role, text: text, timestamp: Date()))
        app.persistChat(id, messages, sources, sessionId, title: generatedTitle)
        generateTitleIfNeeded()
    }

    // MARK: stream consumption (per-runtime, no global state)

    private func consume(_ stream: AsyncStream<RoundsEvent>) async -> (ParsedTurn, String?, Bool) {
        var fullText = ""
        var sid: String?
        var completed = false
        var hadError = false
        liveTokens = 0; tokenBase = 0; lastMsgTokens = 0
        for await event in stream {
            switch event {
            case .started(let s, _):
                sid = s
            case .usage(let t):
                // output_tokens is cumulative PER message and resets each new message — roll the
                // previous message's total into the base so the displayed counter only grows.
                if t < lastMsgTokens { tokenBase += lastMsgTokens }
                lastMsgTokens = t
                liveTokens = tokenBase + t
            case .slashCommands(let c):
                if !c.isEmpty { app.slashCommands = c }   // power the / autocomplete
            case .textDelta(let t):
                fullText += t
                liveText = ProtocolParser.stripForDisplay(fullText)
            case .toolUse(let n, let i):
                let label = AppState.traceLabel(n, i)
                statusLine = label
                if trace.last != label { trace.append(label) }
            case .toolResult(let payload):
                statusLine = "Reading sources…"
                let c = ProtocolParser.citationsFromToolResult(payload)
                if !c.isEmpty { sources = c }
            case .finished(let t, let s, let e, _):
                if !t.isEmpty { fullText = merge(fullText, t) }
                if !s.isEmpty { sid = s }
                completed = true
                if e {
                    hadError = true
                    if let notice = AppState.billingMessage(t) ?? AppState.billingMessage(fullText) { app.engineNotice = notice }
                }
            case .failed(let m):
                hadError = true
                statusLine = "Error: \(m)"
                if let notice = AppState.billingMessage(m) { app.engineNotice = notice }
            }
        }
        return (ProtocolParser.parse(fullText), sid, completed && !hadError)
    }

    private func merge(_ a: String, _ b: String) -> String {
        a.contains(b.prefix(40)) ? a : (a.isEmpty ? b : a + "\n" + b)
    }
}
