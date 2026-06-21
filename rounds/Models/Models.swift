//
//  Models.swift
//  rounds
//
//  Domain model + on-disk vault layout. The directory tree at ~/Rounds is the single
//  source of truth; everything here is plain files Claude Code can read and write.
//

import Foundation

// MARK: - Vault layout

nonisolated struct VaultPaths: Sendable {
    let root: URL

    init(root: URL = VaultPaths.defaultRoot) { self.root = root }

    static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Rounds", isDirectory: true)
    }

    var claudeMd: URL { root.appendingPathComponent("CLAUDE.md") }
    var brainDir: URL { root.appendingPathComponent(".rounds-brain", isDirectory: true) }
    var promptsDir: URL { brainDir.appendingPathComponent("prompts", isDirectory: true) }
    var mcpDir: URL { brainDir.appendingPathComponent("mcp/rounds-sources", isDirectory: true) }
    var mcpIndex: URL { mcpDir.appendingPathComponent("index.mjs") }
    var mcpConfig: URL { brainDir.appendingPathComponent("mcp.json") }
    var brainSettings: URL { brainDir.appendingPathComponent("settings.json") }
    var systemCompact: URL { brainDir.appendingPathComponent("system_compact.txt") }
    var criticalValues: URL { brainDir.appendingPathComponent("critical-values.json") }
    var brainVersion: URL { brainDir.appendingPathComponent("brain-version.json") }

    var dotRounds: URL { root.appendingPathComponent(".rounds", isDirectory: true) }
    var indexJson: URL { dotRounds.appendingPathComponent("index.json") }
    var settingsJson: URL { dotRounds.appendingPathComponent("settings.json") }

    var peopleDir: URL { root.appendingPathComponent("people", isDirectory: true) }
    var hypothesesDir: URL { root.appendingPathComponent("hypotheses", isDirectory: true) }
    var chatsDir: URL { root.appendingPathComponent("chats", isDirectory: true) }
    var inboxDir: URL { root.appendingPathComponent("inbox", isDirectory: true) }

    func personDir(_ slug: String) -> URL { peopleDir.appendingPathComponent(slug, isDirectory: true) }
    func personDocs(_ slug: String) -> URL { personDir(slug).appendingPathComponent("documents", isDirectory: true) }
    func complaintsDir(_ slug: String) -> URL { personDir(slug).appendingPathComponent("complaints", isDirectory: true) }

    func ensureScaffold() throws {
        let fm = FileManager.default
        for dir in [root, brainDir, promptsDir, mcpDir, dotRounds, peopleDir, hypothesesDir, chatsDir, inboxDir,
                    personDir("_self"), personDocs("_self")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

// MARK: - People

nonisolated struct Person: Codable, Identifiable, Sendable, Hashable {
    var slug: String
    var displayName: String
    var relationship: String?   // "self", "mother", "father", ...
    var id: String { slug }

    static let selfPlaceholder = Person(slug: "_self", displayName: "You", relationship: "self")
}

// MARK: - Documents

nonisolated struct Marker: Codable, Sendable, Hashable {
    var name: String
    var value: String
    var unit: String?
    var refLow: Double?
    var refHigh: Double?
    var flag: String?          // "low" | "high" | "normal" | "critical"
}

nonisolated struct MedDocument: Codable, Identifiable, Sendable, Hashable {
    var id: String
    var personId: String
    var docType: String
    var title: String?         // human-readable, specific (e.g. "Cardiology consult")
    var analysisCategory: String?
    var testDate: String?      // ISO yyyy-MM-dd (sample date)
    var sourceLab: String?
    var fileName: String
    var relativePath: String   // relative to vault root
    var isImaging: Bool
    var hasTextReport: Bool
    var conclusionsBlocked: Bool
    var summary: String?
    var markers: [Marker]

    var year: String { testDate.flatMap { String($0.prefix(4)) } ?? "Undated" }
    var displayName: String { title ?? docType.replacingOccurrences(of: "_", with: " ").capitalized }
}

// MARK: - Hypotheses

nonisolated enum HypothesisStatus: String, Codable, Sendable { case proposed, active, snoozed, done, dismissed, superseded }
nonisolated enum HypothesisKind: String, Codable, Sendable {
    case getMoreData = "get-more-data", trySomething = "try-something", seeSpecialist = "see-specialist", watch
    case askUser = "ask-user"     // a patient-history question the user answers in-app
    case needsExam = "needs-exam" // the decisive next datum is a physical sign only a clinician can get
}

/// A symptom-first encounter the user opened (no document required). Its interview questions and
/// next steps are Hypotheses linked back via `complaintId`. Persisted under people/<slug>/complaints/.
nonisolated struct Complaint: Codable, Identifiable, Sendable, Hashable {
    var id: String
    var personId: String
    var title: String        // short symptom label
    var summary: String      // the user's original words
    var status: String       // open | resolved
    var openedAt: String     // ISO date
}

nonisolated struct Hypothesis: Codable, Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var whyNow: String
    var personId: String
    var priority: String       // high | medium | low
    var kind: String
    var status: String
    var sourceCount: Int
    var topTier: String?
    var sessionId: String?
    var body: String?
    var complaintId: String?      // set when this step belongs to a symptom-first Complaint
    // ask-user (question) steps:
    var askPlaceholder: String?   // hint text for the answer field
    var answer: String?           // the user's recorded answer (nil until answered)
    var answeredAt: String?       // ISO date the user answered
    var isQuestion: Bool { kind == HypothesisKind.askUser.rawValue }
}

// MARK: - Sources (right panel)

nonisolated struct Source: Codable, Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var url: String?
    var type: String?
    var trustTier: String      // PRIMARY, T0..T6
    var year: Int?
    var journal: String?
    var citedBy: Int?
    var whyTrusted: String?
}

// MARK: - Chat

nonisolated enum ChatRole: String, Codable, Sendable { case user, assistant, system }

nonisolated struct ChatMessage: Codable, Identifiable, Sendable, Hashable {
    var id: String
    var role: ChatRole
    var text: String
    var timestamp: Date
    var references: [Reference] = []   // @-mentions attached to a user message (shown as chips)
    var hypotheses: [Hypothesis] = []  // next steps this assistant turn created/changed (inline cards)
}

nonisolated struct ChatSummary: Codable, Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var hypothesisId: String?
    var updatedAt: Date
    var sessionId: String?
}

// MARK: - Question protocol (confirm-to-continue)

nonisolated struct QuestionOption: Codable, Identifiable, Sendable, Hashable {
    var id: String
    var label: String
}

nonisolated struct RoundsQuestion: Codable, Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var context: String?
    var options: [QuestionOption]
    var allowFreeform: Bool
    var requiresContinue: Bool
    var multi: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, context, options
        case allowFreeform = "allow_freeform"
        case requiresContinue = "requires_continue"
        case multi
    }
}

// MARK: - Batch intake plan (rounds.intake_plan)

/// One file's classification from a batch analysis (`rounds.intake_plan.files[]`).
nonisolated struct PlanFile: Sendable, Hashable {
    var index: Int
    var slug: String          // person_guess.slug ("_self", a roster slug, or "new")
    var confidence: String    // high | medium | low
    var title: String
    var isImaging: Bool
}

/// One grouped question covering many files (`rounds.intake_plan.questions[]`).
nonisolated struct PlanQuestion: Sendable, Hashable {
    var id: String
    var title: String
    var context: String?
    var options: [QuestionOption]
    var fileIndices: [Int]
    var allowFreeform: Bool
    var requiresContinue: Bool
    var asksName: Bool
}

/// An @-mention reference the user inserted in the input (file, person, step, or chat).
nonisolated struct Reference: Identifiable, Hashable, Sendable, Codable {
    enum Kind: String, Sendable, Codable { case file, person, step, chat }
    var kind: Kind
    var id: String      // relativePath / slug / hypothesis id / chat id
    var label: String
    var iconName: String {
        switch kind { case .file: "doc.text"; case .person: "person"; case .step: "checklist"; case .chat: "bubble.left" }
    }
}

/// A reversible change the chat brain asked the app to make to an existing next-step card
/// (chat is read-only, so the app performs the write). From a `rounds.step_action` block.
nonisolated struct StepAction: Codable, Sendable, Hashable {
    var id: String
    var action: String   // relanguage | done | dismiss | snooze | activate | answer
    var answer: String?  // for action == "answer": the user's verbatim history answer
}

nonisolated struct RoundsAlert: Codable, Sendable, Hashable {
    var severity: String
    var marker: String?
    var value: String?
    var basis: String?
    var message: String

    init(severity: String, marker: String? = nil, value: String? = nil, basis: String? = nil, message: String) {
        self.severity = severity; self.marker = marker; self.value = value; self.basis = basis; self.message = message
    }

    // SAFETY-CRITICAL decode tolerance. The urgent banner is the app's last-line escalation, so a
    // model wording drift must NEVER silently drop it. The brain is told to emit `severity`, but it
    // sometimes writes the natural-language alias `level`; `message` should always be present but we
    // never want a missing key to nuke the whole alert. Accept either key, default severity to
    // "urgent", and tolerate a numeric `value`.
    private enum K: String, CodingKey { case severity, level, marker, value, basis, message }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        severity = (try? c.decode(String.self, forKey: .severity))
            ?? (try? c.decode(String.self, forKey: .level)) ?? "urgent"
        marker = try? c.decodeIfPresent(String.self, forKey: .marker)
        if let s = try? c.decodeIfPresent(String.self, forKey: .value) { value = s }
        else if let n = try? c.decodeIfPresent(Double.self, forKey: .value) { value = String(n) }
        else { value = nil }
        basis = try? c.decodeIfPresent(String.self, forKey: .basis)
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(severity, forKey: .severity)
        try c.encodeIfPresent(marker, forKey: .marker)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(basis, forKey: .basis)
        try c.encode(message, forKey: .message)
    }
}
