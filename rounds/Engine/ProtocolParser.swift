//
//  ProtocolParser.swift
//  rounds
//
//  The brain emits structured intent as fenced ```json blocks containing keys like
//  "rounds.questions", "rounds.sources", "rounds.alert", "rounds.hypotheses". This
//  extracts and decodes them, and returns the human-facing text with those blocks
//  stripped out (so the chat shows prose, not JSON).
//

import Foundation

nonisolated struct ParsedTurn: Sendable {
    var displayText: String = ""
    var questions: [RoundsQuestion] = []
    var sources: [Source] = []
    var hypotheses: [Hypothesis] = []
    var alert: RoundsAlert?
    var turnMeta: [String: Bool] = [:]
    var draftPersonSlug: String?       // from rounds.draft_classification
    var draftConfidence: String?
    var planFiles: [PlanFile] = []     // from rounds.intake_plan
    var planQuestions: [PlanQuestion] = []
    var stepActions: [StepAction] = [] // from rounds.step_action
}

nonisolated enum ProtocolParser {

    static func parse(_ raw: String) -> ParsedTurn {
        var result = ParsedTurn()
        var display = raw

        for block in fencedJSONBlocks(in: raw) {
            guard let data = block.json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            var consumed = false

            if let arr = obj["rounds.questions"] {
                result.questions += decode([RoundsQuestion].self, from: arr) ?? []
                consumed = true
            }
            if let arr = obj["rounds.sources"] {
                result.sources += parseSources(arr)
                consumed = true
            }
            if let arr = obj["rounds.hypotheses"] as? [[String: Any]] {
                result.hypotheses += arr.map { VaultStore.parseHypothesis($0) }
                consumed = true
            }
            if let a = obj["rounds.alert"] {
                if let alert = decode(RoundsAlert.self, from: a) { result.alert = alert }
                consumed = true
            }
            if let meta = obj["rounds.turn_meta"] as? [String: Any] {
                for (k, v) in meta { if let b = v as? Bool { result.turnMeta[k] = b } }
                consumed = true
            }
            if let draft = obj["rounds.draft_classification"] as? [String: Any] {
                if let guess = draft["person_guess"] as? [String: Any] {
                    result.draftPersonSlug = guess["slug"] as? String
                    result.draftConfidence = guess["confidence"] as? String
                }
                consumed = true
            }
            if let plan = obj["rounds.intake_plan"] as? [String: Any] {
                if let files = plan["files"] as? [[String: Any]] {
                    result.planFiles += files.map { f in
                        let guess = f["person_guess"] as? [String: Any]
                        return PlanFile(
                            index: intOf(f["index"]) ?? 0,
                            slug: (guess?["slug"] as? String) ?? (f["slug"] as? String) ?? "new",
                            confidence: (guess?["confidence"] as? String) ?? (f["confidence"] as? String) ?? "low",
                            title: (f["title"] as? String) ?? "Document",
                            isImaging: (f["is_imaging"] as? Bool) ?? false)
                    }
                }
                if let qs = plan["questions"] as? [[String: Any]] {
                    result.planQuestions += qs.map { q in
                        let opts = (q["options"] as? [[String: Any]])?.compactMap { o -> QuestionOption? in
                            guard let id = o["id"] as? String else { return nil }
                            return QuestionOption(id: id, label: (o["label"] as? String) ?? id)
                        } ?? []
                        let idx = (q["file_indices"] as? [Any])?.compactMap { intOf($0) } ?? []
                        return PlanQuestion(
                            id: (q["id"] as? String) ?? "q",
                            title: (q["title"] as? String) ?? "Who is this for?",
                            context: q["context"] as? String,
                            options: opts,
                            fileIndices: idx,
                            allowFreeform: (q["allow_freeform"] as? Bool) ?? true,
                            requiresContinue: (q["requires_continue"] as? Bool) ?? true,
                            asksName: (q["asks_name"] as? Bool) ?? false)
                    }
                }
                consumed = true
            }
            if let sa = obj["rounds.step_action"] {
                let items: [[String: Any]] = (sa as? [[String: Any]]) ?? ((sa as? [String: Any]).map { [$0] } ?? [])
                for o in items {
                    if let id = o["id"] as? String, !id.isEmpty {
                        result.stepActions.append(StepAction(id: id, action: (o["action"] as? String) ?? "relanguage",
                                                             answer: o["answer"] as? String))
                    }
                }
                consumed = true
            }
            if obj["rounds.pending_artifact"] != nil { consumed = true }

            // Remove any block that carried Rounds protocol from the visible text.
            if consumed { display = display.replacingOccurrences(of: block.full, with: "") }
        }

        result.displayText = display.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    /// Display text for a STREAMING (possibly mid-block) buffer: strips complete protocol
    /// blocks AND any trailing unclosed code fence, so raw JSON never flashes on screen.
    static func stripForDisplay(_ raw: String) -> String {
        var s = parse(raw).displayText
        let fenceCount = s.components(separatedBy: "```").count - 1
        if fenceCount % 2 == 1, let r = s.range(of: "```", options: .backwards) {
            s = String(s[..<r.lowerBound])
        }
        // Also cut a trailing bare "{ ...rounds... " object that hasn't closed yet.
        if let r = s.range(of: "{", options: .backwards) {
            let tail = s[r.lowerBound...]
            if tail.contains("\"rounds.") && !tail.contains("}") {
                s = String(s[..<r.lowerBound])
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pull citations out of a rounds-sources tool result so sources can appear progressively
    /// (before the model writes its final answer + curated rounds.sources block).
    static func citationsFromToolResult(_ payload: String) -> [Source] {
        guard payload.contains("\"title\"") else { return [] }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var arr: [[String: Any]] = []
        if let a = obj as? [[String: Any]] { arr = a }
        else if let d = obj as? [String: Any] {
            for key in ["citations", "results", "ranked", "sources"] {
                if let c = d[key] as? [[String: Any]] { arr = c; break }
            }
            if arr.isEmpty {   // fallback: first array-of-objects that has titles
                for v in d.values { if let c = v as? [[String: Any]], c.first?["title"] != nil { arr = c; break } }
            }
        }
        guard !arr.isEmpty else { return [] }
        return arr.prefix(8).enumerated().map { (i, o) in
            let pmid = o["pmid"] as? String
            let doi = o["doi"] as? String
            var url = o["url"] as? String
            if url == nil, let pmid { url = "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/" }
            if url == nil, let doi { url = "https://doi.org/\(doi)" }
            let year = (o["year"] as? Int) ?? (o["year"] as? NSNumber)?.intValue
            let cited = (o["citedBy"] as? Int) ?? (o["citedBy"] as? NSNumber)?.intValue
            return Source(id: "\(i + 1)", title: (o["title"] as? String) ?? "Source",
                          url: url, type: o["source"] as? String,
                          trustTier: (o["trustTier"] as? String) ?? (o["tier"] as? String) ?? "—",
                          year: year, journal: o["journal"] as? String, citedBy: cited,
                          whyTrusted: o["whyTrusted"] as? String)
        }
    }

    // MARK: - helpers

    /// Tolerant int: the model may emit 0, "0", or 0.0.
    private static func intOf(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private static func decode<T: Decodable>(_ type: T.Type, from any: Any) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        let dec = JSONDecoder()
        return try? dec.decode(T.self, from: data)
    }

    /// Tolerant source mapping — the brain may use id/ref, trustTier/tier, and pmid/doi
    /// instead of a url.
    private static func parseSources(_ any: Any) -> [Source] {
        guard let arr = any as? [[String: Any]] else { return [] }
        return arr.map { o in
            let id = (o["id"] as? String) ?? (o["ref"] as? String) ?? "S?"
            let tier = (o["trustTier"] as? String) ?? (o["tier"] as? String) ?? "—"
            var url = o["url"] as? String
            if url == nil, let pmid = o["pmid"] as? String { url = "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/" }
            if url == nil, let doi = o["doi"] as? String { url = "https://doi.org/\(doi)" }
            let year = (o["year"] as? Int) ?? (o["year"] as? NSNumber)?.intValue
            let citedBy = (o["citedBy"] as? Int) ?? (o["citedBy"] as? NSNumber)?.intValue
            return Source(id: id, title: (o["title"] as? String) ?? "",
                          url: url, type: o["type"] as? String, trustTier: tier,
                          year: year, journal: o["journal"] as? String, citedBy: citedBy,
                          whyTrusted: (o["whyTrusted"] as? String) ?? (o["why_trusted"] as? String))
        }
    }

    private struct Block { var full: String; var json: String }

    /// Finds ```json ... ``` (and bare ``` ... ```) fenced blocks.
    private static func fencedJSONBlocks(in text: String) -> [Block] {
        var blocks: [Block] = []
        let ns = text as NSString
        let pattern = "```(?:json)?\\s*([\\s\\S]*?)```"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches where m.numberOfRanges >= 2 {
            let full = ns.substring(with: m.range(at: 0))
            let inner = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if inner.contains("rounds.") {
                blocks.append(Block(full: full, json: inner))
            }
        }
        return blocks
    }
}
