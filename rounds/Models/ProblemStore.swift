//
//  ProblemStore.swift
//  rounds
//
//  The per-person PROBLEM LIST (people/<slug>/problems.json): problems → next steps. It is the one
//  shared plan every Rounds session reads and edits. Claude sessions change it through the
//  rounds-sources MCP tools (`problems_get` / `problems_update`); the app changes it here for the
//  deterministic actions (mark a step done, record an answer, resolve a problem). Both sides use the
//  same protocol so parallel writers never clobber each other:
//    • a per-person lock directory `people/<slug>/.problems.lock` (mkdir is atomic across processes),
//    • read-modify-write of the freshest file under the lock, field-level patches only,
//    • atomic replace (temp file + rename), with `revision` bumped on every write.
//

import Foundation

nonisolated enum ProblemStore {

    static func url(_ slug: String, _ vault: VaultPaths) -> URL {
        vault.personDir(slug).appendingPathComponent("problems.json")
    }

    // MARK: load

    static func loadAll(_ vault: VaultPaths, people: [Person]) -> [ProblemList] {
        people.compactMap { load($0.slug, vault) }
    }

    /// nil when the person has no problem list yet (never migrated, nothing reviewed).
    static func load(_ slug: String, _ vault: VaultPaths) -> ProblemList? {
        guard let data = try? Data(contentsOf: url(slug, vault)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let problems = (obj["problems"] as? [[String: Any]] ?? []).map { parseProblem($0, person: slug) }
        return ProblemList(personId: slug, problems: problems,
                           migratedLegacy: obj["migratedLegacy"] as? Bool ?? false,
                           revision: (obj["revision"] as? NSNumber)?.intValue ?? 0)
    }

    static func parseProblem(_ o: [String: Any], person: String) -> Problem {
        let id = (o["id"] as? String) ?? UUID().uuidString
        let steps: [Hypothesis] = (o["steps"] as? [[String: Any]] ?? []).map { so in
            var h = VaultStore.parseHypothesis(so)
            h.personId = person
            h.problemId = id
            h.body = (so["detail"] as? String) ?? (so["body"] as? String)
            h.sessionId = so["sessionId"] as? String
            h.statusReason = so["statusReason"] as? String
            if h.status == "proposed" || h.status == "active" { h.status = "open" }
            return h
        }
        return Problem(
            id: id, personId: person,
            title: (o["title"] as? String) ?? "Problem",
            status: (o["status"] as? String) ?? "active",
            priority: (o["priority"] as? String) ?? "medium",
            summary: (o["summary"] as? String) ?? "",
            sources: VaultStore.parseSourceList(o["sources"]),
            steps: steps,
            updatedAt: o["updatedAt"] as? String,
            updatedBy: o["updatedBy"] as? String)
    }

    /// Cheap change detector for the background watcher: each person's problems.json mtime + size.
    static func signature(_ vault: VaultPaths) -> String {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(atPath: vault.peopleDir.path)) ?? []
        var parts: [String] = []
        for d in dirs.sorted() where !d.hasPrefix(".") {
            let p = vault.peopleDir.appendingPathComponent(d).appendingPathComponent("problems.json").path
            if let a = try? fm.attributesOfItem(atPath: p) {
                let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                parts.append("\(d):\(m):\((a[.size] as? NSNumber)?.intValue ?? 0)")
            }
        }
        return parts.joined(separator: "|")
    }

    // MARK: write (app-side deterministic actions)

    enum StoreError: Error { case busy, unreadable }

    /// Apply `body` to the person's problem list under the cross-process lock. Runs synchronously —
    /// call it off the main thread (it may wait for another session's write to finish).
    @discardableResult
    static func mutate(_ slug: String, _ vault: VaultPaths, _ body: (inout [String: Any]) -> Void) throws -> [String: Any] {
        let fm = FileManager.default
        let dir = vault.personDir(slug)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let lock = dir.appendingPathComponent(".problems.lock", isDirectory: true)
        let deadline = Date().addingTimeInterval(10)
        while true {
            do { try fm.createDirectory(at: lock, withIntermediateDirectories: false); break } catch {
                // A crashed writer can't hold the lock forever.
                if let m = (try? fm.attributesOfItem(atPath: lock.path))?[.modificationDate] as? Date,
                   Date().timeIntervalSince(m) > 20 {
                    try? fm.removeItem(at: lock); continue
                }
                if Date() > deadline { throw StoreError.busy }
                usleep(25_000)
            }
        }
        defer { try? fm.removeItem(at: lock) }

        let file = url(slug, vault)
        var obj: [String: Any] = ["schemaVersion": 1, "person": slug, "revision": 0, "problems": [[String: Any]]()]
        if let data = try? Data(contentsOf: file) {
            guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StoreError.unreadable }
            obj = o
        }
        body(&obj)
        obj["revision"] = ((obj["revision"] as? NSNumber)?.intValue ?? 0) + 1
        obj["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        obj["updatedBy"] = "rounds-app"
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: file, options: .atomic)
        return obj
    }

    /// Find a step by id anywhere in the list and edit it in place.
    private static func editStep(_ obj: inout [String: Any], _ stepId: String, _ edit: (inout [String: Any]) -> Void) {
        guard var problems = obj["problems"] as? [[String: Any]] else { return }
        for pi in problems.indices {
            guard var steps = problems[pi]["steps"] as? [[String: Any]] else { continue }
            if let si = steps.firstIndex(where: { ($0["id"] as? String) == stepId }) {
                edit(&steps[si])
                steps[si]["updatedAt"] = ISO8601DateFormatter().string(from: Date())
                steps[si]["updatedBy"] = "rounds-app"
                problems[pi]["steps"] = steps
                problems[pi]["updatedAt"] = ISO8601DateFormatter().string(from: Date())
                obj["problems"] = problems
                return
            }
        }
    }

    static func setStepStatus(_ slug: String, stepId: String, status: String, reason: String? = nil, _ vault: VaultPaths) throws {
        try mutate(slug, vault) { obj in
            editStep(&obj, stepId) { s in
                s["status"] = status
                if let reason { s["statusReason"] = reason }
            }
        }
    }

    static func answerStep(_ slug: String, stepId: String, question: String, answer: String, _ vault: VaultPaths) throws {
        let today = Self.today()
        try mutate(slug, vault) { obj in
            editStep(&obj, stepId) { s in
                s["answer"] = answer
                s["answeredAt"] = today
                s["status"] = "done"
            }
        }
        appendConfirmedHistory(slug, question: question, answer: answer, stepId: stepId, vault)
    }

    static func setProblemStatus(_ slug: String, problemId: String, status: String, _ vault: VaultPaths) throws {
        try mutate(slug, vault) { obj in
            guard var problems = obj["problems"] as? [[String: Any]],
                  let i = problems.firstIndex(where: { ($0["id"] as? String) == problemId }) else { return }
            problems[i]["status"] = status
            problems[i]["updatedAt"] = ISO8601DateFormatter().string(from: Date())
            var log = problems[i]["log"] as? [[String: Any]] ?? []
            log.append(["at": ISO8601DateFormatter().string(from: Date()), "by": "rounds-app", "note": "status → \(status) (by the user)"])
            problems[i]["log"] = Array(log.suffix(30))
            obj["problems"] = problems
        }
    }

    /// A person with nothing to carry over still gets a (possibly empty) list marked migrated, so the
    /// one-time move of legacy cards never runs for them again.
    static func markMigrated(_ slug: String, _ vault: VaultPaths) throws {
        try mutate(slug, vault) { obj in obj["migratedLegacy"] = true }
    }

    /// Fallback for a legacy `rounds.hypotheses` block (an old prompt in a resumed session): file the
    /// cards as steps under one "Other next steps" problem rather than dropping them.
    static func addLooseSteps(_ slug: String, _ steps: [Hypothesis], _ vault: VaultPaths) throws {
        try mutate(slug, vault) { obj in
            var problems = obj["problems"] as? [[String: Any]] ?? []
            let pid = "prob_other"
            var idx = problems.firstIndex { ($0["id"] as? String) == pid }
            if idx == nil {
                problems.append(["id": pid, "title": "Other next steps", "status": "active", "priority": "low",
                                 "summary": "", "sources": [], "steps": [], "createdAt": ISO8601DateFormatter().string(from: Date())])
                idx = problems.count - 1
            }
            var list = problems[idx!]["steps"] as? [[String: Any]] ?? []
            for h in steps where !list.contains(where: { ($0["id"] as? String) == h.id }) {
                var d: [String: Any] = ["id": h.id, "title": h.title, "whyNow": h.whyNow, "kind": h.kind,
                                        "priority": h.priority, "status": "open", "detail": h.body ?? ""]
                if !h.sources.isEmpty {
                    d["sources"] = h.sources.map { ["id": $0.id, "title": $0.title, "url": $0.url ?? "", "tier": $0.trustTier] }
                    d["sourceCount"] = h.sources.count
                }
                if let p = h.askPlaceholder { d["ask"] = ["placeholder": p] }
                list.append(d)
            }
            problems[idx!]["steps"] = list
            obj["problems"] = problems
        }
    }

    // MARK: confirmed history

    /// Same line format the MCP server writes for `answer_step`, so a fact is never filed twice.
    static func appendConfirmedHistory(_ slug: String, question: String, answer: String, stepId: String, _ vault: VaultPaths) {
        let file = vault.personDir(slug).appendingPathComponent("CLAUDE.md")
        var md = (try? String(contentsOf: file, encoding: .utf8)) ?? "# About \(slug)\n"
        let heading = "## Confirmed history (from questions)"
        if md.contains("(step \(stepId))"), md.contains(String(answer.prefix(40))) { return }
        if !md.contains(heading) {
            md = md.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n\(heading)\n"
        }
        let flat = { (s: String) in s.replacingOccurrences(of: "\n", with: " ") }
        md = md.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n- \(today()) · Q: \"\(flat(question))\" — A (user, verbatim): \"\(flat(answer))\" (step \(stepId))\n"
        try? md.data(using: .utf8)?.write(to: file, options: .atomic)
    }

    static func today() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: Date())
    }
}
