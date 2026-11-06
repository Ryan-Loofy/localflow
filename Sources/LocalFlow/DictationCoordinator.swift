import Foundation

@MainActor
final class DictationCoordinator {
    private(set) var settings: AppSettings
    private var machine: DictationStateMachine
    private let recorder: AudioRecorder
    private let transcriber: WhisperTranscriber
    private let cleaner: TranscriptCleaner
    private let inserter: TextInserter
    private let pill: FloatingPillController
    private let environmentProvider: () throws -> [String: String]

    private var sessionID: UUID?
    private var recordingStartTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var secondTapTask: Task<Void, Never>?
    private var maximumDurationTask: Task<Void, Never>?

    var onPhaseChanged: ((DictationPhase) -> Void)?
    var onError: ((String) -> Void)?

    init(
        settings: AppSettings,
        recorder: AudioRecorder = AudioRecorder(),
        transcriber: WhisperTranscriber = WhisperTranscriber(),
        cleaner: TranscriptCleaner = TranscriptCleaner(),
        inserter: TextInserter? = nil,
        pill: FloatingPillController,
        environmentProvider: @escaping () throws -> [String: String]
    ) {
        self.settings = settings
        machine = DictationStateMachine(doubleTapWindow: settings.doubleTapWindow, tapToToggle: settings.tapToToggle)
        self.recorder = recorder
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.inserter = inserter ?? TextInserter()
        self.pill = pill
        self.environmentProvider = environmentProvider
    }

    func update(settings: AppSettings) {
        cancel()
        self.settings = settings
        machine = DictationStateMachine(doubleTapWindow: settings.doubleTapWindow, tapToToggle: settings.tapToToggle)
        notifyPhase()
    }

    func hotkeyDown(at time: TimeInterval) {
        DebugLog.write("hotkey down, phase=\(machine.phase) enabled=\(settings.enabled)")
        guard settings.enabled else { return }
        perform(machine.hotkeyDown(at: time))
        notifyPhase()
    }

    func hotkeyUp(at time: TimeInterval) {
        guard settings.enabled else { return }
        perform(machine.hotkeyUp(at: time))
        notifyPhase()
    }

    var isCapturingAudio: Bool { machine.phase.isCapturingAudio }

    /// Return pressed while recording: stop and transcribe, same as a second hotkey tap.
    func stopKeyPressed() {
        guard settings.enabled else { return }
        perform(machine.forceStop())
        notifyPhase()
    }

    func cancel() {
        let actions = machine.cancel()
        if actions.isEmpty { return }
        perform(actions)
        notifyPhase()
    }

    private func perform(_ actions: [DictationAction]) {
        for action in actions {
            switch action {
            case .beginRecording:
                beginRecording()
            case .showMode(let mode):
                pill.show(mode == .held ? .recordingHeld : .recordingHandsFree)
            case .scheduleSecondTapTimeout(let delay):
                scheduleSecondTapTimeout(after: delay)
            case .cancelSecondTapTimeout:
                secondTapTask?.cancel()
                secondTapTask = nil
            case .finishAndTranscribe:
                finishAndTranscribe()
            case .cancelEverything:
                cancelEverything()
            }
        }
    }

    private func beginRecording() {
        transcriber.warmUp(settings: settings)
        if let environment = try? environmentProvider() {
            cleaner.warmUp(settings: settings.llm, environment: environment)
        }
        let id = UUID()
        sessionID = id
        maximumDurationTask?.cancel()
        maximumDurationTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.settings.maximumRecordingDuration * 1_000_000_000))
            guard !Task.isCancelled, self.sessionID == id else { return }
            self.perform(self.machine.forceStop())
            self.notifyPhase()
        }

        recordingStartTask = Task { [weak self] in
            guard let self else { return }
            let allowed = await AudioRecorder.requestPermission()
            guard !Task.isCancelled, self.sessionID == id else { return }
            guard allowed else {
                self.fail(id: id, message: AudioRecorderError.microphonePermissionDenied.localizedDescription)
                return
            }
            do {
                try self.recorder.start()
            } catch {
                self.fail(id: id, message: error.localizedDescription)
            }
        }
    }

    private func scheduleSecondTapTimeout(after delay: TimeInterval) {
        secondTapTask?.cancel()
        secondTapTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.perform(self.machine.secondTapWindowExpired())
            self.notifyPhase()
        }
    }

    private func finishAndTranscribe() {
        secondTapTask?.cancel()
        secondTapTask = nil
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        pill.show(.transcribing)

        guard let id = sessionID else {
            fail(id: nil, message: AudioRecorderError.notRecording.localizedDescription)
            return
        }
        let startTask = recordingStartTask
        processingTask = Task { [weak self] in
            guard let self else { return }
            await startTask?.value
            guard !Task.isCancelled, self.sessionID == id else { return }

            do {
                var timing = TimingLog.Entry()
                let audioURL = try self.recorder.stopAndConvert()
                timing.mark("audio")
                let (rawTranscript, engine) = try await self.transcriber.transcribe(audioURL: audioURL, settings: self.settings)
                timing.mark("whisper_\(engine)")
                try Task.checkCancellation()

                let environment = try self.environmentProvider()
                let finalTranscript: String
                if self.settings.skipCleanupWhenClean && !TranscriptCleaner.needsCleanup(rawTranscript) {
                    finalTranscript = rawTranscript
                    timing.mark("cleanup_skipped")
                } else {
                do {
                    finalTranscript = try await self.cleaner.clean(
                        rawTranscript,
                        settings: self.settings.llm,
                        environment: environment
                    )
                } catch {
                    if self.settings.llm.fallbackToRawTranscript {
                        DebugLog.write("LLM cleanup failed; inserting raw transcript: \(error.localizedDescription)")
                        finalTranscript = rawTranscript
                    } else {
                        throw error
                    }
                }
                timing.mark("cleanup")
                }

                try Task.checkCancellation()
                guard self.sessionID == id else { return }
                try await self.inserter.insert(
                    finalTranscript,
                    restorePreviousClipboard: self.settings.restorePreviousClipboard,
                    restoreDelay: TimeInterval(self.settings.clipboardRestoreDelayMilliseconds) / 1_000
                )
                timing.mark("paste")
                TimingLog.write(timing, words: finalTranscript.split(separator: " ").count)
                self.complete(id: id)
            } catch is CancellationError {
                return
            } catch WhisperError.cancelled {
                return
            } catch {
                self.fail(id: id, message: error.localizedDescription)
            }
        }
    }

    private func cancelEverything() {
        sessionID = nil
        secondTapTask?.cancel()
        maximumDurationTask?.cancel()
        recordingStartTask?.cancel()
        processingTask?.cancel()
        secondTapTask = nil
        maximumDurationTask = nil
        recordingStartTask = nil
        processingTask = nil
        transcriber.cancel()
        recorder.cancel()
        pill.hide()
    }

    private func complete(id: UUID) {
        guard sessionID == id else { return }
        recorder.discardFiles()
        sessionID = nil
        recordingStartTask = nil
        processingTask = nil
        machine.processingCompleted()
        pill.hide()
        notifyPhase()
    }

    private func fail(id: UUID?, message: String) {
        if let id, sessionID != id { return }
        transcriber.cancel()
        recorder.cancel()
        sessionID = nil
        recordingStartTask?.cancel()
        recordingStartTask = nil
        processingTask = nil
        secondTapTask?.cancel()
        secondTapTask = nil
        maximumDurationTask?.cancel()
        maximumDurationTask = nil
        machine.processingCompleted()
        DebugLog.write("dictation failed: \(message)")
        pill.show(.error(message))
        onError?(message)
        notifyPhase()
    }

    private func notifyPhase() {
        onPhaseChanged?(machine.phase)
    }
}
