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
    private var sourceFile: AVAudioFile?
    private var sessionDirectory: URL?

    var isRecording: Bool { engine.isRunning }

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
        engine = AVAudioEngine()

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AudioRecorderError.invalidInputFormat
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("capture.caf")
        let file = try AVAudioFile(forWriting: sourceURL, settings: format.settings)

        sourceFile = file
        sessionDirectory = directory
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak file] buffer, _ in
            try? file?.write(from: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            DebugLog.write("recording started: \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
        } catch {
            DebugLog.write("recording failed to start: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            sourceFile = nil
            try? FileManager.default.removeItem(at: directory)
            sessionDirectory = nil
            throw error
        }
    }

    func stopAndConvert() throws -> URL {
        guard engine.isRunning, let directory = sessionDirectory else {
            throw AudioRecorderError.notRecording
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sourceFile = nil

        let sourceURL = directory.appendingPathComponent("capture.caf")
        let outputURL = directory.appendingPathComponent("capture-16khz.wav")
        try Self.convertToWhisperWAV(sourceURL: sourceURL, outputURL: outputURL)
        try? FileManager.default.removeItem(at: sourceURL)
        return outputURL
    }

    func cancel() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        sourceFile = nil
        if let sessionDirectory {
            try? FileManager.default.removeItem(at: sessionDirectory)
        }
        sessionDirectory = nil
    }

    func discardFiles() {
        if let sessionDirectory {
            try? FileManager.default.removeItem(at: sessionDirectory)
        }
        sessionDirectory = nil
    }

    static func convertToWhisperWAV(sourceURL: URL, outputURL: URL) throws {
        let inputFile = try AVAudioFile(forReading: sourceURL)
        let inputFormat = inputFile.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioRecorderError.conversionFailed("unsupported microphone format")
        }

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
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
    }
}
