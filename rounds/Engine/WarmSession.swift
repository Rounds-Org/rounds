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
    private var sawResultThisTurn = false
    private var _sessionId: String?
    private var _turnCount = 0
    private var _alive = false
    private var stderrBuf = Data()
    private var parser: LineParser!

    /// A turn that produces no `result` while the process stays alive would otherwise hang.
    private let turnTimeout: TimeInterval = 300

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
                    "--model", model.rawValue,
                    "--permission-mode", config.permissionMode.rawValue]
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

            // Watchdog: never let a turn hang forever.
            parseQueue.asyncAfter(deadline: .now() + turnTimeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let stillThisTurn = (self._turnCount == turn && !self.sawResultThisTurn)
                self.lock.unlock()
                if stillThisTurn { self.finishTurn(failure: "This turn timed out.") }
            }

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
        for event in EventMapper.map(obj) {
            switch event {
            case .started(let sid, _):
                lock.lock(); _sessionId = sid; lock.unlock()
            case .finished(let text, let sid, let isError, let cost):
                lock.lock()
                if !sid.isEmpty { _sessionId = sid }
                let c = current
                sawResultThisTurn = true
                lock.unlock()
                c?.yield(.finished(text: text, sessionId: sid, isError: isError, costUSD: cost))
                finishTurn(failure: nil)
            default:
                lock.lock(); let c = current; lock.unlock()
                c?.yield(event)
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
