//
//  SearchIndex.swift
//  rounds
//
//  Local full-text search over chats (every message), documents (title, summary, markers) and next
//  steps. Built off the main thread whenever the vault changes; queried per keystroke (debounced).
//
//  Matching, per query word, against the index vocabulary (normalized: lowercase, no diacritics, ё→е):
//    • prefix  — "анализ" finds "анализами", "ferrit" finds "ferritin" (typing-as-you-go + inflections)
//    • typos   — bounded Damerau-Levenshtein (1 edit for 4–6 letters, 2 for 7+), also against the word's
//                prefix, so "фиритин" → "ферритин", "anlysis" → "analysis", "ferritn" → "ferritin"
//  A result must match EVERY query word (falls back to "most words" when nothing matches all of them).
//  Title hits outrank body hits; ties break by recency. The snippet is cut around the first hit.
//

import Foundation

nonisolated struct SearchDoc: Sendable {
    enum Kind: String, Sendable { case chat, document, step }
    var kind: Kind
    var id: String          // chat id / document relativePath / hypothesis id
    var title: String
    var body: String
    var date: Date?
}

nonisolated struct SearchHit: Sendable, Identifiable, Hashable {
    var id: String { "\(kind.rawValue):\(refId)" }
    var kind: SearchDoc.Kind
    var refId: String
    var title: String
    var snippet: String          // "" when the hit is in the title only
    var terms: [String]          // matched vocabulary words (normalized) — for highlighting
    var score: Double
}

nonisolated final class SearchIndex: @unchecked Sendable {
    private let docs: [SearchDoc]
    private var vocab: [[UInt32]] = []              // unique normalized tokens as unicode scalars
    private var vocabStrings: [String] = []
    private var postings: [[Int32]] = []            // vocab index → doc indices (body or title)
    private var titleTokens: [Set<Int32>] = []      // per doc: vocab indices present in the title

    init(_ docs: [SearchDoc]) {
        self.docs = docs
        var ids: [String: Int32] = [:]
        var post: [[Int32]] = []
        titleTokens = Array(repeating: [], count: docs.count)
        for (di, d) in docs.enumerated() {
            var seen = Set<Int32>()
            func add(_ tok: String, title: Bool) {
                let vi: Int32
                if let v = ids[tok] { vi = v } else {
                    vi = Int32(vocabStrings.count); ids[tok] = vi
                    vocabStrings.append(tok); vocab.append(tok.unicodeScalars.map(\.value)); post.append([])
                }
                if seen.insert(vi).inserted { post[Int(vi)].append(Int32(di)) }
                if title { titleTokens[di].insert(vi) }
            }
            for t in Self.tokens(d.title) { add(t, title: true) }
            for t in Self.tokens(d.body) { add(t, title: false) }
        }
        postings = post
    }

    var isEmpty: Bool { docs.isEmpty }

    // MARK: normalization

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
    }

    static func tokens(_ s: String) -> [String] {
        normalize(s).split { !($0.isLetter || $0.isNumber) }.compactMap { sub in
            sub.count >= 2 || sub.first?.isNumber == true ? String(sub) as String? : nil
        }
    }

    // MARK: query

    func search(_ query: String, limit: Int = 60) -> [SearchHit] {
        let qtoks = Array(Set(Self.tokens(query))).sorted { $0.count > $1.count }
        guard !qtoks.isEmpty, !docs.isEmpty else { return [] }

        // per query word: doc → (quality, vocab index of the best-matching word)
        var perWord: [[Int32: (Double, Int32)]] = []
        for q in qtoks {
            var best: [Int32: (Double, Int32)] = [:]
            for (vi, quality) in matches(for: q) {
                for di in postings[vi] {
                    let qual = quality * (titleTokens[Int(di)].contains(Int32(vi)) ? 3 : 1)
                    if (best[di]?.0 ?? 0) < qual { best[di] = (qual, Int32(vi)) }
                }
            }
            perWord.append(best)
        }

        var scored: [(Int32, Double, [Int32], Int)] = []   // doc, score, matched vocab, words matched
        var all = Set<Int32>()
        for m in perWord { all.formUnion(m.keys) }
        for di in all {
            var score = 0.0, terms: [Int32] = [], n = 0
            for m in perWord { if let (q, v) = m[di] { score += q; terms.append(v); n += 1 } }
            scored.append((di, score, terms, n))
        }
        let needAll = scored.contains { $0.3 == qtoks.count }
        let minWords = needAll ? qtoks.count : max(1, qtoks.count - 1)
        scored = scored.filter { $0.3 >= minWords }

        scored.sort { a, b in
            if a.3 != b.3 { return a.3 > b.3 }
            if abs(a.1 - b.1) > 0.01 { return a.1 > b.1 }
            return (docs[Int(a.0)].date ?? .distantPast) > (docs[Int(b.0)].date ?? .distantPast)
        }

        return scored.prefix(limit).map { (di, score, terms, _) in
            let d = docs[Int(di)]
            let words = terms.map { vocabStrings[Int($0)] }
            let inTitleOnly = terms.allSatisfy { titleTokens[Int(di)].contains($0) }
            return SearchHit(kind: d.kind, refId: d.id, title: d.title,
                             snippet: inTitleOnly ? Self.snippet(d.body, words: []) : Self.snippet(d.body, words: words),
                             terms: words, score: score)
        }
    }

    /// Vocabulary words matching one query word, with a quality in (0, 1.2].
    private func matches(for q: String) -> [(Int, Double)] {
        let qs = q.unicodeScalars.map(\.value)
        let maxEd = qs.count >= 7 ? 2 : (qs.count >= 4 ? 1 : 0)
        var out: [(Int, Double)] = []
        for (vi, t) in vocab.enumerated() {
            if t.count >= qs.count, t.starts(with: qs) {
                out.append((vi, t.count == qs.count ? 1.2 : 1.0))
                continue
            }
            guard maxEd > 0, abs(t.count - qs.count) <= maxEd || t.count > qs.count else { continue }
            // Cheap gate: typos rarely hit both of the first two letters.
            guard t.first == qs.first || (t.count > 1 && t[1] == qs[1]) else { continue }
            // Whole word, or the word's prefix (so a typo'd stem still finds inflected forms).
            var d = Self.distance(qs, t[...], maxEd)
            if d > maxEd, t.count > qs.count {
                for len in max(1, qs.count - 1)...min(t.count, qs.count + 1) {
                    d = min(d, Self.distance(qs, t[0..<len], maxEd))
                    if d <= 1 { break }
                }
            }
            if d <= maxEd { out.append((vi, d == 1 ? 0.75 : 0.5)) }
        }
        return out
    }

    /// Optimal-string-alignment (Damerau-Levenshtein) distance with an early exit above `cap`.
    private static func distance(_ a: [UInt32], _ b: ArraySlice<UInt32>, _ cap: Int) -> Int {
        let b = Array(b)
        let n = a.count, m = b.count
        if abs(n - m) > cap { return cap + 1 }
        if n == 0 { return m }; if m == 0 { return n }
        var prev2 = [Int](repeating: 0, count: m + 1)
        var prev = Array(0...m)
        var cur = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...m {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { v = min(v, prev2[j - 2] + 1) }
                cur[j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > cap { return cap + 1 }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        return prev[m]
    }

    /// ~150 chars of body around the first occurrence of any matched word, on one line.
    static func snippet(_ body: String, words: [String]) -> String {
        let flat = body.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: " ")
        var hit: Range<String.Index>?
        for w in words.sorted(by: { $0.count > $1.count }) {
            if let r = flat.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]),
               hit == nil || r.lowerBound < hit!.lowerBound { hit = r }
        }
        guard let r = hit else { return String(flat.prefix(140)).trimmingCharacters(in: .whitespaces) }
        let start = flat.index(r.lowerBound, offsetBy: -50, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: 100, limitedBy: flat.endIndex) ?? flat.endIndex
        var s = String(flat[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > flat.startIndex { s = "…" + s }
        if end < flat.endIndex { s += "…" }
        return s
    }
}
