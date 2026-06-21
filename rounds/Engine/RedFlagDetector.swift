//
//  RedFlagDetector.swift
//  rounds
//
//  Principle 6, hardened onto the DETERMINISTIC plane. A curated red-flag-symptoms.json
//  (bundled via BrainResources) drives a pure-Swift scan over the user's free text that runs
//  BEFORE — and independently of — the model. On a match the app raises the urgent banner no
//  matter what the model says. A non-match never means "safe": it means "no known pattern
//  detected", and the brain still adds a "this doesn't rule anything out" line.
//

import Foundation

nonisolated struct RedFlagMatch: Sendable, Equatable {
    var id: String
    var label: String
    var kind: String        // "emergency" | "crisis"
    var message: String
    var asAlert: RoundsAlert {
        RoundsAlert(severity: kind == "crisis" ? "crisis" : "emergency",
                    marker: label, value: nil, basis: "matched a red-flag symptom pattern",
                    message: message)
    }
}

nonisolated enum RedFlagDetector {

    private struct Rule {
        let id: String, label: String, kind: String, message: String
        let all: [NSRegularExpression]
        let anyOf: [NSRegularExpression]
    }

    /// Parsed once from the embedded JSON. The curated content is open-source and auditable.
    private static let rules: [Rule] = parse(BrainResources.redFlagSymptoms)

    /// The first red-flag rule that fires on this free text, or nil. Deterministic, no model.
    static func detect(_ text: String) -> RedFlagMatch? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3 else { return nil }
        let ns = t as NSString
        let full = NSRange(location: 0, length: ns.length)
        for r in rules {
            let allHit = r.all.allSatisfy { $0.firstMatch(in: t, range: full) != nil }
            guard allHit else { continue }
            let anyHit = r.anyOf.isEmpty || r.anyOf.contains { $0.firstMatch(in: t, range: full) != nil }
            guard anyHit else { continue }
            return RedFlagMatch(id: r.id, label: r.label, kind: r.kind, message: r.message)
        }
        return nil
    }

    // MARK: parse

    private static func parse(_ json: String) -> [Rule] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["rules"] as? [[String: Any]] else { return [] }
        func compile(_ any: Any?) -> [NSRegularExpression] {
            (any as? [String] ?? []).compactMap {
                try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
            }
        }
        return arr.compactMap { o in
            guard let id = o["id"] as? String, let msg = o["message"] as? String else { return nil }
            return Rule(id: id,
                        label: (o["label"] as? String) ?? "Possible emergency",
                        kind: (o["kind"] as? String) ?? "emergency",
                        message: msg,
                        all: compile(o["all"]),
                        anyOf: compile(o["anyOf"]))
        }
    }
}
