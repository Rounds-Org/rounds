//
//  BrainInstaller.swift
//  rounds
//
//  Lays the embedded "brain" onto disk at ~/Rounds on first run (and re-installs on a
//  version bump). After this, the user's local Claude Code is pointed at this vault via
//  cwd + --mcp-config + --settings, and everything is plain, auditable files.
//

import Foundation

nonisolated enum BrainInstaller {

    static func needsInstall(_ vault: VaultPaths) -> Bool {
        guard let data = try? Data(contentsOf: vault.brainVersion),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let installed = obj["brainVersion"] as? String
        else { return true }
        return installed != BrainResources.brainVersion
    }

    @discardableResult
    static func installIfNeeded(_ vault: VaultPaths, toolPaths: ToolPaths) throws -> Bool {
        try vault.ensureScaffold()
        guard needsInstall(vault) else { return false }
        try install(vault, toolPaths: toolPaths)
        return true
    }

    static func install(_ vault: VaultPaths, toolPaths: ToolPaths) throws {
        try vault.ensureScaffold()

        // Global contract (auto-loaded as project memory from cwd). Brain-owned: always
        // (re)written on update. It imports the user's family memory, which we never clobber.
        try write(BrainResources.claudeMd, to: vault.claudeMd)

        // User family memory — created once, then owned by the brain at runtime. NEVER
        // overwritten on a version bump, so a brain update can't wipe family facts.
        let memory = vault.dotRounds.appendingPathComponent("memory.md")
        if !FileManager.default.fileExists(atPath: memory.path) {
            try write("# Family memory\n\n_Confirmed durable facts the assistant has learned. Grounding only._\n", to: memory)
        }

        // Prompts + config inside the namespaced brain dir.
        try write(BrainResources.systemCompact, to: vault.systemCompact)
        try write(BrainResources.intakePrompt, to: vault.promptsDir.appendingPathComponent("intake.md"))
        try write(BrainResources.intakeBatch, to: vault.promptsDir.appendingPathComponent("intake_batch.md"))
        try write(BrainResources.hypothesesPrompt, to: vault.promptsDir.appendingPathComponent("hypotheses.md"))
        try write(BrainResources.chatPrompt, to: vault.promptsDir.appendingPathComponent("chat.md"))
        try write(BrainResources.complaintPrompt, to: vault.promptsDir.appendingPathComponent("complaint.md"))
        try write(BrainResources.settingsJson, to: vault.brainSettings)
        try write(BrainResources.criticalValues, to: vault.criticalValues)
        try write(BrainResources.redFlagSymptoms, to: vault.brainDir.appendingPathComponent("red-flag-symptoms.json"))
        try write(BrainResources.mcpIndexMjs, to: vault.mcpIndex)

        // mcp.json with the resolved absolute node + server paths.
        let node = toolPaths.node ?? "/usr/bin/env node"
        let mcp = BrainResources.mcpTemplate
            .replacingOccurrences(of: "{{NODE_PATH}}", with: node)
            .replacingOccurrences(of: "{{MCP_INDEX_PATH}}", with: vault.mcpIndex.path)
        try write(mcp, to: vault.mcpConfig)

        // Stamp the installed version.
        let stamp: [String: Any] = ["brainVersion": BrainResources.brainVersion,
                                    "installedAt": ISO8601DateFormatter().string(from: Date())]
        let data = try JSONSerialization.data(withJSONObject: stamp, options: .prettyPrinted)
        try data.write(to: vault.brainVersion)
    }

    private static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.data(using: .utf8)?.write(to: url)
    }
}
