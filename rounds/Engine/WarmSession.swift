//
//  WarmSession.swift
//  rounds
//
//  A warm, persistent `claude` process bound to one chat. Turn N reuses the live process
//  (context already loaded) instead of cold-spawning — this is the "no lag" promise.
//  Verified contract: claude --input-format stream-json --output-format stream-json
//  --verbose --include-partial-messages. Each user turn is one JSON line on stdin; events
//  stream back on stdout until a `result` event ends the turn.
//
//  Robustness: all stdout parsing runs on a single serial queue (no feed/flush races);
//  the turn's continuation is finished from exactly one of {result, process-exit, stop,
//  watchdog timeout}; shared state is lock-guarded; stderr is always drained.
//

import Foundation

nonisolated final class WarmSession: @unchecked Sendable {
    let model: RoundsModel
    private let config: ClaudeRun
    private let proc = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let parseQueue = DispatchQueue(label: "com.lpst.rounds.warm.parse")

    private let lock = NSLock()
    private var current: AsyncStream<RoundsEvent>.Continuation?
    /// Events arriving OUTSIDE a send() turn (e.g. a turn driven from the phone via remote control)
    /// are routed here instead of being dropped. Set by ChatRuntime; invoked on the parse queue.
    var onPassive: (@Sendable (RoundsEvent) -> Void)?
    private var sawResultThisTurn = false
    private var _sessionId: String?
    private var _turnCount = 0
    private var _alive = false
    private var stderrBuf = Data()
    private var parser: LineParser!

    /// A turn is killed only if it goes SILENT this long (no events at all) with no result — a true
    /// hang. An actively-working turn (tool calls, streaming text) keeps resetting the timer, so a
    /// long multi-step run (deep search, building a document) is never cut off mid-work.
    private let idleTimeout: TimeInterval = 180
    private var lastActivityAt = Date()

    init(model: RoundsModel, config: ClaudeRun) {
        self.model = model
        self.config = config
        self.parser = LineParser { [weak self] obj in self?.handle(obj) }
    }

    // Lock-guarded accessors (read from MainActor, written from the parse queue).
    var sessionId: String? { lock.lock(); defer { lock.unlock() }; return _sessionId }
    var turnCount: Int { lock.lock(); defer { lock.unlock() }; return _turnCount }
    var isAlive: Bool { lock.lock(); defer { lock.unlock() }; return _alive && proc.isRunning }

    func start() throws {
        guard let claude = config.toolPaths.claude else { throw RoundsError.noClaude }
        proc.executableURL = URL(fileURLWithPath: claude)
        proc.currentDirectoryURL = config.cwd
        var args = ["--input-format", "stream-json",
                    "--output-format", "stream-json",
                    "--verbose", "--include-partial-messages",
                    "--replay-user-messages",   // echo user turns (incl. phone-typed via remote control) on stdout so Rounds mirrors them
                    "--model", model.rawValue,
                    "--permission-mode", config.permissionMode.rawValue]
        // Resume the chat's prior Claude session so the model keeps full multi-turn memory
        // (without this the warm session starts blank and re-grounds only from files).
        if let resume = config.resumeSessionId, !resume.isEmpty { args += ["--resume", resume] }
        if config.effort != .default { args += ["--effort", config.effort.rawValue] }
        if let mcp = config.mcpConfigPath { args += ["--strict-mcp-config", "--mcp-config", mcp] }
        if let settings = config.settingsPath { args += ["--settings", settings] }
        if let sys = config.appendSystemPrompt { args += ["--append-system-prompt", sys] }
        if !config.policy.allowed.isEmpty { args += ["--allowedTools", config.policy.allowed.joined(separator: " ")] }
        if !config.policy.disallowed.isEmpty { args += ["--disallowedTools", config.policy.disallowed.joined(separator: " ")] }
        proc.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = config.toolPaths.path
        env["CI"] = "1"
        proc.environment = env

        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let self else { return }
            self.parseQueue.async { self.parser.feed(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let self else { return }
            self.lock.lock(); self.stderrBuf.append(data); self.lock.unlock()
        }
        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self._alive = false; self.lock.unlock()
            self.parseQueue.async {
                self.parser.flush()
                self.finishTurn(failure: self.stderrText().isEmpty ? "The session ended." : self.stderrText())
            }
        }
        try proc.run()
        lock.lock(); _alive = true; lock.unlock()
    }

    /// Send one user turn; events stream until the turn's `result` (or timeout / failure).
    func send(_ text: String) -> AsyncStream<RoundsEvent> {
        AsyncStream { cont in
            lock.lock()
            current = cont
            sawResultThisTurn = false
            _turnCount += 1
            let turn = _turnCount
            lock.unlock()

            // Idle watchdog: end the turn only if it goes silent (a real hang), never because it's
            // taking a long time doing real work (e.g. many searches + building a document).
            lock.lock(); lastActivityAt = Date(); lock.unlock()
            scheduleWatchdog(turn)

            let msg: [String: Any] = ["type": "user",
                                      "message": ["role": "user",
                                                  "content": [["type": "text", "text": text]]]]
            guard var data = try? JSONSerialization.data(withJSONObject: msg) else {
                cont.yield(.failed("Could not encode the message.")); cont.finish(); return
            }
            data.append(0x0A)
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                finishTurn(failure: "The session is no longer accepting input.")
            }
        }
    }

    /// Enable/disable Claude Code Remote Control on this LIVE session — the same mechanism the
    /// VS Code extension uses: an in-band `control_request` written to stdin. The reply
    /// (`control_response`) carries the pairing `session_url`, surfaced as a `.remoteControl` event.
    func sendControl(enabled: Bool, name: String?) {
        var request: [String: Any] = ["subtype": "remote_control", "enabled": enabled]
        if enabled, let name { request["name"] = name }
        let msg: [String: Any] = ["type": "control_request", "request_id": UUID().uuidString, "request": request]
        guard let body = try? JSONSerialization.data(withJSONObject: msg) else { return }
        var data = body; data.append(0x0A)
        lock.lock(); let alive = _alive; lock.unlock()
        guard alive else { return }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    /// Re-arm every 30s; finish the turn only after `idleTimeout` of complete silence with no result.
    private func scheduleWatchdog(_ turn: Int) {
        parseQueue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let active = (self._turnCount == turn && !self.sawResultThisTurn && self._alive)
            let idle = Date().timeIntervalSince(self.lastActivityAt)
            self.lock.unlock()
            guard active else { return }                                  // turn already finished
            if idle > self.idleTimeout { self.finishTurn(failure: "This turn stalled.") }
            else { self.scheduleWatchdog(turn) }                          // still working — keep watching
        }
    }

    func stop() {
        lock.lock(); _alive = false; lock.unlock()
        try? stdinPipe.fileHandleForWriting.close()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if proc.isRunning { proc.terminate() }
        finishTurn(failure: "Stopped.")   // never depend on the weak terminationHandler firing
    }

    // MARK: - internals (run on parseQueue, except stop()/accessors)

    private func stderrText() -> String {
        lock.lock(); defer { lock.unlock() }
        return (String(data: stderrBuf, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handle(_ obj: [String: Any]) {
        lock.lock(); lastActivityAt = Date(); lock.unlock()   // any output means the turn is alive
        for event in EventMapper.map(obj) {
            switch event {
            case .started(let sid, _):
                lock.lock(); _sessionId = sid; lock.unlock()
            case .finished(let text, let sid, let isError, let cost):
                lock.lock()
                if !sid.isEmpty { _sessionId = sid }
                let c = current
                if c != nil { sawResultThisTurn = true }
                lock.unlock()
                if let c {
                    c.yield(.finished(text: text, sessionId: sid, isError: isError, costUSD: cost))
                    finishTurn(failure: nil)
                } else {
                    onPassive?(event)   // a turn driven from the phone (no active local turn)
                }
            default:
                lock.lock(); let c = current; lock.unlock()
                if let c { c.yield(event) } else { onPassive?(event) }
            }
        }
    }

    /// Finishes the current turn's stream exactly once (idempotent via the nil-out).
    private func finishTurn(failure: String?) {
        lock.lock()
        let c = current
        current = nil
        let needFailure = (failure != nil) && !sawResultThisTurn && c != nil
        lock.unlock()
        if needFailure, let failure { c?.yield(.failed(failure)) }
        c?.finish()
    }
}

nonisolated enum RoundsError: Error { case noClaude }
