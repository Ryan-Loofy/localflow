import Foundation

/// One line per dictation in ~/Library/Logs/LocalFlow/timing.log: milliseconds per step
/// from the moment recording stopped. Never the transcript itself.
enum TimingLog {
    struct Entry {
        private let start = Date()
        private var last = Date()
        private(set) var steps: [(String, Int)] = []

        mutating func mark(_ name: String) {
            let now = Date()
            steps.append((name, Int(now.timeIntervalSince(last) * 1_000)))
            last = now
        }

        var totalMilliseconds: Int { Int(last.timeIntervalSince(start) * 1_000) }
    }

    static func write(_ entry: Entry, words: Int) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LocalFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("timing.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let steps = entry.steps.map { "\($0.0)=\($0.1)ms" }.joined(separator: " ")
        let line = "\(stamp) total=\(entry.totalMilliseconds)ms words=\(words) \(steps)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
