import Darwin
import Foundation

enum WhisperError: LocalizedError {
    case executableMissing(String)
    case modelMissing(String)
    case processFailed(Int32, String)
    case missingOutput
    case cancelled

    var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            return "whisper-cli was not found or is not executable at \(path)."
        case .modelMissing(let path):
            return "The whisper.cpp model was not found at \(path)."
        case .processFailed(let status, let detail):
            return "whisper-cli exited with status \(status): \(detail)"
        case .missingOutput:
            return "whisper-cli completed without producing a transcript."
        case .cancelled:
            return "Transcription was cancelled."
        }
    }
}

final class WhisperTranscriber {
    private let lock = NSLock()
    private var activeProcess: Process?

    /// Returns the transcript and which engine produced it ("server" or "cli").
    /// The resident whisper-server keeps the model loaded; the CLI is the fallback when it is down.
    func transcribe(audioURL: URL, settings: AppSettings) async throws -> (String, String) {
        if let serverURL = URL(string: settings.whisperServerURL), !settings.whisperServerURL.isEmpty {
            do {
                return (try await transcribeWithServer(audioURL: audioURL, serverURL: serverURL), "server")
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                DebugLog.write("whisper-server unavailable, using whisper-cli: \(error.localizedDescription)")
            }
        }
        return (try await transcribeWithCLI(audioURL: audioURL, settings: settings), "cli")
    }

    /// Fired when recording starts: half a second of silence pages the model back in.
    func warmUp(settings: AppSettings) {
        guard let serverURL = URL(string: settings.whisperServerURL), !settings.whisperServerURL.isEmpty else { return }
        let silenceURL = FileManager.default.temporaryDirectory.appendingPathComponent("localflow-warmup.wav")
        if !FileManager.default.fileExists(atPath: silenceURL.path) {
            try? Self.silentWAV(seconds: 0.5).write(to: silenceURL)
        }
        Task.detached(priority: .utility) { [weak self] in
            _ = try? await self?.transcribeWithServer(audioURL: silenceURL, serverURL: serverURL)
        }
    }

    static func silentWAV(seconds: Double) -> Data {
        let sampleRate: UInt32 = 16_000
        let dataSize = UInt32(Double(sampleRate) * seconds) * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(Data("RIFF".utf8)); u32(36 + dataSize); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(dataSize); d.append(Data(count: Int(dataSize)))
        return d
    }

    private func transcribeWithServer(audioURL: URL, serverURL: URL) async throws -> String {
        let boundary = "LocalFlow-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("response_format", "text")
        field("temperature", "0.0")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: audioURL))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WhisperError.missingOutput
        }
        let transcript = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw WhisperError.missingOutput }
        return transcript
    }

    private func transcribeWithCLI(audioURL: URL, settings: AppSettings) async throws -> String {
        let executablePath = PathResolver.expand(settings.whisperExecutable)
        let modelPath = PathResolver.expand(settings.whisperModel)
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw WhisperError.executableMissing(executablePath)
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperError.modelMissing(modelPath)
        }

        let outputPrefix = audioURL.deletingPathExtension().appendingPathExtension("transcript")
        let outputURL = URL(fileURLWithPath: outputPrefix.path + ".txt")
        let logURL = audioURL.deletingLastPathComponent().appendingPathComponent("whisper.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--model", modelPath,
            "--file", audioURL.path,
            "--language", settings.whisperLanguage,
            "--no-timestamps",
            "--output-txt",
            "--output-file", outputPrefix.path,
            "--no-prints"
        ]
        let logHandle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle

        lock.withLock { activeProcess = process }

        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try process.run()
                } catch {
                    try? logHandle.close()
                    self?.clear(process)
                    throw error
                }
                process.waitUntilExit()
                try? logHandle.close()
                self?.clear(process)

                if Task.isCancelled { throw WhisperError.cancelled }
                guard process.terminationStatus == 0 else {
                    let detail = (try? String(contentsOf: logURL, encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "no diagnostics"
                    throw WhisperError.processFailed(process.terminationStatus, detail)
                }
                guard FileManager.default.fileExists(atPath: outputURL.path) else {
                    throw WhisperError.missingOutput
                }
                let transcript = try String(contentsOf: outputURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !transcript.isEmpty else { throw WhisperError.missingOutput }
                return transcript
            }.value
        }, onCancel: { [weak self] in
            self?.cancel()
        })
    }

    func cancel() {
        let process = lock.withLock { activeProcess }
        guard let process, process.isRunning else { return }
        process.terminate()

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self, weak process] in
            guard let self, let process, process.isRunning else { return }
            let isStillActive = self.lock.withLock { self.activeProcess === process }
            if isStillActive {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private func clear(_ process: Process) {
        lock.withLock {
            if activeProcess === process { activeProcess = nil }
        }
    }
}
