//
//  ModelCatalog.swift
//  rounds
//
//  The model list, read LIVE from the user's installed Claude Code — never hardcoded. Claude Code
//  answers an `initialize` control_request (stream-json stdin) with the exact list its own /model
//  picker shows: aliases (`opus`/`sonnet`/`haiku`, which always resolve to the newest model of that
//  family) plus pinned ids (`claude-fable-5-1`, older versions…), each with a display name,
//  description and supported effort levels. A new model ships → `claude` updates → Rounds shows it.
//  The last answer is cached in UserDefaults so the picker is right at launch, before the probe returns.
//

import Foundation

nonisolated struct ModelInfo: Codable, Sendable, Hashable {
    var value: String                 // what `--model` takes
    var displayName: String           // "Opus 5.5"
    var description: String           // "Best for everyday, complex tasks"
    var resolvedModel: String?        // "claude-opus-5-5"
    var supportedEffortLevels: [String]?
}

nonisolated final class ModelCatalog: @unchecked Sendable {
    static let shared = ModelCatalog()

    private let lock = NSLock()
    private var _models: [ModelInfo]
    private static let cacheKey = "rounds.modelCatalog.v1"

    /// Used only before the first successful probe ever (no cache): bare aliases with no version
    /// numbers, so even this can't go stale — Claude Code resolves each alias to its newest model.
    static let fallback: [ModelInfo] = [
        ModelInfo(value: "opus", displayName: "Opus", description: "Deepest reasoning", resolvedModel: nil, supportedEffortLevels: nil),
        ModelInfo(value: "sonnet", displayName: "Sonnet", description: "Fast & capable", resolvedModel: nil, supportedEffortLevels: nil),
        ModelInfo(value: "haiku", displayName: "Haiku", description: "Fastest", resolvedModel: nil, supportedEffortLevels: []),
    ]

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([ModelInfo].self, from: d), !cached.isEmpty {
            _models = cached
        } else {
            _models = Self.fallback
        }
    }

    var models: [ModelInfo] { lock.lock(); defer { lock.unlock() }; return _models }
    func info(_ value: String) -> ModelInfo? { models.first { $0.value == value } }

    /// Current models: the first of each family (the aliases + e.g. the newest Fable), in Claude Code's
    /// own order. `older`: everything else (pinned previous versions), for an "Older models" submenu.
    func split() -> (current: [ModelInfo], older: [ModelInfo]) {
        var seen = Set<String>(), current: [ModelInfo] = [], older: [ModelInfo] = []
        for m in models {
            let family = m.displayName.split(separator: " ").first.map { String($0).lowercased() } ?? m.value
            if seen.insert(family).inserted { current.append(m) } else { older.append(m) }
        }
        return (current, older)
    }

    /// Ask the installed CLI for its model list. Returns true when the list changed.
    @discardableResult
    func refresh(toolPaths: ToolPaths) async -> Bool {
        guard let claude = toolPaths.claude,
              let fresh = await Self.probe(claude: claude, path: toolPaths.path), !fresh.isEmpty else { return false }
        let changed = replace(with: fresh)
        if changed, let d = try? JSONEncoder().encode(fresh) { UserDefaults.standard.set(d, forKey: Self.cacheKey) }
        return changed
    }

    private func replace(with fresh: [ModelInfo]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let changed = fresh != _models
        _models = fresh
        return changed
    }

    /// Spawn `claude` in stream-json input mode, send `initialize`, read the `control_response`, kill it.
    /// No prompt is ever sent, so this costs no tokens. `--strict-mcp-config` keeps it from booting MCP servers.
    private static func probe(claude: String, path: String) async -> [ModelInfo]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[ModelInfo]?, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: claude)
            proc.currentDirectoryURL = FileManager.default.temporaryDirectory
            proc.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                              "--verbose", "--strict-mcp-config"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            env["CI"] = "1"
            proc.environment = env
            let inPipe = Pipe(), outPipe = Pipe()
            proc.standardInput = inPipe
            proc.standardOutput = outPipe
            proc.standardError = FileHandle.nullDevice

            let once = NSLock()
            var done = false
            func finish(_ result: [ModelInfo]?) {
                once.lock(); defer { once.unlock() }
                guard !done else { return }
                done = true
                outPipe.fileHandleForReading.readabilityHandler = nil
                try? inPipe.fileHandleForWriting.close()
                if proc.isRunning { proc.terminate() }
                cont.resume(returning: result)
            }

            let parser = LineParser { obj in
                guard (obj["type"] as? String) == "control_response" else { return }
                let payload = (obj["response"] as? [String: Any])?["response"] as? [String: Any]
                finish(parseModels(payload?["models"]))
            }
            let q = DispatchQueue(label: "com.lpst.rounds.modelprobe")
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { q.async { finish(nil) }; return }
                q.async { parser.feed(d) }
            }
            proc.terminationHandler = { _ in q.async { parser.flush(); finish(nil) } }

            do { try proc.run() } catch { finish(nil); return }
            let req = #"{"type":"control_request","request_id":"rounds-models","request":{"subtype":"initialize"}}"# + "\n"
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(req.utf8))
            q.asyncAfter(deadline: .now() + 25) { finish(nil) }   // old CLI / hang → keep the cache
        }
    }

    static func parseModels(_ raw: Any?) -> [ModelInfo]? {
        guard let arr = raw as? [[String: Any]] else { return nil }
        let list: [ModelInfo] = arr.compactMap { m in
            guard let value = m["value"] as? String, !value.isEmpty,
                  value != "default"   // "Default (recommended)" just mirrors the opus alias
            else { return nil }
            return ModelInfo(value: value,
                             displayName: (m["displayName"] as? String) ?? value,
                             description: (m["description"] as? String) ?? "",
                             resolvedModel: m["resolvedModel"] as? String,
                             supportedEffortLevels: (m["supportsEffort"] as? Bool) == true
                                ? ((m["supportedEffortLevels"] as? [String]) ?? []) : [])
        }
        return list.isEmpty ? nil : list
    }
}
