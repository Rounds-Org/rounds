//
//  UpdateService.swift
//  rounds
//
//  The one (optional) network touch that isn't a medical query: a poll of a small, static
//  version manifest so the app can show an "update available" banner. It carries only
//  version strings and a download link — never any health data.
//
//  Manifest shape (hosted as static JSON, e.g. on GitHub Releases):
//    { "latestVersion": "1.1.0", "minSupported": "1.0.0",
//      "downloadURL": "https://…/Rounds-1.1.0.dmg", "notes": "What changed" }
//

import Foundation

nonisolated struct UpdateInfo: Sendable, Equatable {
    var latestVersion: String
    var downloadURL: URL
    var notes: String
    var mandatory: Bool
}

nonisolated enum UpdateService {

    /// Where the static manifest lives (committed to the repo; served raw from GitHub).
    static let manifestURL = URL(string: "https://raw.githubusercontent.com/Rounds-Org/rounds/main/appcast.json")!

    static func check(currentVersion: String) async -> UpdateInfo? {
        // A local override lets us test the banner without a live endpoint.
        let override = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Rounds/.rounds/update-manifest.json")
        let data: Data?
        if let d = try? Data(contentsOf: override) {
            data = d
        } else {
            var req = URLRequest(url: manifestURL)
            req.timeoutInterval = 6
            data = try? await URLSession.shared.data(for: req).0
        }
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return evaluate(manifest: obj, current: currentVersion)
    }

    /// Pure decision function (unit-testable): is the advertised version newer than ours?
    static func evaluate(manifest: [String: Any], current: String) -> UpdateInfo? {
        guard let latest = manifest["latestVersion"] as? String,
              let urlStr = manifest["downloadURL"] as? String,
              let url = URL(string: urlStr),
              isNewer(latest, than: current)
        else { return nil }
        let minSupported = manifest["minSupported"] as? String ?? "0.0.0"
        let mandatory = isNewer(minSupported, than: current)
        return UpdateInfo(latestVersion: latest, downloadURL: url,
                          notes: manifest["notes"] as? String ?? "", mandatory: mandatory)
    }

    /// Semantic-version compare: returns true if `a` > `b`.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func parts(_ v: String) -> [Int] {
        v.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? 0 }
    }

    static var currentAppVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}
