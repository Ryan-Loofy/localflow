import AppKit

/// "Check for Updates…" in the menu. LocalFlow never checks on its own: this asks GitHub
/// for the latest release only when someone clicks it, and sends nothing about the Mac.
enum UpdateChecker {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/Ryan-Loofy/localflow-app/releases/latest")!
    static let downloadPage = URL(string: "https://localflowvoice.com/download.html")!

    /// True when `latest` (a tag such as "v0.2.3") is a newer version than `current` ("0.2.2").
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(latest), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @MainActor
    static func check() {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        Task {
            let alert = NSAlert()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    throw URLError(.badServerResponse)
                }
                let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if isNewer(latest, than: current) {
                    alert.messageText = "LocalFlow \(latest) is available"
                    alert.informativeText = "You have \(current). Download the new version, quit LocalFlow, and drag the new one into Applications to replace it."
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Later")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(downloadPage) }
                    return
                }
                alert.messageText = "LocalFlow is up to date"
                alert.informativeText = "You have the latest version, \(current)."
            } catch {
                DebugLog.write("update check failed: \(error.localizedDescription)")
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = "Check your internet connection, or see localflowvoice.com for the latest version. You have \(current)."
            }
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
