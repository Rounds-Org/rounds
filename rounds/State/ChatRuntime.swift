//
//  ChatRuntime.swift
//  rounds
//
//  Per-chat state + streaming. Each chat owns its messages, live text, trace, sources,
//  warm process and task — so multiple chats stream in parallel with independent status.
//

import Foundation
import Observation
import AppKit

/// A message the user sent while a turn was still streaming. Held in `ChatRuntime.queued`,
/// shown as a grey deletable chip, and dispatched (in order) the moment the active turn ends.
struct QueuedTurn: Identifiable, Equatable {
    let id = UUID().uuidString
    let text: String
    var references: [Reference] = []
}

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
    var remoteControlOn = false       // Claude Code Remote Control enabled for this chat's live session
    var remoteSessionURL: String?     // pairing URL to open this session on a phone / claude.ai
    var draft = ""                    // unsent input text — kept per-chat so it survives leaving/returning to the tab
    var draftReferences: [Reference] = []   // unsent @-references, likewise preserved across tab switches
    var queued: [QueuedTurn] = []     // messages typed mid-stream: grey deletable chips, sent in order once the turn ends
    @ObservationIgnored weak var inputTextView: ChatKeyTextView?   // live editor, for inserting voice dictation at the caret
    private var phoneLive = ""        // accumulates streamed assistant text for a phone-driven turn

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
        app.checkRedFlags(msg)   // deterministic Principle-6 net, before the model
        // Mid-stream: don't drop the message. Queue it (shown as a grey, deletable chip) and it
        // fires automatically the instant the current turn finishes. Claude Code answers turns
        // sequentially, so this lands the same end result as the VS Code extension's follow-ups.
        if isStreaming {
            queued.append(QueuedTurn(text: msg, references: references))
            return
        }
        isStreaming = true   // close the gate now so a fast follow-up queues instead of racing
        task = Task { await runQueue(first: QueuedTurn(text: msg, references: references)) }
    }

    /// Run the first turn, then drain any messages queued while it (and each later one) streamed,
    /// in order. `isStreaming` stays true for the whole drain so follow-ups keep queueing, not racing.
    private func runQueue(first: QueuedTurn) async {
        // Only this task resets streaming state on NORMAL completion. If it was cancelled (Stop),
        // stop() already reset it — and a fresh turn may now own isStreaming, so don't clobber it.
        defer { if !Task.isCancelled { isStreaming = false; statusLine = ""; liveText = ""; notifyFinishedIfAway() } }
        var turn: QueuedTurn? = first
        while let t = turn, !Task.isCancelled {
            await runTurn(t.text, t.references)
            turn = queued.isEmpty ? nil : queued.removeFirst()
        }
    }

    /// When a chat finishes its turn(s), ping the user — but only if they're NOT already watching it
    /// (the app isn't frontmost, or they're on a different tab). Skips the next-steps generation lane
    /// (that has its own "updated your next steps" notification).
    private func notifyFinishedIfAway() {
        guard !id.hasPrefix("nextsteps-") else { return }
        let watching = NSApp.isActive && app.activeChatTab == id
        guard !watching else { return }
        let name = title
        NotificationService.shared.notify(title: "Rounds finished",
                                          body: name.isEmpty || name == "New chat" ? "Your answer is ready." : "“\(name)” is ready.")
    }

    func stop() {
        task?.cancel()
        warm?.stop(); warm = nil; warmModel = nil
        isStreaming = false; statusLine = ""; liveText = ""
        queued.removeAll()
    }

    func modelChanged() { warm?.stop(); warm = nil; warmModel = nil }

    private func ensureWarm() {
        if let w = warm, w.isAlive, warmModel == app.selectedModel { return }
        warm?.stop()
        let w = WarmSession(model: app.selectedModel, config: app.chatRun(resume: sessionId))
        w.onPassive = { [weak self] event in Task { @MainActor in self?.handlePassive(event) } }
        do { try w.start(); warm = w; warmModel = app.selectedModel } catch { warm = nil }
    }

    /// Toggle Claude Code Remote Control for THIS chat's live session — the VS Code mechanism:
    /// an in-band control_request on the warm stream-json session. The reply's `session_url` lets
    /// you open the SAME session on your phone / claude.ai; messages typed there flow back in as
    /// passive events (rendered via `handlePassive`), and locally-typed turns still work normally.
    func setRemoteControl(_ on: Bool) {
        ensureWarm()
        remoteControlOn = on
        if !on {
            remoteSessionURL = nil
            warm?.sendControl(enabled: false, name: nil)
            app.toast = "Remote control off."
            return
        }
        app.toast = "Turning on remote control…"
        let name = "rounds-\(id.prefix(8))"
        // Give a freshly-spawned warm session a moment to emit its init before the control_request.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.warm?.sendControl(enabled: true, name: name)
        }
    }

    /// Events that arrive OUTSIDE a local send() turn — i.e. a turn someone drove from the phone via
    /// remote control, plus the control_response carrying the pairing URL. Renders phone turns into
    /// the same `messages` list so the laptop and phone stay in sync.
    private func handlePassive(_ event: RoundsEvent) {
        switch event {
        case .remoteControl(let url):
            if let url, !url.isEmpty {
                remoteSessionURL = url; remoteControlOn = true
                app.toast = "Remote control on — open this chat on your phone."
            }
        case .userMessage(let text):
            phoneLive = ""
            messages.append(ChatMessage(id: UUID().uuidString, role: .user, text: text, timestamp: Date()))
            app.persistChat(id, messages, sources, sessionId, title: generatedTitle)
        case .textDelta(let t):
            phoneLive += t
        case .finished(let text, let sid, _, _):
            if !sid.isEmpty { sessionId = sid }
            let raw = text.isEmpty ? phoneLive : text
            phoneLive = ""
            // Parse a phone-driven turn the SAME way a local turn is parsed, so its sources, alert,
            // and any new next-step card are captured. Otherwise the Sources panel keeps the previous
            // turn's sources while the answer cites [n] from this turn → the mismatch the user saw.
            let parsed = ProtocolParser.parse(raw)
            let display = parsed.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ProtocolParser.stripForDisplay(raw) : parsed.displayText
            if !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append(ChatMessage(id: UUID().uuidString, role: .assistant, text: display, timestamp: Date()))
            }
            if !parsed.sources.isEmpty { sources = parsed.sources }
            if let a = parsed.alert { alert = a }
            if !parsed.hypotheses.isEmpty {
                let saved = app.persistChatHypotheses(parsed.hypotheses, sessionId: sessionId, sources: parsed.sources)
                if !saved.isEmpty, let idx = messages.lastIndex(where: { $0.role == .assistant }) {
                    messages[idx].hypotheses = saved
                }
            }
            app.persistChat(id, messages, sources, sessionId, title: generatedTitle)
            if !parsed.stepActions.isEmpty { let actions = parsed.stepActions; Task { await app.applyStepActions(actions) } }
        default:
            break
        }
    }

    /// True when a turn's text is Claude Code's "not authenticated" failure rather than a real answer.
    static func looksLikeClaudeAuthError(_ s: String) -> Bool {
        let t = s.lowercased()
        return t.contains("not logged in")
            || t.contains("please run /login")
            || (t.contains("/login") && t.contains("available in this environment"))   // apostrophe-proof
            || t.contains("invalid api key")
            || (t.contains("authentication") && t.contains("error"))
    }

    /// Shown in place of that failure: clear, correct steps. Sign-in must happen in a real terminal
    /// because Rounds runs Claude Code non-interactively (no TTY / browser flow for /login).
    static let claudeLoginGuidance = """
    **Claude Code isn’t signed in yet.** Rounds runs Claude Code on your Mac, and it needs a one-time sign-in that has to be done in **Terminal** — Rounds can’t do it for you.

    1. Open the **Terminal** app (press ⌘-Space, type “Terminal”, hit Return).
    2. Type `claude` and press Return.
    3. Complete the sign-in — a browser opens for your Claude account, or you can paste an Anthropic API key.
    4. Come back to Rounds and send your message again.

    Note: typing `/login` here won’t work — it only runs in a real terminal.
    """

    private func runTurn(_ msg: String, _ references: [Reference]) async {
        messages.append(ChatMessage(id: UUID().uuidString, role: .user, text: msg, timestamp: Date(), references: references))
        app.persistChat(id, messages, sources, sessionId, title: generatedTitle)   // shows in Recent immediately
        statusLine = "Thinking…"; liveText = ""; trace = []   // isStreaming is owned by runQueue across the whole drain

        ensureWarm()
        let firstTurn = (warm?.turnCount ?? 0) == 0
        let prompt = app.chatPrompt(msg, references: references, firstTurn: firstTurn)

        var (parsed, sid, ok): (ParsedTurn, String?, Bool)
        if let w = warm {
            (parsed, sid, ok) = await consume(w.send(prompt))
            if !ok {
                if Task.isCancelled { return }   // user hit Stop — don't cold-respawn a phantom answer
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
        var finalText = answer.isEmpty ? "I couldn't complete that just now. Please try again." : answer
        // Claude Code is installed but not signed in → it returns "Not logged in · Please run /login"
        // (and /login can't run here, non-interactively). Replace that cryptic output with clear,
        // correct steps, and reflect the state so Settings/onboarding show the sign-in step too.
        if Self.looksLikeClaudeAuthError(finalText) {
            finalText = Self.claudeLoginGuidance
            app.toolPaths.loggedIn = false
        }
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
            let saved = app.persistChatHypotheses(parsed.hypotheses, sessionId: sessionId, sources: parsed.sources)
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
        trace = []; statusLine = ""; liveText = ""   // fresh turn — don't carry over the previous run's steps
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
            case .userMessage, .remoteControl:
                break   // remote-control / phone-driven events are handled passively, not in a local turn
            }
        }
        return (ProtocolParser.parse(fullText), sid, completed && !hadError)
    }

    private func merge(_ a: String, _ b: String) -> String {
        a.contains(b.prefix(40)) ? a : (a.isEmpty ? b : a + "\n" + b)
    }
}
