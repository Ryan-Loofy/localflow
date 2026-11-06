import Foundation

/// Diagnostic lines in ~/Library/Logs/LocalFlow/localflow.log. Never typed characters:
/// only hotkey-related key codes, counts, permission state and errors.
enum DebugLog {
    private static let queue = DispatchQueue(label: "LocalFlow.DebugLog")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/LocalFlow", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("localflow.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
