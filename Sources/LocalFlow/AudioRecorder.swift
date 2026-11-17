import AVFoundation
import Foundation

enum AudioRecorderError: LocalizedError {
    case microphonePermissionDenied
    case invalidInputFormat
    case notRecording
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is not granted."
        case .invalidInputFormat:
            return "The selected microphone did not provide a usable audio format."
        case .notRecording:
            return "No recording is active."
        case .conversionFailed(let detail):
            return "Could not convert the recording for whisper.cpp: \(detail)"
        }
    }
}

final class AudioRecorder {
    // Recreated for every recording: after a mic change (a headset connecting, a device
    // switch) a long-lived engine keeps a stale input and never records again.
    private var engine = AVAudioEngine()
    private var configurationObserver: NSObjectProtocol?
    private var sourceFile: AVAudioFile?
    private var sessionDirectory: URL?
    /// One file per engine run. A Bluetooth headset switches to its call mode when the mic opens,
    /// which reconfigures the engine and sometimes stops it mid-recording (2026-11-17: two
    /// dictations lost). The engine is then restarted into a new segment, and every segment is
    /// transcribed together.
    private var segments: [URL] = []
    private var restarts = 0
    private static let maximumRestarts = 5

    var isRecording: Bool { sessionDirectory != nil }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func start() throws {
        cancel()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessionDirectory = directory
        restarts = 0
        do {
            try startSegment(in: directory)
        } catch {
            DebugLog.write("recording failed to start: \(error.localizedDescription)")
            discardFiles()
            throw error
        }
    }

    /// Starts a fresh engine writing to the next segment file.
    private func startSegment(in directory: URL) throws {
        stopEngine()
        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }

        let url = directory.appendingPathComponent("capture-\(segments.count).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        sourceFile = file
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak file] buffer, _ in
            try? file?.write(from: buffer)
        }
        observeConfigurationChanges(of: engine)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            sourceFile = nil
            throw error
        }
        segments.append(url)
        DebugLog.write("recording started: \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, segment \(segments.count)")
    }

    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self, weak engine] _ in
            DebugLog.write("audio engine configuration changed; running=\(engine?.isRunning ?? false)")
            self?.resumeIfStopped(engine)
            // The engine can stop a moment after the notification, so look once more.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.resumeIfStopped(engine) }
        }
    }

    private func resumeIfStopped(_ changed: AVAudioEngine?) {
        guard let changed, changed === engine, !engine.isRunning, let directory = sessionDirectory else { return }
        guard restarts < Self.maximumRestarts else {
            DebugLog.write("audio engine stopped again; keeping what was recorded")
            return
        }
        restarts += 1
        do {
            try startSegment(in: directory)
            DebugLog.write("audio engine restarted after the system stopped it (\(restarts))")
        } catch {
            DebugLog.write("audio engine restart failed: \(error.localizedDescription); keeping what was recorded")
        }
    }

    private func stopEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if sourceFile != nil { engine.inputNode.removeTap(onBus: 0) }
        if engine.isRunning { engine.stop() }
        sourceFile = nil
    }

    /// Converts everything recorded, including what was captured before the system stopped the engine.
    func stopAndConvert() throws -> URL {
        guard let directory = sessionDirectory, !segments.isEmpty else {
            DebugLog.write("stop with no recording: engineRunning=\(engine.isRunning) haveFiles=\(sessionDirectory != nil)")
            throw AudioRecorderError.notRecording
        }
        if !engine.isRunning {
            DebugLog.write("stop after the system stopped the engine; transcribing what was recorded")
        }
        stopEngine()

        let outputURL = directory.appendingPathComponent("capture-16khz.wav")
        try Self.convertToWhisperWAV(sourceURLs: segments, outputURL: outputURL)
        for segment in segments { try? FileManager.default.removeItem(at: segment) }
        segments = []
        return outputURL
    }

    func cancel() {
        stopEngine()
        discardFiles()
    }

    func discardFiles() {
        if let sessionDirectory {
            try? FileManager.default.removeItem(at: sessionDirectory)
        }
        sessionDirectory = nil
        segments = []
    }

    static func convertToWhisperWAV(sourceURL: URL, outputURL: URL) throws {
        try convertToWhisperWAV(sourceURLs: [sourceURL], outputURL: outputURL)
    }

    /// Appends each source, in order, to one 16 kHz mono WAV. Segments may differ in format,
    /// since a restarted engine can come back at another sample rate.
    static func convertToWhisperWAV(sourceURLs: [URL], outputURL: URL) throws {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioRecorderError.conversionFailed("unsupported output format")
        }
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        for sourceURL in sourceURLs {
            try append(sourceURL: sourceURL, to: outputFile, outputFormat: outputFormat)
        }
    }

    private static func append(sourceURL: URL, to outputFile: AVAudioFile, outputFormat: AVAudioFormat) throws {
        let inputFile = try AVAudioFile(forReading: sourceURL)
        let inputFormat = inputFile.processingFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioRecorderError.conversionFailed("unsupported microphone format")
        }
        let inputCapacity: AVAudioFrameCount = 8_192
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity) else {
            throw AudioRecorderError.conversionFailed("could not allocate an input buffer")
        }

        while inputFile.framePosition < inputFile.length {
            try inputFile.read(into: inputBuffer, frameCount: inputCapacity)
            if inputBuffer.frameLength == 0 { break }

            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 32
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                throw AudioRecorderError.conversionFailed("could not allocate an output buffer")
            }

            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, statusPointer in
                if suppliedInput {
                    statusPointer.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                statusPointer.pointee = .haveData
                return inputBuffer
            }

            if status == .error {
                throw AudioRecorderError.conversionFailed(conversionError?.localizedDescription ?? "unknown error")
            }
            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
            }
        }

        // The resampler holds back its last frames until told the input has ended; without this,
        // each file lost its final tenth of a second or so.
        while true {
            guard let tail = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else { break }
            var conversionError: NSError?
            let status = converter.convert(to: tail, error: &conversionError) { _, statusPointer in
                statusPointer.pointee = .endOfStream
                return nil
            }
            if status == .error {
                throw AudioRecorderError.conversionFailed(conversionError?.localizedDescription ?? "unknown error")
            }
            if tail.frameLength > 0 { try outputFile.write(from: tail) }
            if status == .endOfStream || tail.frameLength == 0 { break }
        }
    }
}
