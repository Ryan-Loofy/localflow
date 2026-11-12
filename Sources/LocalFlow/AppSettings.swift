import Foundation

struct AppSettings: Codable, Equatable {
    var enabled = true
    var hotkey = HotkeySettings()
    var doubleTapWindowMilliseconds = 350
    var maxRecordingSeconds = 300
    var restorePreviousClipboard = false
    var clipboardRestoreDelayMilliseconds = 400
    var whisperExecutable = "~/Library/Application Support/LocalFlow/whisper.cpp/build/bin/whisper-cli"
    var whisperModel = "~/Library/Application Support/LocalFlow/whisper.cpp/models/ggml-small.en.bin"
    var whisperLanguage = "en"
    var whisperServerURL = "http://127.0.0.1:8178/inference"
    var tapToToggle = true
    var skipCleanupWhenClean = true
    /// Caps Lock becomes F13 while LocalFlow runs, so it can be the dictation key.
    var mapCapsLock = false
    var llm = LLMCleanupSettings()

    var doubleTapWindow: TimeInterval {
        TimeInterval(max(150, doubleTapWindowMilliseconds)) / 1_000
    }

    var maximumRecordingDuration: TimeInterval {
        TimeInterval(min(max(1, maxRecordingSeconds), 300))
    }
}

extension AppSettings {
    // Missing keys fall back to defaults, so older settings files keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        hotkey = try c.decodeIfPresent(HotkeySettings.self, forKey: .hotkey) ?? d.hotkey
        doubleTapWindowMilliseconds = try c.decodeIfPresent(Int.self, forKey: .doubleTapWindowMilliseconds) ?? d.doubleTapWindowMilliseconds
        maxRecordingSeconds = try c.decodeIfPresent(Int.self, forKey: .maxRecordingSeconds) ?? d.maxRecordingSeconds
        restorePreviousClipboard = try c.decodeIfPresent(Bool.self, forKey: .restorePreviousClipboard) ?? d.restorePreviousClipboard
        clipboardRestoreDelayMilliseconds = try c.decodeIfPresent(Int.self, forKey: .clipboardRestoreDelayMilliseconds) ?? d.clipboardRestoreDelayMilliseconds
        whisperExecutable = try c.decodeIfPresent(String.self, forKey: .whisperExecutable) ?? d.whisperExecutable
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? d.whisperModel
        whisperLanguage = try c.decodeIfPresent(String.self, forKey: .whisperLanguage) ?? d.whisperLanguage
        whisperServerURL = try c.decodeIfPresent(String.self, forKey: .whisperServerURL) ?? d.whisperServerURL
        tapToToggle = try c.decodeIfPresent(Bool.self, forKey: .tapToToggle) ?? d.tapToToggle
        skipCleanupWhenClean = try c.decodeIfPresent(Bool.self, forKey: .skipCleanupWhenClean) ?? d.skipCleanupWhenClean
        mapCapsLock = try c.decodeIfPresent(Bool.self, forKey: .mapCapsLock) ?? d.mapCapsLock
        llm = try c.decodeIfPresent(LLMCleanupSettings.self, forKey: .llm) ?? d.llm
    }
}

struct HotkeySettings: Codable, Equatable {
    var key = "fn"
    var modifiers: [String] = []
}

struct LLMCleanupSettings: Codable, Equatable {
    var enabled = true
    var fallbackToRawTranscript = true
    /// The cleanup server bundled in LocalFlow.app. Point this at Ollama or any OpenAI-compatible endpoint to use another.
    var baseURL = "http://127.0.0.1:8179/v1"
    var model = "qwen2.5-7b-instruct"
    var apiKeyEnvironmentVariable = "LLM_API_KEY"
}

extension LLMCleanupSettings {
    // Like AppSettings: a partial "llm" section keeps the defaults for what it leaves out.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LLMCleanupSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        fallbackToRawTranscript = try c.decodeIfPresent(Bool.self, forKey: .fallbackToRawTranscript) ?? d.fallbackToRawTranscript
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        apiKeyEnvironmentVariable = try c.decodeIfPresent(String.self, forKey: .apiKeyEnvironmentVariable) ?? d.apiKeyEnvironmentVariable
    }
}

final class ConfigStore {
    private let fileManager: FileManager
    let directoryURL: URL
    let settingsURL: URL
    let environmentURL: URL

    init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        directoryURL = base.appendingPathComponent("LocalFlow", isDirectory: true)
        settingsURL = directoryURL.appendingPathComponent("settings.json")
        environmentURL = directoryURL.appendingPathComponent(".env")
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: settingsURL.path) {
            try save(AppSettings())
        }
        if !fileManager.fileExists(atPath: environmentURL.path) {
            let starter = """
            # Leave these empty to use the cleanup model bundled with LocalFlow.
            # To use Ollama instead: LLM_BASE_URL=http://127.0.0.1:11434/v1 and LLM_MODEL=qwen2.5:7b
            LLM_API_KEY=
            LLM_BASE_URL=
            LLM_MODEL=
            """
            try starter.write(to: environmentURL, atomically: true, encoding: .utf8)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: environmentURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    func load() throws -> AppSettings {
        let data = try Data(contentsOf: settingsURL)
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }

    func save(_ settings: AppSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    func loadEnvironment() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: environmentURL.path) else { return [:] }
        return EnvFile.parse(try String(contentsOf: environmentURL, encoding: .utf8))
    }
}

enum EnvFile {
    static func parse(_ source: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in source.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}

enum PathResolver {
    static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}
