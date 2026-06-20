//
//  ToolLocator.swift
//  rounds
//
//  Resolves absolute paths to the user's `claude` and `node` binaries, plus a usable
//  PATH. A macOS app launched from Finder gets a minimal environment that does NOT
//  include nvm / Homebrew / ~/.local/bin, so we probe a login shell once at startup.
//

import Foundation

nonisolated struct ToolPaths: Sendable {
    var claude: String?
    var node: String?
    var path: String

    var claudeInstalled: Bool { claude != nil }
    var nodeInstalled: Bool { node != nil }
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

        return ToolPaths(claude: claude, node: node, path: path)
    }

    static func runLoginShell(_ script: String) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                proc.arguments = ["-lic", script]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = Pipe()
                do {
                    try proc.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
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
