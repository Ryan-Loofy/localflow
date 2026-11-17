import Darwin
import AVFoundation
import Foundation

private var failureCount = 0

private func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
    if condition() {
        print("PASS  \(description)")
    } else {
        failureCount += 1
        fputs("FAIL  \(description)\n", stderr)
    }
}

do {
    var machine = DictationStateMachine(doubleTapWindow: 0.35)
    expect(machine.hotkeyDown(at: 10) == [.beginRecording, .showMode(.held)], "hold begins recording")
    expect(machine.hotkeyUp(at: 10.5) == [.finishAndTranscribe], "long hold stops on release")
    expect(machine.phase == .transcribing, "release enters transcription")
}

do {
    var machine = DictationStateMachine(doubleTapWindow: 0.35)
    _ = machine.hotkeyDown(at: 10)
    _ = machine.hotkeyUp(at: 10.08)
    expect(
        machine.hotkeyDown(at: 10.2) == [.cancelSecondTapTimeout, .showMode(.handsFree)],
        "double-tap enters hands-free mode"
    )
    expect(machine.hotkeyUp(at: 10.25).isEmpty, "second release keeps recording")
    expect(
        machine.hotkeyDown(at: 12) == [.cancelSecondTapTimeout, .finishAndTranscribe],
        "third tap stops hands-free mode"
    )
}

do {
    var machine = DictationStateMachine(doubleTapWindow: 0.35)
    _ = machine.hotkeyDown(at: 0)
    expect(machine.cancel() == [.cancelEverything], "Escape produces cancellation")
    expect(machine.phase == .idle, "cancellation returns to idle")
}

do {
    var machine = DictationStateMachine(doubleTapWindow: 0.35)
    _ = machine.hotkeyDown(at: 0)
    expect(
        machine.forceStop() == [.cancelSecondTapTimeout, .finishAndTranscribe],
        "maximum duration forces transcription"
    )
}

do {
    let parsed = EnvFile.parse("""
    # ignored
    export LLM_API_KEY="secret"
    LLM_MODEL='local model'
    EMPTY=
    """)
    expect(parsed["LLM_API_KEY"] == "secret", ".env parses exported quoted values")
    expect(parsed["LLM_MODEL"] == "local model", ".env parses single quotes")
    expect(parsed["EMPTY"] == "", ".env preserves empty values")
}

do {
    let expanded = TranscriptCleaner.chatCompletionsURL(from: "http://127.0.0.1:8080/v1")?.absoluteString
    let unchanged = TranscriptCleaner.chatCompletionsURL(
        from: "https://example.com/v1/chat/completions"
    )?.absoluteString
    expect(expanded == "http://127.0.0.1:8080/v1/chat/completions", "LLM endpoint appends the API path")
    expect(unchanged == "https://example.com/v1/chat/completions", "full LLM endpoint is not duplicated")
}

do {
    var settings = AppSettings()
    settings.maxRecordingSeconds = 10_000
    expect(settings.maximumRecordingDuration == 300, "recording duration is capped at five minutes")
}

expect(UpdateChecker.isNewer("v0.2.3", than: "0.2.2"), "a newer release tag is offered")
expect(!UpdateChecker.isNewer("v0.2.2", than: "0.2.2"), "the same version is up to date")
expect(UpdateChecker.isNewer("v0.10.0", than: "0.9.1"), "versions compare by number, not text")
expect(!UpdateChecker.isNewer("v0.2.1", than: "0.2.2"), "an older release is not offered")
expect(HotkeyDefinition.soloModifierName(for: 61) == "right_option", "Right Option is recognized as a lone modifier key")
expect((try? HotkeyDefinition(settings: HotkeySettings(key: "right_option", modifiers: [])))?.soloFlag == .maskAlternate, "Right Option alone is a valid dictation key")
expect((try? HotkeyDefinition(settings: HotkeySettings(key: "fn", modifiers: [])))?.isFunctionKey == true, "fn is still the function key")
expect(HotkeyDefinition.displayName(HotkeySettings(key: "right_command", modifiers: []), capsLock: false) == "Right ⌘", "a lone modifier key reads as Right ⌘")
expect(HotkeyDefinition.keyName(for: 49) == "space", "a recorded key code maps back to its settings name")
expect(HotkeyDefinition.displayName(HotkeySettings(key: "space", modifiers: ["command", "option"]), capsLock: false) == "⌥⌘ Space", "a custom shortcut reads in macOS modifier order")
expect(HotkeyDefinition.displayName(HotkeySettings(key: "f13", modifiers: []), capsLock: true) == "Caps Lock", "Caps Lock mapped to F13 reads as Caps Lock")
expect((try? HotkeyDefinition(settings: HotkeySettings(key: "d", modifiers: ["control", "shift"]))) != nil, "a recorded letter with modifiers is a valid hotkey")

do {
    let hotkey = try HotkeyDefinition(settings: HotkeySettings(key: "f13", modifiers: []))
    expect(hotkey.keyCode == 105, "F13 is accepted without modifiers for programmable keys")
} catch {
    failureCount += 1
    fputs("FAIL  F13 hotkey configuration threw: \(error.localizedDescription)\n", stderr)
}

do {
    _ = try HotkeyDefinition(settings: HotkeySettings(key: "space", modifiers: []))
    failureCount += 1
    fputs("FAIL  ordinary unmodified keys remain rejected\n", stderr)
} catch HotkeyError.modifierRequired {
    print("PASS  ordinary unmodified keys remain rejected")
} catch {
    failureCount += 1
    fputs("FAIL  ordinary unmodified key returned the wrong error: \(error.localizedDescription)\n", stderr)
}

do {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalFlow-AudioSelfTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.caf")
    let outputURL = directory.appendingPathComponent("output.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let sourceFile = try AVAudioFile(forWriting: sourceURL, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    buffer.frameLength = 48_000
    if let samples = buffer.floatChannelData?[0] {
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = sin(Float(frame) * 2 * .pi * 440 / 48_000) * 0.1
        }
    }
    try sourceFile.write(from: buffer)

    try AudioRecorder.convertToWhisperWAV(sourceURL: sourceURL, outputURL: outputURL)
    let outputFile = try AVAudioFile(forReading: outputURL)
    expect(outputFile.fileFormat.sampleRate == 16_000, "audio conversion produces 16 kHz WAV")
    expect(outputFile.fileFormat.channelCount == 1, "audio conversion produces mono WAV")
    expect(outputFile.fileFormat.commonFormat == .pcmFormatInt16, "audio conversion produces signed 16-bit PCM")
    expect(outputFile.length > 15_000 && outputFile.length < 17_000, "audio conversion preserves duration")
} catch {
    failureCount += 1
    fputs("FAIL  audio conversion threw: \(error.localizedDescription)\n", stderr)
}

do {
    // A Bluetooth headset can stop the engine mid-recording; the restarted engine writes a second
    // segment, possibly at another rate, and both must reach whisper as one recording.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("localflow-segments-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var sources: [URL] = []
    for (index, rate) in [48_000.0, 24_000.0].enumerated() {
        let url = directory.appendingPathComponent("capture-\(index).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
        buffer.frameLength = AVAudioFrameCount(rate)
        try file.write(from: buffer)
        sources.append(url)
    }
    let outputURL = directory.appendingPathComponent("out.wav")
    try AudioRecorder.convertToWhisperWAV(sourceURLs: sources, outputURL: outputURL)
    let output = try AVAudioFile(forReading: outputURL)
    expect(output.length == 32_000, "segments at different rates join into one recording")
} catch {
    failureCount += 1
    fputs("FAIL  segment conversion threw: \(error.localizedDescription)\n", stderr)
}

do {
    var machine = DictationStateMachine(doubleTapWindow: 0.35, tapToToggle: true)
    expect(machine.hotkeyDown(at: 10) == [.beginRecording, .showMode(.held)], "tap mode: press begins recording")
    expect(machine.hotkeyUp(at: 10.1) == [.showMode(.handsFree)], "tap mode: quick release keeps recording")
    expect(machine.phase == .recording(.handsFree), "tap mode: quick tap is hands-free")
    expect(machine.hotkeyDown(at: 14) == [.cancelSecondTapTimeout, .finishAndTranscribe], "tap mode: second tap stops")
    expect(machine.hotkeyUp(at: 14.1).isEmpty, "tap mode: second release does nothing")
}

do {
    var machine = DictationStateMachine(doubleTapWindow: 0.35, tapToToggle: true)
    _ = machine.hotkeyDown(at: 10)
    expect(machine.hotkeyUp(at: 12) == [.finishAndTranscribe], "tap mode: a long hold still works as push-to-talk")
}

do {
    var machine = DictationStateMachine(doubleTapWindow: 0.35, tapToToggle: true)
    _ = machine.hotkeyDown(at: 10)
    _ = machine.hotkeyUp(at: 10.1)
    expect(machine.phase.isCapturingAudio, "tap mode: recording counts as capturing for the Return key")
    expect(machine.forceStop() == [.cancelSecondTapTimeout, .finishAndTranscribe], "Return stops a tap-mode recording")
    expect(!machine.phase.isCapturingAudio, "after Return, Return is no longer swallowed")
    expect(machine.forceStop().isEmpty, "a second Return does nothing")
}

expect(!TranscriptCleaner.needsCleanup("Can you check whether the pipeline ran last night?"), "clean text skips cleanup")
expect(TranscriptCleaner.needsCleanup("So um we should ship it."), "filler word needs cleanup")
expect(TranscriptCleaner.needsCleanup("We should ship the the connector."), "repeated word needs cleanup")
expect(TranscriptCleaner.needsCleanup("We should, we should ship it."), "repeated word across a comma needs cleanup")
expect(TranscriptCleaner.needsCleanup("I was going to... never mind."), "trailing off needs cleanup")
expect(!TranscriptCleaner.needsCleanup("Thank you. You did it."), "different words do not count as a repeat")
expect(TranscriptCleaner.needsCleanup(String(repeating: "word ", count: 20)), "long dictation is always cleaned for formatting")
expect(TranscriptCleaner.messages(for: "x").count == 10, "cleanup sends system prompt, four examples and the transcript")
expect(TranscriptCleaner.messages(for: "x").last?["content"] == "<transcript>x</transcript>", "cleanup wraps the transcript in tags")
expect(TranscriptCleaner.unwrap("<transcript> Hi. </transcript>") == "Hi.", "echoed tags are stripped from the output")

do {
    let old = #"{"enabled":true,"hotkey":{"key":"f13","modifiers":[]},"llm":{"enabled":false,"model":"m","baseURL":"http://x","fallbackToRawTranscript":true,"apiKeyEnvironmentVariable":"K"}}"#
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
    expect(settings.hotkey.key == "f13" && settings.llm.model == "m", "older settings keep their values")
    expect(settings.tapToToggle && settings.skipCleanupWhenClean && settings.whisperServerURL.hasSuffix("/inference"), "older settings get new defaults")
} catch {
    failureCount += 1
    fputs("FAIL  older settings file threw: \(error)\n", stderr)
}

do {
    let partial = #"{"llm":{"baseURL":"http://127.0.0.1:11434/v1","model":"qwen2.5:7b"}}"#
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(partial.utf8))
    expect(settings.llm.model == "qwen2.5:7b" && settings.llm.enabled && settings.llm.apiKeyEnvironmentVariable == "LLM_API_KEY", "a partial llm section keeps the other defaults")
    expect(AppSettings().llm.baseURL == "http://127.0.0.1:8179/v1" && !AppSettings().mapCapsLock, "new installs clean up with the bundled server")
} catch {
    failureCount += 1
    fputs("FAIL  partial llm section threw: \(error)\n", stderr)
}

var testTimebase = mach_timebase_info_data_t()
mach_timebase_info(&testTimebase)
let machNow: UInt64 = 1_000_000_000_000
let machNowNanos = machNow / UInt64(testTimebase.denom) * UInt64(testTimebase.numer)
let nsNow: UInt64 = machNowNanos
let machTicksPerSecond = 1_000_000_000 * UInt64(testTimebase.denom) / UInt64(testTimebase.numer)
if testTimebase.numer != testTimebase.denom {
    let half = HotkeyMonitor.eventSeconds(timestamp: machNow - machTicksPerSecond / 2, machNow: machNow, uptimeNanosNow: nsNow * 40, fallback: 9e9)
    expect(abs(half - (Double(machNowNanos) / 1e9 - 0.5)) < 0.001, "a mach-tick event timestamp converts to seconds since boot")
}
let nsEvent = HotkeyMonitor.eventSeconds(timestamp: 5_000_000_000_000 - 250_000_000, machNow: 10, uptimeNanosNow: 5_000_000_000_000, fallback: 9e9)
expect(abs(nsEvent - 4999.75) < 0.000001, "a nanosecond event timestamp reads as seconds since boot")
expect(HotkeyMonitor.eventSeconds(timestamp: 0, machNow: machNow, uptimeNanosNow: nsNow, fallback: 42) == 42, "a zero timestamp falls back to now")
var tapMachine = DictationStateMachine(doubleTapWindow: 0.35, tapToToggle: true)
_ = tapMachine.hotkeyDown(at: 100.0)
// The key-up is handled 1.2 s late, but its event says it moved 0.1 s after the press: still a tap.
expect(tapMachine.hotkeyUp(at: 100.1) == [.showMode(.handsFree)], "a quick tap timed by its own event stays a tap")
expect(HotkeyMonitor.escapeCancels(type: .keyDown, keyCode: 53, isRepeat: false, busy: true), "Escape cancels a dictation that is recording or transcribing")
expect(!HotkeyMonitor.escapeCancels(type: .keyDown, keyCode: 53, isRepeat: false, busy: false), "Escape passes through when nothing is being dictated")
expect(!HotkeyMonitor.escapeCancels(type: .keyDown, keyCode: 53, isRepeat: true, busy: true), "a held Escape cancels once, not on every repeat")
expect(!HotkeyMonitor.escapeCancels(type: .keyDown, keyCode: 36, isRepeat: false, busy: true), "only Escape cancels")

do {
    let silent = try WhisperTranscriber.serverTranscript(statusCode: 200, body: Data())
    let blank = try WhisperTranscriber.serverTranscript(statusCode: 200, body: Data(" [BLANK_AUDIO]\n".utf8))
    let quiet = try WhisperTranscriber.serverTranscript(statusCode: 200, body: Data("(silence)".utf8))
    let words = try WhisperTranscriber.serverTranscript(statusCode: 200, body: Data(" Hello there.\n".utf8))
    expect(silent == "" && blank == "" && quiet == "", "a server that heard no speech returns nothing, not an error")
    expect(words == "Hello there.", "a server transcript is trimmed and kept")
    expect((try? WhisperTranscriber.serverTranscript(statusCode: 500, body: Data("boom".utf8))) == nil, "a server error still falls back to whisper-cli")
} catch {
    failureCount += 1
    fputs("FAIL  serverTranscript threw: \(error)\n", stderr)
}

expect(WhisperTranscriber.isTooShortForSpeech(frames: 0) && !WhisperTranscriber.isTooShortForSpeech(frames: 16_000), "a recording with no audio frames is no speech, a second of audio is transcribed")
do {
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent("localflow-selftest-empty.wav")
    try WhisperTranscriber.silentWAV(seconds: 0).write(to: empty)
    expect(WhisperTranscriber.audioFrames(empty) == 0, "an empty recording reads as zero frames")
} catch {
    failureCount += 1
    fputs("FAIL  empty recording threw: \(error)\n", stderr)
}

if failureCount > 0 {
    fputs("\n\(failureCount) self-test(s) failed.\n", stderr)
    exit(1)
}
print("\nAll LocalFlow self-tests passed.")
