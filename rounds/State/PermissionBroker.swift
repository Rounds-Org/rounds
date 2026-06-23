//
//  PermissionBroker.swift
//  rounds
//
//  Bridges Claude Code's PreToolUse permission hook to a SwiftUI Allow/Deny dialog. The hook
//  (brain/mcp/permission-hook.mjs) writes a request file and waits for our response file; we watch
//  the dir, prompt the user, and write the decision. "Always allow" is recorded so the hook can
//  fast-path future calls of that tool.
//

import Foundation

struct PendingPermission: Identifiable, Equatable {
    let id: String          // tool_use_id
    let toolName: String
    let inputSummary: String
}

extension AppState {

    /// Start watching the handshake dir (idempotent). Called from bootstrap when full power is on.
    func startPermissionWatcher() {
        try? FileManager.default.createDirectory(at: permDir, withIntermediateDirectories: true)
        permTimer?.invalidate()
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanPermRequests() }
        }
        RunLoop.main.add(t, forMode: .common)
        permTimer = t
    }

    func stopPermissionWatcher() { permTimer?.invalidate(); permTimer = nil }

    private func scanPermRequests() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: permDir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix("req-") && f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = o["id"] as? String, !seenPermIds.contains(id) else { continue }
            // already answered?
            if fm.fileExists(atPath: permDir.appendingPathComponent("res-\(id).json").path) { continue }
            seenPermIds.insert(id)
            let tool = (o["tool_name"] as? String) ?? "a tool"
            let input = (o["tool_input"] as? [String: Any]) ?? [:]
            permQueue.append(PendingPermission(id: id, toolName: tool, inputSummary: Self.summarizePermInput(input)))
        }
        if pendingPermission == nil, !permQueue.isEmpty { pendingPermission = permQueue.removeFirst() }
    }

    func respondPermission(_ pp: PendingPermission, allow: Bool, always: Bool) {
        let resPath = permDir.appendingPathComponent("res-\(pp.id).json")
        let res: [String: Any] = ["decision": allow ? "allow" : "deny",
                                  "reason": allow ? "Approved in Rounds" : "Declined in Rounds"]
        try? JSONSerialization.data(withJSONObject: res).write(to: resPath)
        if always, allow { addAlwaysAllow(pp.toolName) }
        seenPermIds.remove(pp.id)
        pendingPermission = permQueue.isEmpty ? nil : permQueue.removeFirst()
    }

    private func addAlwaysAllow(_ tool: String) {
        let path = permDir.appendingPathComponent("always-allow.json")
        var list = (try? JSONSerialization.jsonObject(with: Data(contentsOf: path))) as? [String] ?? []
        if !list.contains(tool) { list.append(tool) }
        try? JSONSerialization.data(withJSONObject: list).write(to: path)
    }

    static func summarizePermInput(_ input: [String: Any]) -> String {
        for k in ["command", "query", "url", "prompt", "description", "pattern", "file_path"] {
            if let v = input[k] as? String, !v.isEmpty { return v }
        }
        if let d = try? JSONSerialization.data(withJSONObject: input),
           let s = String(data: d, encoding: .utf8) { return String(s.prefix(240)) }
        return ""
    }

    /// Write the settings file Rounds passes via --settings. In full-power mode it adds the
    /// PreToolUse permission hook (matching the risky tools) on top of the installed brain settings.
    func writeEffectiveSettings() {
        let fm = FileManager.default
        var base: [String: Any] = (try? JSONSerialization.jsonObject(with: Data(contentsOf: vault.brainSettings))) as? [String: Any] ?? [:]
        if fullPowerActive, let node = toolPaths.node {
            let hook = vault.brainDir.appendingPathComponent("mcp/permission-hook.mjs").path
            base["hooks"] = [
                "PreToolUse": [[
                    "matcher": "Bash|Task|WebSearch|KillShell|ToolSearch|Write|Edit|MultiEdit",
                    "hooks": [["type": "command", "command": "\"\(node)\" \"\(hook)\""]],
                ]],
            ]
        } else {
            base.removeValue(forKey: "hooks")
        }
        try? fm.createDirectory(at: vault.dotRounds, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: base, options: [.prettyPrinted]) {
            try? data.write(to: effectiveSettingsURL)
        }
    }

    var effectiveSettingsURL: URL { vault.dotRounds.appendingPathComponent("effective-settings.json") }
}
