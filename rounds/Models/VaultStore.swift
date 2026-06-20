//
//  VaultStore.swift
//  rounds
//
//  Reads the on-disk vault into model objects for the UI. The tree is the source of
//  truth; we scan it (small N) rather than trusting a cache. Group-by axes (person /
//  type / test-date) are derived here, never duplicated on disk.
//

import Foundation

nonisolated struct VaultSnapshot: Sendable {
    var people: [Person] = []
    var documents: [MedDocument] = []
    var hypotheses: [Hypothesis] = []
    var chats: [ChatSummary] = []
    var displayName: String = ""
}

nonisolated enum VaultStore {

    static func load(_ vault: VaultPaths) -> VaultSnapshot {
        var snap = VaultSnapshot()
        snap.displayName = readDisplayName(vault)
        snap.people = loadPeople(vault)
        snap.documents = loadDocuments(vault, people: snap.people)
        snap.hypotheses = loadHypotheses(vault)
        snap.chats = loadChats(vault)
        return snap
    }

    // MARK: people

    static func loadPeople(_ vault: VaultPaths) -> [Person] {
        let fm = FileManager.default
        var people: [Person] = []
        let dirs = (try? fm.contentsOfDirectory(at: vault.peopleDir, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let slug = dir.lastPathComponent
            let pj = dir.appendingPathComponent("person.json")
            // Tolerant parse: the brain may write relationshipToSelf or relationship, etc.
            if let data = try? Data(contentsOf: pj),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let name = (obj["displayName"] as? String) ?? (slug == "_self" ? "You" : slug.capitalized)
                let rel = (obj["relationshipToSelf"] as? String) ?? (obj["relationship"] as? String) ?? (slug == "_self" ? "self" : nil)
                people.append(Person(slug: slug, displayName: name, relationship: rel))
            } else {
                people.append(Person(slug: slug,
                                     displayName: slug == "_self" ? "You" : slug.capitalized,
                                     relationship: slug == "_self" ? "self" : nil))
            }
        }
        if !people.contains(where: { $0.slug == "_self" }) {
            people.insert(.selfPlaceholder, at: 0)
        }
        return people.sorted { ($0.slug == "_self" ? 0 : 1) < ($1.slug == "_self" ? 0 : 1) }
    }

    // MARK: documents

    static func loadDocuments(_ vault: VaultPaths, people: [Person]) -> [MedDocument] {
        let fm = FileManager.default
        var docs: [MedDocument] = []
        for person in people {
            let docsDir = vault.personDocs(person.slug)
            guard let items = try? fm.contentsOfDirectory(at: docsDir, includingPropertiesForKeys: nil) else { continue }
            for url in items where url.pathExtension.lowercased() == "json" {
                guard let data = try? Data(contentsOf: url),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                docs.append(parseSidecar(obj, sidecarURL: url, personSlug: person.slug, vault: vault))
            }
        }
        return docs.sorted { ($0.testDate ?? "") > ($1.testDate ?? "") }
    }

    /// Tolerant sidecar parsing — the brain's JSON evolves; never let one field break the UI.
    static func parseSidecar(_ obj: [String: Any], sidecarURL: URL, personSlug: String, vault: VaultPaths) -> MedDocument {
        func b(_ keys: [String], _ def: Bool) -> Bool {
            for k in keys { if let v = obj[k] as? Bool { return v } }
            return def
        }
        let personId = (obj["personId"] as? String) ?? personSlug
        let rawFile = (obj["rawFile"] as? String) ?? (obj["fileName"] as? String)
            ?? sidecarURL.deletingPathExtension().lastPathComponent
        let isImaging = b(["isImaging", "is_imaging"], false)
        let hasReport = b(["hasTextReport", "has_text_report"], !isImaging)
        let conclusionsBlocked = b(["conclusionsBlocked", "conclusions_blocked"], isImaging && !hasReport)

        var markers: [Marker] = []
        if let arr = obj["markers"] as? [[String: Any]] {
            for m in arr {
                markers.append(Marker(
                    name: (m["name"] as? String) ?? "—",
                    value: anyToString(m["value"]),
                    unit: m["unit"] as? String,
                    refLow: anyToDouble(m["refLow"]),
                    refHigh: anyToDouble(m["refHigh"]),
                    flag: m["flag"] as? String))
            }
        }
        let relPath = "people/\(personId)/documents/\(rawFile)"
        return MedDocument(
            id: (obj["id"] as? String) ?? rawFile,
            personId: personId,
            docType: (obj["docType"] as? String) ?? "document",
            title: obj["title"] as? String,
            analysisCategory: obj["analysisCategory"] as? String,
            testDate: obj["testDate"] as? String,
            sourceLab: obj["sourceLab"] as? String,
            fileName: rawFile,
            relativePath: relPath,
            isImaging: isImaging,
            hasTextReport: hasReport,
            conclusionsBlocked: conclusionsBlocked,
            summary: obj["summary"] as? String,
            markers: markers)
    }

    static func anyToString(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            let d = n.doubleValue
            return d == d.rounded() ? String(Int(d)) : String(d)
        }
        return ""
    }

    static func anyToDouble(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// The brain writes the sidecar but cannot move the raw binary (Bash is disabled).
    /// After intake we move the staged original into the destination the sidecar points to,
    /// matched by provenance.stagedFrom. Returns the new relative path if moved.
    @discardableResult
    static func reconcileStagedFile(stagedPath: String, vault: VaultPaths) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stagedPath) else { return nil }
        let peopleDirs = (try? fm.contentsOfDirectory(at: vault.peopleDir, includingPropertiesForKeys: nil)) ?? []
        for pdir in peopleDirs {
            let docsDir = pdir.appendingPathComponent("documents", isDirectory: true)
            guard let sidecars = try? fm.contentsOfDirectory(at: docsDir, includingPropertiesForKeys: nil) else { continue }
            for url in sidecars where url.pathExtension.lowercased() == "json" {
                guard let data = try? Data(contentsOf: url),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawFile = (obj["rawFile"] as? String) ?? (obj["fileName"] as? String)
                else { continue }
                let prov = obj["provenance"] as? [String: Any]
                let stagedFrom = (prov?["stagedFrom"] as? String) ?? (obj["stagedFrom"] as? String)
                let dest = docsDir.appendingPathComponent(rawFile)
                let matches = stagedFrom == stagedPath || (!fm.fileExists(atPath: dest.path) && stagedFrom == nil)
                if matches, !fm.fileExists(atPath: dest.path) {
                    do {
                        try fm.moveItem(at: URL(fileURLWithPath: stagedPath), to: dest)
                        return "\(pdir.lastPathComponent)/documents/\(rawFile)"
                    } catch { return nil }
                }
            }
        }
        return nil
    }

    // MARK: hypotheses

    static func loadHypotheses(_ vault: VaultPaths) -> [Hypothesis] {
        let fm = FileManager.default
        var hyps: [Hypothesis] = []

        // Hypotheses may live top-level (~/Rounds/hypotheses/) OR per-person
        // (~/Rounds/people/<slug>/hypotheses/). Scan both.
        var containers: [URL] = [vault.hypothesesDir]
        let peopleDirs = (try? fm.contentsOfDirectory(at: vault.peopleDir, includingPropertiesForKeys: nil)) ?? []
        for p in peopleDirs { containers.append(p.appendingPathComponent("hypotheses", isDirectory: true)) }

        for container in containers {
            let dirs = (try? fm.contentsOfDirectory(at: container, includingPropertiesForKeys: nil)) ?? []
            for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let hj = dir.appendingPathComponent("hypothesis.json")
                guard let data = try? Data(contentsOf: hj),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                var h = parseHypothesis(obj)
                h.body = try? String(contentsOf: dir.appendingPathComponent("hypothesis.md"), encoding: .utf8)
                hyps.append(h)
            }
        }
        return hyps.sorted { priorityRank($0.priority) < priorityRank($1.priority) }
    }

    static func parseHypothesis(_ obj: [String: Any]) -> Hypothesis {
        let sc: Int = {
            if let i = obj["sourceCount"] as? Int { return i }
            if let n = obj["sourceCount"] as? NSNumber { return n.intValue }
            if let arr = obj["sources"] as? [Any] { return arr.count }
            return 0
        }()
        let askPlaceholder = (obj["ask"] as? [String: Any])?["placeholder"] as? String
            ?? obj["askPlaceholder"] as? String
        return Hypothesis(
            id: (obj["id"] as? String) ?? UUID().uuidString,
            title: (obj["title"] as? String) ?? "Next step",
            whyNow: (obj["whyNow"] as? String) ?? (obj["why_now"] as? String) ?? "",
            personId: (obj["personId"] as? String) ?? (obj["person"] as? String) ?? "_self",
            priority: (obj["priority"] as? String) ?? "medium",
            kind: (obj["kind"] as? String) ?? "get-more-data",
            status: (obj["status"] as? String) ?? "proposed",
            sourceCount: sc,
            topTier: obj["topTier"] as? String,
            body: nil,
            askPlaceholder: askPlaceholder,
            answer: obj["answer"] as? String,
            answeredAt: (obj["answeredAt"] as? String) ?? (obj["answered_at"] as? String))
    }

    static func priorityRank(_ p: String) -> Int {
        switch p { case "high": 0; case "medium": 1; default: 2 }
    }

    // MARK: chats

    static func loadChats(_ vault: VaultPaths) -> [ChatSummary] {
        let fm = FileManager.default
        var chats: [ChatSummary] = []
        let items = (try? fm.contentsOfDirectory(at: vault.chatsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in items where url.pathExtension.lowercased() == "md" {
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            let id = url.deletingPathExtension().lastPathComponent
            let title = firstHeading(in: url) ?? id
            chats.append(ChatSummary(id: id, title: title, hypothesisId: nil, updatedAt: mod, sessionId: nil))
        }
        return chats.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func saveChatSources(_ id: String, _ sources: [Source], _ vault: VaultPaths) {
        let url = vault.chatsDir.appendingPathComponent("\(id).sources.json")
        guard !sources.isEmpty else { try? FileManager.default.removeItem(at: url); return }
        if let data = try? JSONEncoder().encode(sources) {
            try? FileManager.default.createDirectory(at: vault.chatsDir, withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    static func loadChatSources(_ id: String, _ vault: VaultPaths) -> [Source] {
        let url = vault.chatsDir.appendingPathComponent("\(id).sources.json")
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode([Source].self, from: data) else { return [] }
        return s
    }

    private static func firstHeading(in url: URL) -> String? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in s.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("title:") { return String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return nil
    }

    // MARK: settings

    static func readString(_ key: String, _ vault: VaultPaths) -> String? {
        guard let data = try? Data(contentsOf: vault.settingsJson),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj[key] as? String
    }

    static func writeString(_ key: String, _ value: String, _ vault: VaultPaths) {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: vault.settingsJson),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = existing
        }
        obj[key] = value
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) {
            try? FileManager.default.createDirectory(at: vault.dotRounds, withIntermediateDirectories: true)
            try? data.write(to: vault.settingsJson)
        }
    }

    static func readDisplayName(_ vault: VaultPaths) -> String { readString("displayName", vault) ?? "" }
    static func writeDisplayName(_ name: String, _ vault: VaultPaths) { writeString("displayName", name, vault) }
}
