//
//  ClaudeEngine.swift
//  rounds
//
//  Drives the user's local `claude` CLI in headless stream-json mode and surfaces a
//  clean AsyncStream of typed events. This is the whole "brain" integration: spawn,
//  stream tokens, capture tool calls, parse the final result. Verified spawn contract:
//    claude -p <prompt> --output-format stream-json --verbose --include-partial-messages
//           --model <m> --strict-mcp-config --mcp-config <f> --settings <f>
//           --append-system-prompt <contract> --allowedTools ... --disallowedTools ...
//           [--resume <sessionId>]
//

import Foundation

/// A Claude model as Claude Code names it on `--model`. `rawValue` is the CLI value — an alias
/// (`opus`/`sonnet`/`haiku`, which Claude Code itself resolves to the newest model of that family) or
/// a full id (`claude-fable-5-1`). The human names come from `ModelCatalog`, which is read LIVE from the
/// installed CLI (`initialize` control_request → `models`), so the picker never goes stale.
nonisolated struct RoundsModel: RawRepresentable, Hashable, Sendable, Codable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let opus = RoundsModel(rawValue: "opus")
    static let sonnet = RoundsModel(rawValue: "sonnet")
    static let haiku = RoundsModel(rawValue: "haiku")

    private var info: ModelInfo? { ModelCatalog.shared.info(rawValue) }
    /// Menu line, e.g. "Opus 5.5 — Best for everyday, complex tasks".
    var displayName: String {
        guard let i = info else { return short }
        return i.description.isEmpty ? i.displayName : "\(i.displayName) — \(i.description)"
    }
    /// Compact label for the toolbar, e.g. "Opus 5.5".
    var short: String { info?.displayName ?? rawValue.capitalized }
    /// Effort levels this model accepts (empty → the model doesn't take `--effort`).
    var supportedEfforts: [String] { info?.supportedEffortLevels ?? RoundsEffort.allCases.filter { $0 != .default }.map(\.rawValue) }
}

/// Reasoning effort for the run (`claude --effort`). Higher = more thinking, slower. `default` skips
/// the flag (uses the model's own default).
nonisolated enum RoundsEffort: String, CaseIterable, Sendable, Codable {
    case `default`, low, medium, high, xhigh, max
    var short: String {
        switch self {
        case .default: "Auto"; case .low: "Low"; case .medium: "Med"
        case .high: "High"; case .xhigh: "X-High"; case .max: "Max"
        }
    }
    var displayName: String {
        switch self {
        case .default: "Auto — the model's default reasoning"
        case .low: "Low — fastest, least thinking"
        case .medium: "Medium"
        case .high: "High — more thorough"
        case .xhigh: "Extra high"
        case .max: "Max — deepest reasoning, slowest"
        }
    }
}

/// How far out on the evidence-maturity axis the brain should reach when it researches a question.
/// Higher stages widen the net (from settled guidelines out to preclinical/experimental work) and
/// REQUIRE the brain to label how early each source is. `frontier` is the product default: reach for
/// promising but not-yet-proven medicine, while flagging exactly how much to trust it. The enum is
/// versioned in the prompt (chat.md); Swift only injects the per-turn directive below.
nonisolated enum RoundsResearchStage: String, CaseIterable, Sendable, Codable {
    case standard, proven, frontier, experimental

    static var `default`: Self { .frontier }

    /// Slider position, 1…4.
    var index: Int {
        switch self {
        case .standard: 1; case .proven: 2; case .frontier: 3; case .experimental: 4
        }
    }
    static func from(index: Int) -> Self {
        allCases.first { $0.index == index } ?? .default
    }

    var displayName: String {
        switch self {
        case .standard: "Standard of care"
        case .proven: "Proven + recent"
        case .frontier: "Frontier"
        case .experimental: "Experimental"
        }
    }
    var short: String {
        switch self {
        case .standard: "Standard"; case .proven: "Proven"
        case .frontier: "Frontier"; case .experimental: "Experimental"
        }
    }
    var symbol: String {
        switch self {
        case .standard: "checkmark.seal"
        case .proven: "chart.bar.doc.horizontal"
        case .frontier: "chart.line.uptrend.xyaxis"
        case .experimental: "atom"
        }
    }
    /// One-line human blurb for tooltips / the active-stage description.
    var blurb: String {
        switch self {
        case .standard: "Settled, high-trust: clinical guidelines and systematic reviews only."
        case .proven: "Well-supported and current: adds recent randomized trials and meta-analyses."
        case .frontier: "Promising but early: adds ongoing phase 2/3 trials and strong preprints — each labelled with how much to trust it."
        case .experimental: "Speculative frontier: adds preclinical, mechanistic, phase-1 and case-report evidence, clearly flagged."
        }
    }
    /// Very short "what this level includes" for the popover legend list.
    var legend: String {
        switch self {
        case .standard: "Guidelines & systematic reviews only"
        case .proven: "Adds recent randomized trials"
        case .frontier: "Adds ongoing trials & strong preprints"
        case .experimental: "Adds preclinical & case-report evidence"
        }
    }
    /// Compact directive injected into every turn's prompt. The FULL behaviour spec lives in chat.md.
    var turnDirective: String {
        switch self {
        case .standard:
            return "Restrict sources to clinical guidelines, drug labels, and systematic reviews (tiers PRIMARY, T0–T2). Do not surface single trials, preprints, or case reports as recommendations."
        case .proven:
            return "Use guidelines and systematic reviews first, and you MAY add well-conducted recent randomized trials (down to T3). Avoid preprints and single observational studies as the basis for advice."
        case .frontier:
            return "Reach out to the research frontier: include ongoing phase 2/3 clinical trials and strong preprints (down to T5/T6) when relevant. For EVERY source that is not yet standard-of-care, state its maturity band and a one-line caution on how much to trust it. Never present early evidence as settled."
        case .experimental:
            return "Reach the full frontier, including preclinical, mechanistic, phase-1 and case-report evidence. Clearly flag each such source as experimental/speculative with a one-line caution; keep any concrete suggestions proportional to how thin the evidence is."
        }
    }
}

/// Claude Code permission mode. `bypass` runs allowed tools with no prompts (Rounds can't surface
/// the CLI's interactive permission prompt), while `--disallowedTools` still HARD-removes Bash/Task/
/// WebSearch — so file writes & source lookups just work, but the dangerous tools stay off.
nonisolated enum RoundsPermissionMode: String, CaseIterable, Sendable, Codable {
    case bypass = "bypassPermissions"
    case acceptEdits = "acceptEdits"
    case standard = "default"
    var displayName: String {
        switch self {
        case .bypass: "Bypass — let Rounds act without prompts (default)"
        case .acceptEdits: "Auto-accept edits"
        case .standard: "Standard — ask before each tool"
        }
    }
    var blurb: String {
        switch self {
        case .bypass: "Rounds reads, files, and updates your records without interrupting you. Bash, web search, and sub-agents stay disabled either way."
        case .acceptEdits: "File edits are auto-approved; other tools follow Claude Code's defaults."
        case .standard: "Claude Code's default prompting. In Rounds these prompts can't be shown, so file changes may silently fail."
        }
    }
}

nonisolated enum RoundsEvent: Sendable {
    case started(sessionId: String, model: String)
    case textDelta(String)
    case toolUse(name: String, input: String)
    case toolResult(String, isError: Bool)
    case usage(outputTokens: Int)   // cumulative output tokens for the current message (live counter)
    case slashCommands([String])    // available Claude Code slash commands (from the init event)
    case userMessage(String)        // an inbound user turn — e.g. typed from the phone via remote control
    case remoteControl(sessionURL: String?)   // control_response to a remote_control request (carries the pairing URL)
    case finished(text: String, sessionId: String, isError: Bool, costUSD: Double)
    case failed(String)
}

/// What the model is allowed to do for a given operation.
nonisolated struct ToolPolicy: Sendable {
    var allowed: [String]
    var disallowed: [String]

    /// Read-only analysis (chat, hypotheses planning). No file writes.
    static let readOnly = ToolPolicy(
        allowed: ["Read", "Glob", "Grep", "WebFetch", "mcp__rounds-sources"],
        disallowed: ["Bash", "Task", "WebSearch", "ToolSearch", "KillShell"])

    /// Read + write inside the vault (intake commit, hypothesis files).
    static let readWrite = ToolPolicy(
        allowed: ["Read", "Glob", "Grep", "Write", "Edit", "WebFetch", "mcp__rounds-sources"],
        disallowed: ["Bash", "Task", "WebSearch", "ToolSearch", "KillShell"])
}

nonisolated struct ClaudeRun: Sendable {
    var prompt: String
    var model: RoundsModel
    var policy: ToolPolicy
    var cwd: URL
    var appendSystemPrompt: String?
    var mcpConfigPath: String?
    /// true → `--strict-mcp-config`: ONLY the Rounds MCP config loads. false → the user's own MCP
    /// servers (user/project scope, same as running `claude` in Terminal) load ALONGSIDE rounds-sources.
    var strictMCP: Bool = true
    var settingsPath: String?
    var resumeSessionId: String?
    var toolPaths: ToolPaths
    var includePartial: Bool = true
    var permissionMode: RoundsPermissionMode = .bypass
    var effort: RoundsEffort = .default
    /// Evidence-maturity window for this run. Exported to the child process as
    /// `ROUNDS_RESEARCH_STAGE` so the `rounds-sources` MCP server can hard-cap which tiers it returns.
    var researchStage: RoundsResearchStage = .default
}

nonisolated enum ClaudeEngine {

    static func stream(_ run: ClaudeRun) -> AsyncStream<RoundsEvent> {
        AsyncStream { continuation in
            guard let claude = run.toolPaths.claude else {
                continuation.yield(.failed("Claude Code CLI not found. Install it and check the checklist."))
                continuation.finish()
                return
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: claude)
            proc.currentDirectoryURL = run.cwd

            var args = ["-p", run.prompt,
                        "--output-format", "stream-json",
                        "--verbose",
                        "--model", run.model.rawValue]
            if run.includePartial { args += ["--include-partial-messages"] }
            if run.effort != .default { args += ["--effort", run.effort.rawValue] }
            args += ["--permission-mode", run.permissionMode.rawValue]
            if let mcp = run.mcpConfigPath { args += (run.strictMCP ? ["--strict-mcp-config"] : []) + ["--mcp-config", mcp] }
            if let settings = run.settingsPath { args += ["--settings", settings] }
            if let sys = run.appendSystemPrompt { args += ["--append-system-prompt", sys] }
            if !run.policy.allowed.isEmpty { args += ["--allowedTools", run.policy.allowed.joined(separator: " ")] }
            if !run.policy.disallowed.isEmpty { args += ["--disallowedTools", run.policy.disallowed.joined(separator: " ")] }
            if let resume = run.resumeSessionId { args += ["--resume", resume] }
            proc.arguments = args

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = run.toolPaths.path
            // Keep telemetry quiet & non-interactive.
            env["CI"] = "1"
            // Hard-cap the evidence tiers the sources MCP will return (1…4). Inherited by the MCP child.
            env["ROUNDS_RESEARCH_STAGE"] = String(run.researchStage.index)
            proc.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            // All parsing on one serial queue so feed/flush never race.
            let parseQueue = DispatchQueue(label: "com.lpst.rounds.engine.parse")
            let stderr = DataBox()
            let parser = LineParser { obj in
                for event in EventMapper.map(obj) { continuation.yield(event) }
            }

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                parseQueue.async { parser.feed(data) }
            }
            // Always drain stderr so a chatty child never blocks on a full pipe.
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stderr.append(data)
            }

            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                parseQueue.async {
                    // Drain any bytes still buffered, then flush the trailing partial line.
                    let rest = outPipe.fileHandleForReading.readDataToEndOfFile()
                    if !rest.isEmpty { parser.feed(rest) }
                    stderr.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    parser.flush()
                    if !parser.sawResult {
                        let msg = stderr.string().trimmingCharacters(in: .whitespacesAndNewlines)
                        if p.terminationStatus != 0 || !msg.isEmpty {
                            continuation.yield(.failed(msg.isEmpty ? "claude exited with status \(p.terminationStatus)" : msg))
                        }
                    }
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                if proc.isRunning { proc.terminate() }
            }

            do {
                try proc.run()
            } catch {
                continuation.yield(.failed("Failed to launch claude: \(error.localizedDescription)"))
                continuation.finish()
            }
        }
    }
}

/// Thread-safe byte accumulator for draining a pipe (stderr) off any queue.
nonisolated final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { guard !d.isEmpty else { return }; lock.lock(); data.append(d); lock.unlock() }
    func string() -> String { lock.lock(); defer { lock.unlock() }; return String(data: data, encoding: .utf8) ?? "" }
}

/// Buffers raw pipe bytes into whole JSON lines. Not thread-safe by itself; the pipe's
/// readabilityHandler invokes `feed` serially per file handle, which is sufficient here.
nonisolated final class LineParser: @unchecked Sendable {
    private var buffer = Data()
    private let onObject: ([String: Any]) -> Void
    private(set) var sawResult = false

    init(onObject: @escaping ([String: Any]) -> Void) { self.onObject = onObject }

    func feed(_ data: Data) {
        buffer.append(data)
        let newline = UInt8(0x0A)
        while let idx = buffer.firstIndex(of: newline) {
            let lineData = buffer.subdata(in: buffer.startIndex..<idx)
            buffer.removeSubrange(buffer.startIndex...idx)
            handleLine(lineData)
        }
    }

    func flush() {
        if !buffer.isEmpty { handleLine(buffer); buffer.removeAll() }
    }

    private func handleLine(_ data: Data) {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if (obj["type"] as? String) == "result" { sawResult = true }
        onObject(obj)
    }
}

/// Maps a raw stream-json object to zero or more typed RoundsEvents.
nonisolated enum EventMapper {
    static func map(_ obj: [String: Any]) -> [RoundsEvent] {
        guard let type = obj["type"] as? String else { return [] }
        switch type {
        case "system":
            if (obj["subtype"] as? String) == "init",
               let sid = obj["session_id"] as? String {
                let model = obj["model"] as? String ?? ""
                var events: [RoundsEvent] = [.started(sessionId: sid, model: model)]
                if let cmds = obj["slash_commands"] as? [String], !cmds.isEmpty {
                    events.append(.slashCommands(cmds))
                }
                return events
            }
            return []

        case "stream_event":
            // Token-by-token deltas for the live typing feel + live token usage for the counter.
            if let event = obj["event"] as? [String: Any] {
                let et = event["type"] as? String
                // Claude streams the "thinking out loud" narration between tool calls as SEPARATE
                // text blocks. Insert a paragraph break at each text block start so the end of one
                // block doesn't run into the next ("…his case.Let me read…").
                if et == "content_block_start",
                   ((event["content_block"] as? [String: Any])?["type"] as? String) == "text" {
                    return [.textDelta("\n\n")]
                }
                if et == "content_block_delta",
                   let delta = event["delta"] as? [String: Any],
                   let text = delta["text"] as? String {
                    return [.textDelta(text)]
                }
                if et == "message_delta", let ot = intOf((event["usage"] as? [String: Any])?["output_tokens"]) {
                    return [.usage(outputTokens: ot)]
                }
                if et == "message_start",
                   let ot = intOf(((event["message"] as? [String: Any])?["usage"] as? [String: Any])?["output_tokens"]) {
                    return [.usage(outputTokens: ot)]
                }
            }
            return []

        case "assistant":
            // Capture tool calls (text is already covered by deltas) + the message's final token count.
            guard let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            var events: [RoundsEvent] = []
            if let ot = intOf((message["usage"] as? [String: Any])?["output_tokens"]) {
                events.append(.usage(outputTokens: ot))
            }
            for block in content {
                if (block["type"] as? String) == "tool_use",
                   let name = block["name"] as? String {
                    let input = block["input"].map { (try? JSONSerialization.data(withJSONObject: $0)).flatMap { String(data: $0, encoding: .utf8) } ?? "" } ?? ""
                    events.append(.toolUse(name: name, input: input))
                }
            }
            return events

        case "user":
            // A user turn on the stream. Two flavors: tool_result blocks (from our own tools), and
            // plain text — which, when we didn't type it ourselves, is an inbound message from the
            // phone via remote control. Render the latter as a user bubble.
            guard let message = obj["message"] as? [String: Any] else { return [] }
            if let text = message["content"] as? String, !text.isEmpty {
                return [.userMessage(text)]
            }
            if let content = message["content"] as? [[String: Any]] {
                for block in content where (block["type"] as? String) == "tool_result" {
                    return [.toolResult(stringifyToolResult(block["content"]), isError: (block["is_error"] as? Bool) == true)]
                }
                let texts = content.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                if !texts.isEmpty { return [.userMessage(texts.joined(separator: "\n"))] }
            }
            return []

        case "control_response":
            // Reply to a control_request. For remote_control enable it carries the pairing session_url.
            if let resp = obj["response"] as? [String: Any],
               let url = (resp["response"] as? [String: Any])?["session_url"] as? String, !url.isEmpty {
                return [.remoteControl(sessionURL: url)]
            }
            return []

        case "result":
            let text = obj["result"] as? String ?? ""
            let sid = obj["session_id"] as? String ?? ""
            let isError = (obj["is_error"] as? Bool) ?? false
            let cost = (obj["total_cost_usd"] as? Double) ?? 0
            return [.finished(text: text, sessionId: sid, isError: isError, costUSD: cost)]

        default:
            return []
        }
    }

    static func stringifyToolResult(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let arr = value as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    static func intOf(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
