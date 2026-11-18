import Foundation

/// The website in the front browser tab, so a site such as LinkedIn can have its own writing style.
/// macOS asks once per browser before LocalFlow may read it (Automation); until then this returns nil.
enum BrowserTab {
    /// AppleScript that returns the front tab's URL, by browser bundle identifier.
    static let scripts: [String: String] = [
        "company.thebrowser.Browser": chromium("company.thebrowser.Browser"),
        "com.google.Chrome": chromium("com.google.Chrome"),
        "com.brave.Browser": chromium("com.brave.Browser"),
        "com.microsoft.edgemac": chromium("com.microsoft.edgemac"),
        "com.apple.Safari": "tell application id \"com.apple.Safari\" to get URL of front document"
    ]

    private static func chromium(_ id: String) -> String {
        "tell application id \"\(id)\" to get URL of active tab of front window"
    }

    static func host(forApp bundleID: String?) -> String? {
        guard let bundleID, let source = scripts[bundleID], let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            DebugLog.write("browser tab not readable (\(bundleID)): \(error[NSAppleScript.errorNumber] ?? "?")")
            return nil
        }
        return result.stringValue.flatMap { URL(string: $0)?.host }
    }
}
