import Foundation

/// Runs the speech and cleanup servers that ship inside LocalFlow.app as child processes.
/// A server is started only when LocalFlow is configured to use the bundled address and nothing
/// already answers there, so a setup with its own whisper-server or Ollama is left alone.
@MainActor
final class BundledServers {
    static let whisperPort = 8178
    static let cleanupPort = 8179
    static let cleanupBaseURL = "http://127.0.0.1:\(cleanupPort)/v1"

    private var processes: [String: Process] = [:]

    static func helper(_ name: String) -> URL? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let url = dir.appendingPathComponent(name)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var isBundled: Bool { helper("whisper-server") != nil && helper("llama-server") != nil }

    static func usesBundledWhisper(_ settings: AppSettings) -> Bool {
        settings.whisperServerURL == "http://127.0.0.1:\(whisperPort)/inference"
    }

    static func usesBundledCleanup(_ settings: AppSettings, environment: [String: String]) -> Bool {
        guard settings.llm.enabled else { return false }
        let base = environment["LLM_BASE_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? settings.llm.baseURL
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == cleanupBaseURL
    }

    /// Models the bundled servers will need, given the settings.
    static func neededModels(_ settings: AppSettings, environment: [String: String]) -> [ModelFile] {
        guard isBundled else { return [] }
        var models: [ModelFile] = []
        if usesBundledWhisper(settings) { models.append(.speech) }
        if usesBundledCleanup(settings, environment: environment) { models.append(.cleanup) }
        return models
    }

    func startNeeded(settings: AppSettings, environment: [String: String]) async {
        if Self.usesBundledWhisper(settings), ModelStore.isInstalled(.speech) {
            await start("whisper-server", port: Self.whisperPort, arguments: [
                "-m", ModelStore.url(for: .speech).path,
                "--host", "127.0.0.1", "--port", String(Self.whisperPort),
                "-l", "en", "-nt", "-nf"
            ])
        }
        if Self.usesBundledCleanup(settings, environment: environment), ModelStore.isInstalled(.cleanup) {
            await start("llama-server", port: Self.cleanupPort, arguments: [
                "-m", ModelStore.url(for: .cleanup).path,
                "--host", "127.0.0.1", "--port", String(Self.cleanupPort),
                "-c", "4096", "-np", "1", "-ngl", "99", "--no-webui",
                "--alias", "qwen2.5-7b-instruct"
            ])
        }
    }

    func stopAll() {
        for (name, process) in processes where process.isRunning {
            DebugLog.write("stopping bundled \(name)")
            process.terminate()
        }
        processes.removeAll()
    }

    private func start(_ name: String, port: Int, arguments: [String]) async {
        if let running = processes[name], running.isRunning { return }
        if await Self.answers(port: port) {
            DebugLog.write("port \(port) already answers; not starting bundled \(name)")
            return
        }
        guard let executable = Self.helper(name) else { return }
        // A downloaded app's files carry the quarantine flag; once the user has opened the app,
        // clear it on our own servers so macOS does not block them as separate downloads.
        removexattr(executable.path, "com.apple.quarantine", 0)
        let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/LocalFlow/\(name).log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { p in
            DebugLog.write("bundled \(name) exited status=\(p.terminationStatus)")
        }
        do {
            try process.run()
            processes[name] = process
            DebugLog.write("started bundled \(name) pid=\(process.processIdentifier)")
        } catch {
            DebugLog.write("could not start bundled \(name): \(error.localizedDescription)")
        }
    }

    /// True when anything answers HTTP on the port within half a second.
    static func answers(port: Int) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 0.5
        return (try? await URLSession.shared.data(for: request)) != nil
    }
}
