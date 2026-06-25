//
//  AnalyticsService.swift
//  rounds
//
//  Privacy-first product analytics. The ONLY thing that ever leaves here is a small
//  allowlist of event names with enum/numeric properties — never a document, a name, a
//  health value, or any free-form string. Everything passes one `sanitize()` chokepoint,
//  and the user can opt out. No content, ever.
//
//  Transport: Amplitude HTTP V2 (api2.amplitude.com/2/httpapi). With an empty apiKey the
//  service is a no-op (still runs the allowlist so it stays testable). Device id is a
//  random local UUID, never tied to identity.
//

import Foundation

nonisolated enum AnalyticsEvent: Sendable {
    case appOpened
    case toolCheck(tool: String, ok: Bool)        // tool ∈ {claude, node}
    case documentAdded(isImaging: Bool)           // no name/type/content
    case questionShown
    case questionAnswered(confirmed: Bool)
    case hypothesesGenerated(count: Int)
    case chatStarted
    case ranSearch(sourceCount: Int, topTier: String)
    case modelChanged(model: String)              // opus/sonnet/haiku
    case updateBannerShown
    case updateBannerClicked

    var name: String {
        switch self {
        case .appOpened: "app_opened"
        case .toolCheck: "tool_check"
        case .documentAdded: "document_added"
        case .questionShown: "question_shown"
        case .questionAnswered: "question_answered"
        case .hypothesesGenerated: "hypotheses_generated"
        case .chatStarted: "chat_started"
        case .ranSearch: "ran_search"
        case .modelChanged: "model_changed"
        case .updateBannerShown: "update_banner_shown"
        case .updateBannerClicked: "update_banner_clicked"
        }
    }

    /// Raw (pre-sanitize) properties — only enums and numbers by construction.
    var rawProps: [String: Any] {
        switch self {
        case .toolCheck(let tool, let ok): ["tool": tool, "ok": ok]
        case .documentAdded(let isImaging): ["is_imaging": isImaging]
        case .questionAnswered(let confirmed): ["confirmed": confirmed]
        case .hypothesesGenerated(let count): ["count": count]
        case .ranSearch(let n, let tier): ["source_count": n, "top_tier": tier]
        case .modelChanged(let model): ["model": model]
        default: [:]
        }
    }
}

nonisolated enum Analytics {

    /// Build-time key, injected into Info.plist (`AmplitudeAPIKey`) from the AMPLITUDE_API_KEY
    /// build setting — never committed to the public repo. EMPTY = analytics fully disabled (no
    /// network); the allowlist below stays published so the privacy guarantee is auditable.
    static let apiKey: String = {
        let v = (Bundle.main.object(forInfoDictionaryKey: "AmplitudeAPIKey") as? String) ?? ""
        return v.contains("$(") ? "" : v.trimmingCharacters(in: .whitespacesAndNewlines)   // unexpanded placeholder → disabled
    }()
    static let endpoint = URL(string: "https://api2.amplitude.com/2/httpapi")!

    private static let allowedEvents: Set<String> = [
        "app_opened", "tool_check", "document_added", "question_shown", "question_answered",
        "hypotheses_generated", "chat_started", "ran_search", "model_changed",
        "update_banner_shown", "update_banner_clicked"
    ]
    private static let allowedPropKeys: Set<String> = [
        "tool", "ok", "is_imaging", "confirmed", "count", "source_count", "top_tier", "model"
    ]
    // String props must match this enum-ish shape — no spaces, no content.
    private static let enumish = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.-]{1,24}$")

    nonisolated(unsafe) static var optedOut = false
    nonisolated(unsafe) static var deviceId = "anon"

    static func configure(optedOut: Bool, deviceId: String) {
        self.optedOut = optedOut
        self.deviceId = deviceId.isEmpty ? "anon" : deviceId
    }

    static func track(_ event: AnalyticsEvent) {
        guard !optedOut else { return }
        guard let safe = sanitize(name: event.name, props: event.rawProps) else { return }
        send(name: safe.0, props: safe.1)
    }

    /// THE chokepoint. Drops unknown events, unknown keys, and any value that isn't a
    /// number, a bool, or an enum-ish short token. This is what guarantees no content leaks.
    static func sanitize(name: String, props: [String: Any]) -> (String, [String: Any])? {
        guard allowedEvents.contains(name) else { return nil }
        var out: [String: Any] = [:]
        for (k, v) in props where allowedPropKeys.contains(k) {
            if let i = v as? Int { out[k] = i }
            else if let b = v as? Bool { out[k] = b }
            else if let d = v as? Double { out[k] = d }
            else if let s = v as? String,
                    enumish.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil {
                out[k] = s
            }
            // anything else (free strings, nested objects) is silently dropped
        }
        return (name, out)
    }

    private static func send(name: String, props: [String: Any]) {
        guard !apiKey.isEmpty else { return }   // disabled build → no network
        let event: [String: Any] = [
            "user_id": NSNull(), "device_id": deviceId,
            "event_type": name, "event_properties": props,
            "platform": "macOS", "app_version": UpdateService.currentAppVersion
        ]
        let body: [String: Any] = ["api_key": apiKey, "events": [event]]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        Task.detached { _ = try? await URLSession.shared.data(for: req) }
    }

    static func loadOrCreateDeviceId(_ vault: VaultPaths) -> String {
        let url = vault.dotRounds.appendingPathComponent("analytics-id")
        if let id = try? String(contentsOf: url, encoding: .utf8), !id.isEmpty {
            return id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let id = UUID().uuidString
        try? FileManager.default.createDirectory(at: vault.dotRounds, withIntermediateDirectories: true)
        try? id.data(using: .utf8)?.write(to: url)
        return id
    }
}
