import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum AudioRecorderError: LocalizedError {
    case microphonePermissionDenied
    case invalidInputFormat
    case notRecording
    case conversionFailed(String)
    case audioUnit(String, OSStatus)

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
        case .audioUnit(let step, let status):
            return "The microphone could not be opened (\(step), error \(status))."
        }
    }
}

/// Reads the default mic through an input-only audio unit. AVAudioEngine also starts the sound
/// output side, and took 265 to 346 ms from start to the first audio; this took 46 to 51 ms
/// (measured on Ryan's Mac, 2026-11-18). Each recording, and each restart within one, gets its
/// own unit, so a mic change never leaves a stale input behind (the 2026-11-04 bug).
private final class MicCapture {
    let device: AudioDeviceID
    let sampleRate: Double
    private let unit: AudioUnit
    private var format: AudioStreamBasicDescription
    private let samples: UnsafeMutablePointer<Float>
    private static let capacity: UInt32 = 16_384
    private var file: ExtAudioFileRef?
    private var disposed = false

    init(device: AudioDeviceID) throws {
        self.device = device
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioRecorderError.audioUnit("find", -1)
        }
        var created: AudioUnit?
        try Self.check("create", AudioComponentInstanceNew(component, &created))
        guard let unit = created else { throw AudioRecorderError.audioUnit("create", -1) }
        self.unit = unit
        samples = .allocate(capacity: Int(Self.capacity))

        do {
            var on: UInt32 = 1
            var off: UInt32 = 0
            var chosen = device
            try Self.check("enable input", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4))
            try Self.check("disable output", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4))
            try Self.check("choose mic", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &chosen, 4))

            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check("read format", AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size))
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0 else { throw AudioRecorderError.invalidInputFormat }
            sampleRate = hardware.mSampleRate

            // Mono 32-bit float at the mic's own rate: the unit cannot resample on input, and the
            // conversion to whisper's 16 kHz happens once the recording ends.
            format = AudioStreamBasicDescription(
                mSampleRate: hardware.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
            )
            try Self.check("set format", AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, size))

            var callback = AURenderCallbackStruct(
                inputProc: micInputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try Self.check("set callback", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try Self.check("initialize", AudioUnitInitialize(unit))
        } catch {
            AudioComponentInstanceDispose(unit)
            samples.deallocate()
            disposed = true
            throw error
        }
    }

    deinit { dispose() }

    var isRunning: Bool {
        var running: UInt32 = 0
        var size = UInt32(4)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size)
        return status == noErr && running != 0
    }

    /// Opens the file and starts the mic. Audio is written on the audio thread with
    /// ExtAudioFileWriteAsync, which is made for exactly that.
    func start(writingTo url: URL) throws {
        var created: ExtAudioFileRef?
        try Self.check("create file", ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &format, nil, AudioFileFlags.eraseFile.rawValue, &created))
        guard let created else { throw AudioRecorderError.audioUnit("create file", -1) }
        // The first async write allocates its buffers; done here, off the audio thread.
        ExtAudioFileWriteAsync(created, 0, nil)
        file = created
        let status = AudioOutputUnitStart(unit)
        if status != noErr {
            ExtAudioFileDispose(created)
            file = nil
            throw AudioRecorderError.audioUnit("start", status)
        }
    }

    /// Stops the mic, which waits for the audio thread, then flushes and closes the file.
    func stop() {
        guard !disposed else { return }
        AudioOutputUnitStop(unit)
        if let file { ExtAudioFileDispose(file) }
        file = nil
    }

    func dispose() {
        guard !disposed else { return }
        stop()
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        samples.deallocate()
        disposed = true
    }

    fileprivate func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard frames <= Self.capacity else { return kAudioUnitErr_TooManyFramesToProcess }
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: UnsafeMutableRawPointer(samples))
        )
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, &list)
        if status == noErr, let file {
            ExtAudioFileWriteAsync(file, frames, &list)
        }
        return status
    }

    private static func check(_ step: String, _ status: OSStatus) throws {
        if status != noErr { throw AudioRecorderError.audioUnit(step, status) }
    }
}

private let micInputCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
    Unmanaged<MicCapture>.fromOpaque(refCon).takeUnretainedValue()
        .render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
}

/// CoreAudio calls this on its own thread; the work moves to the main queue, where the recorder lives.
private let micChangeListener: AudioObjectPropertyListenerProc = { _, count, addresses, data in
    guard let data, count > 0 else { return noErr }
    let selector = addresses[0].mSelector
    let recorder = Unmanaged<AudioRecorder>.fromOpaque(data)
    DispatchQueue.main.async { recorder.takeUnretainedValue().micChanged(selector) }
    return noErr
}

final class AudioRecorder {
    private var capture: MicCapture?
    private var sessionDirectory: URL?
    /// One file per mic run. A Bluetooth headset switches to its call mode when the mic opens,
    /// and a mic can change mid-recording; either way the mic is reopened into a new segment, and
    /// every segment is transcribed together (2026-11-17: two dictations were lost before this).
    private var segments: [URL] = []
    private var restarts = 0
    private static let maximumRestarts = 5
    /// A mic unit built and initialized while idle, so a press only has to start it. Used only
    /// if the default mic is still the one it was built for.
    private var spare: MicCapture?
    /// Registered with a C function and this recorder as its data, because CoreAudio removes a
    /// listener only by the same pair: a Swift block is bridged anew on each call, so removing
    /// one never matched and every recording left its listeners behind (seen 2026-11-18).
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress)] = []

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
            try startSegment(in: directory, prewarmed: takeSpare())
        } catch {
            DebugLog.write("recording failed to start: \(error.localizedDescription)")
            discardFiles()
            throw error
        }
    }

    /// Builds the next mic unit ahead of the next press. Nothing is opened for sound until it
    /// starts, so no mic indicator shows and no headset switches to its call mode here.
    func prewarm() {
        guard capture == nil, spare == nil,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let device = Self.defaultInputDevice() else { return }
        let began = DispatchTime.now()
        do {
            spare = try MicCapture(device: device)
            DebugLog.write("mic prewarmed in \(Self.milliseconds(since: began)) ms")
        } catch {
            DebugLog.write("mic prewarm failed: \(error.localizedDescription)")
        }
    }

    /// Prewarms after the current work settles, so it never sits between a press and the mic.
    func prewarmSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.prewarm() }
    }

    private func takeSpare() -> MicCapture? {
        guard let spare else { return nil }
        self.spare = nil
        guard spare.device == Self.defaultInputDevice() else {
            DebugLog.write("prewarmed mic discarded: the default mic changed")
            spare.dispose()
            return nil
        }
        return spare
    }

    /// Starts a mic unit writing to the next segment file: the prewarmed one if given, else a new
    /// one on the current default mic.
    private func startSegment(in directory: URL, prewarmed: MicCapture? = nil) throws {
        let began = DispatchTime.now()
        stopCapture()
        let next: MicCapture
        if let prewarmed {
            next = prewarmed
        } else {
            guard let device = Self.defaultInputDevice() else { throw AudioRecorderError.invalidInputFormat }
            next = try MicCapture(device: device)
        }
        let ready = Self.milliseconds(since: began)
        let url = directory.appendingPathComponent("capture-\(segments.count).caf")
        do {
            try next.start(writingTo: url)
        } catch {
            next.dispose()
            throw error
        }
        capture = next
        segments.append(url)
        watchForChanges(device: next.device)
        DebugLog.write("recording started: \(Int(next.sampleRate)) Hz, 1 ch, segment \(segments.count), \(prewarmed == nil ? "cold" : "prewarmed") mic, ready \(ready) ms, started \(Self.milliseconds(since: began)) ms")
    }

    /// Reopens the mic into a new segment when its rate changes, it goes away, or another mic
    /// becomes the default, and checks again shortly after, since a mic can stop a moment later.
    private func watchForChanges(device: AudioDeviceID) {
        removeListeners()
        let watched: [(AudioObjectID, AudioObjectPropertySelector)] = [
            (device, kAudioDevicePropertyNominalSampleRate),
            (device, kAudioDevicePropertyDeviceIsAlive),
            (AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
        ]
        let data = Unmanaged.passUnretained(self).toOpaque()
        for (object, selector) in watched {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListener(object, &address, micChangeListener, data) == noErr {
                listeners.append((object, address))
            }
        }
    }

    /// Called on the main queue for a change one of the listeners saw.
    fileprivate func micChanged(_ selector: AudioObjectPropertySelector) {
        guard capture != nil else { return }
        let reason: String
        switch selector {
        case kAudioDevicePropertyNominalSampleRate: reason = "the mic's sample rate changed"
        case kAudioDevicePropertyDeviceIsAlive: reason = "the mic went away"
        default: reason = "the default mic changed"
        }
        DebugLog.write("mic changed while recording: \(reason)")
        reopen()
    }

    private func removeListeners() {
        let data = Unmanaged.passUnretained(self).toOpaque()
        for (object, address) in listeners {
            var address = address
            AudioObjectRemovePropertyListener(object, &address, micChangeListener, data)
        }
        listeners = []
    }

    deinit {
        removeListeners()
        capture?.dispose()
        spare?.dispose()
    }

    private func reopen() {
        guard let directory = sessionDirectory, capture != nil else { return }
        guard restarts < Self.maximumRestarts else {
            DebugLog.write("mic changed again; keeping what was recorded")
            return
        }
        restarts += 1
        do {
            try startSegment(in: directory)
            DebugLog.write("mic reopened after a change (\(restarts))")
        } catch {
            DebugLog.write("mic reopen failed: \(error.localizedDescription); keeping what was recorded")
            stopCapture()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let capture = self.capture, !capture.isRunning else { return }
            DebugLog.write("mic stopped after reopening")
            self.reopen()
        }
    }

    private func stopCapture() {
        removeListeners()
        capture?.dispose()
        capture = nil
    }

    /// Converts everything recorded, including what was captured before a mic change.
    func stopAndConvert() throws -> URL {
        guard let directory = sessionDirectory, !segments.isEmpty else {
            DebugLog.write("stop with no recording: micOpen=\(capture != nil) haveFiles=\(sessionDirectory != nil)")
            throw AudioRecorderError.notRecording
        }
        if let capture, !capture.isRunning {
            DebugLog.write("stop after the system stopped the mic; transcribing what was recorded")
        }
        stopCapture()

        let outputURL = directory.appendingPathComponent("capture-16khz.wav")
        try Self.convertToWhisperWAV(sourceURLs: segments, outputURL: outputURL)
        for segment in segments { try? FileManager.default.removeItem(at: segment) }
        segments = []
        prewarmSoon()
        return outputURL
    }

    func cancel() {
        stopCapture()
        discardFiles()
    }

    /// Ends a session that will not be followed straight away by a new one, then gets the next mic ready.
    func cancelAndPrewarm() {
        cancel()
        prewarmSoon()
    }

    func discardFiles() {
        if let sessionDirectory {
            try? FileManager.default.removeItem(at: sessionDirectory)
        }
        sessionDirectory = nil
        segments = []
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func milliseconds(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
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
