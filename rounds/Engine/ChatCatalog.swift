//
//  ChatCatalog.swift
//  rounds
//
//  Derived, read-only facts about every chat, computed OFF the main thread from the chat .md files:
//  who the chat is about (for the sidebar's group-by-person) and its full text (for search).
//  Parsed files are cached by modification date, so a rebuild after one chat changes re-reads one file.
//
//  Person attribution (a user override always wins — see AppState.chatPersonOverrides):
//    1. `nextsteps-<slug>` chats belong to <slug>.
//    2. @-references in the chat: a person, a file (its owner), a next step (its person) — strong signal.
//    3. Mentions in the USER's messages: the person's name (stem, so inflected Russian forms count) or
//       their relationship ("mom", "мама", "жена"…). The first message counts triple.
//    4. Nothing points elsewhere → the user themself (`_self`).
//

import Foundation

nonisolated struct ParsedChatFile: Sendable {
    var title: String
    var userText: String
    var firstUserText: String
    var allText: String
    var references: [Reference]
}

nonisolated enum ChatCatalog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (Date, ParsedChatFile)] = [:]

    static func parse(_ url: URL) -> ParsedChatFile? {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        lock.lock()
        if let (d, p) = cache[url.path], d == mod { lock.unlock(); return p }
        lock.unlock()
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var title = url.deletingPathExtension().lastPathComponent
        var body = Substring(s)
        if s.hasPrefix("---"), let end = s.range(of: "\n---", range: s.index(s.startIndex, offsetBy: 3)..<s.endIndex) {
            for line in s[s.startIndex..<end.lowerBound].split(separator: "\n") where line.hasPrefix("title:") {
                title = line.dropFirst(6).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            body = s[end.upperBound...]
        }

        var user = "", firstUser: String?, all = "", refs: [Reference] = []
        var role = "", buf = ""
        func flush() {
            let t = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                let clean = role == "assistant" ? ProtocolParser.stripForDisplay(t) : t
                all += clean + "\n"
                if role == "user" { user += t + "\n"; if firstUser == nil { firstUser = t } }
            }
            buf = ""
        }
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("<!-- rounds:msg role=") {
                flush()
                let inner = line.dropFirst("<!-- rounds:msg role=".count).replacingOccurrences(of: " -->", with: "")
                let parts = inner.split(separator: " ", maxSplits: 1)
                role = parts.first.map(String.init) ?? ""
                if parts.count > 1, parts[1].hasPrefix("refs="),
                   let data = Data(base64Encoded: String(parts[1].dropFirst(5))),
                   let r = try? JSONDecoder().decode([Reference].self, from: data) { refs += r }
            } else if ["## user", "## assistant", "## system"].contains(line.trimmingCharacters(in: .whitespaces)) {
                flush(); role = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)   // legacy format
            } else {
                buf += line + "\n"
            }
        }
        flush()
        let parsed = ParsedChatFile(title: title, userText: user, firstUserText: firstUser ?? "", allText: all, references: refs)
        lock.lock(); cache[url.path] = (mod, parsed); lock.unlock()
        return parsed
    }

    /// Relationship words (stems) per relationship key, in English + Russian.
    private static let relationshipStems: [(String, [String])] = [
        ("mother_in_law", ["тещ", "свекров", "motherinlaw"]),
        ("grandmother", ["бабушк", "бабул", "grandm", "granny", "grandma"]),
        ("grandfather", ["дедушк", "grandf", "grandpa"]),
        ("mother", ["мама", "мамы", "маме", "маму", "мамой", "мать", "матер", "mother", "mom", "mum"]),
        ("father", ["папа", "папы", "папе", "папу", "папой", "отец", "отца", "отцу", "отцом", "father", "dad"]),
        ("wife", ["жена", "жены", "жене", "жену", "женой", "супруг", "wife"]),
        ("husband", ["муж", "мужа", "мужу", "мужем", "husband"]),
        ("son", ["сын", "son"]),
        ("daughter", ["доч", "daughter"]),
        ("brother", ["брат", "brother"]),
        ("sister", ["сестр", "sister"]),
    ]

    private static func relationshipKey(_ p: Person) -> String? {
        let r = ((p.relationship ?? "") + " " + p.slug).lowercased()
        if r.contains("wife_mother") || r.contains("in-law") || r.contains("in_law") { return "mother_in_law" }
        if r.contains("grandmother") { return "grandmother" }
        if r.contains("grandfather") { return "grandfather" }
        for (key, _) in relationshipStems where r.contains(key) { return key }
        return nil
    }

    /// Name stems: each word of the display name (parenthesized notes like "(мама Ани)" dropped), long
    /// words trimmed by one letter so "Марина" also catches "Марины/Марине". Short words match exactly.
    private static func nameStems(_ p: Person) -> [(stem: String, prefix: Bool)] {
        guard p.slug != "_self" else { return [] }
        let name = p.displayName.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        return SearchIndex.tokens(name).filter { $0.count >= 3 && Int($0) == nil }.map {
            $0.count > 5 ? (String($0.prefix($0.count - 1)), true) : ($0, false)
        }
    }

    /// Multi-word descriptions of a person: the notes in their display-name parentheses
    /// ("Людмила (бабушка, мама мамы)" → "мама мамы") plus fixed in-law phrasings.
    private static func phrases(_ p: Person) -> [String] {
        var out: [String] = []
        if let open = p.displayName.firstIndex(of: "("), let close = p.displayName.lastIndex(of: ")"), open < close {
            for part in p.displayName[p.displayName.index(after: open)..<close].split(separator: ",") {
                let toks = SearchIndex.tokens(String(part))
                if toks.count >= 2 { out.append(toks.joined(separator: " ")) }
            }
        }
        if relationshipKey(p) == "mother_in_law" {
            out += ["мама жены", "мамы жены", "маме жены", "маму жены", "wife mother", "wifes mother", "mother in law", "мать жены", "матери жены"]
        }
        if relationshipKey(p) == "grandmother" { out += ["мама мамы", "мамы мамы", "маме мамы"] }
        return out
    }

    static func person(chatId: String, chat: ParsedChatFile, people: [Person],
                       docOwner: [String: String], stepOwner: [String: String]) -> String {
        let slugs = Set(people.map(\.slug))
        if chatId.hasPrefix("nextsteps-") {
            let s = String(chatId.dropFirst("nextsteps-".count))
            if slugs.contains(s) { return s }
        }
        var score: [String: Double] = [:]
        for r in chat.references {
            switch r.kind {
            case .person where slugs.contains(r.id): score[r.id, default: 0] += 10
            case .file: if let o = docOwner[r.id] { score[o, default: 0] += 10 }
            case .step: if let o = stepOwner[r.id] { score[o, default: 0] += 10 }
            default: break
            }
        }
        // The generated title ("Father's prostate cancer…") is as telling as the first message.
        var text = " " + SearchIndex.tokens(chat.title + "\n" + chat.userText).joined(separator: " ") + " "
        let firstSet = Set(SearchIndex.tokens(chat.title + " " + chat.firstUserText))
        // Multi-word phrases first ("мама Ани", "wife's mother", "мама мамы"): they name ONE person, so
        // they score for that person and are cut out before single words, or "мама" would also count
        // for the user's mother.
        for p in people where p.slug != "_self" {
            for phrase in phrases(p) {
                let needle = " " + phrase + " "
                var n = 0
                while let r = text.range(of: needle) { n += 1; text.replaceSubrange(r, with: " ") }
                if n > 0 { score[p.slug, default: 0] += Double(n) * 4 }
            }
        }
        let first = firstSet
        let all = text.split(separator: " ").map(String.init)
        for p in people where p.slug != "_self" {
            var stems = nameStems(p)
            if let key = relationshipKey(p), let rs = relationshipStems.first(where: { $0.0 == key })?.1 {
                stems += rs.map { (SearchIndex.normalize($0), true) }
            }
            guard !stems.isEmpty else { continue }
            var hits = 0.0
            for t in all where stems.contains(where: { $0.prefix ? t.hasPrefix($0.stem) : t == $0.stem }) {
                hits += first.contains(t) ? 3 : 1
            }
            if hits > 0 { score[p.slug, default: 0] += hits }
        }
        guard let best = score.max(by: { $0.value < $1.value }), best.value >= 1 else { return "_self" }
        return best.key
    }
}
