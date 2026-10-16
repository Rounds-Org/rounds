//
//  ToolLocator.swift
//  rounds
//
//  Resolves absolute paths to the user's `claude` and `node` binaries, plus a usable
//  PATH. A macOS app launched from Finder gets a minimal environment that does NOT
//  include nvm / Homebrew / ~/.local/bin, so we probe a login shell once at startup.
//

import Foundation

nonisolated struct ToolPaths: Sendable, Codable, Equatable {
    var claude: String?
    var node: String?
    var path: String
    var claudeVersion: String?   // e.g. "2.1.172"
    var loggedIn: Bool?          // from `claude auth status` — nil = unknown / not probed / old CLI

    var claudeInstalled: Bool { claude != nil }
    var nodeInstalled: Bool { node != nil }
    /// Installed but explicitly NOT signed in — the "Not logged in · Please run /login" failure.
    var claudeNeedsLogin: Bool { claudeInstalled && loggedIn == false }

    /// PreToolUse hooks that return a permission decision (so Rounds can show Allow/Deny dialogs and
    /// unlock the full Claude Code toolset) need a recent enough Claude Code. Below this → safe mode.
    static let minVersionForPermissionHooks = (2, 0, 0)
    var supportsPermissionHooks: Bool {
        guard let v = ToolPaths.parseVersion(claudeVersion) else { return false }
        return v >= ToolPaths.minVersionForPermissionHooks
    }

    static func parseVersion(_ s: String?) -> (Int, Int, Int)? {
        guard let s else { return nil }
        let nums = s.split(whereSeparator: { !"0123456789".contains($0) }).compactMap { Int($0) }
        guard nums.count >= 1 else { return nil }
        return (nums[0], nums.count > 1 ? nums[1] : 0, nums.count > 2 ? nums[2] : 0)
    }
}

func >= (l: (Int, Int, Int), r: (Int, Int, Int)) -> Bool {
    if l.0 != r.0 { return l.0 > r.0 }
    if l.1 != r.1 { return l.1 > r.1 }
    return l.2 >= r.2
}

nonisolated enum ToolLocator {

    /// Probe a login+interactive shell to discover the real PATH and tool locations.
    static func locate() async -> ToolPaths {
        let probe = """
        command -v claude || true
        command -v node || true
        printf 'PATH=%s' "$PATH"
        """
        let out = await runLoginShell(probe)
        var claude: String?
        var node: String?
        var path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"

        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("PATH=") {
                path = String(line.dropFirst("PATH=".count))
            } else if line.hasSuffix("/claude") || line == "claude" {
                if claude == nil { claude = line }
            } else if line.hasSuffix("/node") || line == "node" {
                if node == nil { node = line }
            }
        }

        // Common fallbacks if the probe missed them.
        let home = NSHomeDirectory()
        let candidatesClaude = [claude, "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        claude = candidatesClaude.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }

        let candidatesNode = [node, "/opt/homebrew/bin/node", "/usr/local/bin/node"]
        node = candidatesNode.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }

        // Enrich PATH so the spawned `claude` can find `node` and friends.
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        var parts = path.split(separator: ":").map(String.init)
        if let node, let dir = node.split(separator: "/").dropLast().joined(separator: "/").nilIfEmpty {
            parts.insert("/" + dir, at: 0)
        }
        for e in extra where !parts.contains(e) { parts.append(e) }
        path = parts.joined(separator: ":")

        // Version + auth: run the binary DIRECTLY with the resolved PATH (each extra login shell cost
        // ~1 s here — sourcing the user's .zshrc/nvm — while the commands themselves take ~0.1 s),
        // and run both at once.
        var version: String?
        var loggedIn: Bool?
        if let claude {
            let env = ["PATH": path, "HOME": home]
            async let versionOut = run(claude, ["--version"], env: env)
            async let authOut = run(claude, ["auth", "status", "--json"], env: env)
            // e.g. "2.1.172 (Claude Code)"
            let v = await versionOut
            if let m = v.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) {
                version = String(v[m])
            }
            // Cheap, model-free auth probe: `claude auth status --json` → {"loggedIn": true/false,…}.
            // Only commit to true/false when the JSON says so; anything else stays nil (don't alarm).
            let auth = await authOut
            if auth.range(of: #""loggedIn"\s*:\s*true"#, options: .regularExpression) != nil { loggedIn = true }
            else if auth.range(of: #""loggedIn"\s*:\s*false"#, options: .regularExpression) != nil { loggedIn = false }
        }

        return ToolPaths(claude: claude, node: node, path: path, claudeVersion: version, loggedIn: loggedIn)
    }

    // MARK: launch cache

    private static let cacheKey = "rounds.toolPaths.v1"

    /// The tools found on the previous launch, if they're still where they were — lets Rounds open
    /// instantly and work right away while the real probe re-checks in the background.
    static func cached() -> ToolPaths? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let t = try? JSONDecoder().decode(ToolPaths.self, from: data) else { return nil }
        let fm = FileManager.default
        if let c = t.claude, !fm.isExecutableFile(atPath: c) { return nil }
        if let n = t.node, !fm.isExecutableFile(atPath: n) { return nil }
        return t
    }

    static func save(_ t: ToolPaths) {
        if let data = try? JSONEncoder().encode(t) { UserDefaults.standard.set(data, forKey: cacheKey) }
    }

    /// Run an executable directly (no shell) and return its stdout. Gives up after `timeout` seconds.
    static func run(_ exe: String, _ args: [String], env: [String: String], timeout: TimeInterval = 10) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: exe)
                proc.arguments = args
                var e = ProcessInfo.processInfo.environment
                for (k, v) in env { e[k] = v }
                proc.environment = e
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice
                proc.standardInput = FileHandle.nullDevice
                do {
                    try proc.run()
                    let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    killer.cancel()
                    cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    cont.resume(returning: "")
                }
            }
        }
    }

    static func runLoginShell(_ script: String) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                proc.arguments = ["-lic", script]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice
                proc.standardInput = FileHandle.nullDevice
                do {
                    try proc.run()
                    // A shell profile that hangs (or waits for input) must not stall the tool check forever.
                    let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    killer.cancel()
                    cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    cont.resume(returning: "")
                }
            }
        }
    }
}

nonisolated extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
