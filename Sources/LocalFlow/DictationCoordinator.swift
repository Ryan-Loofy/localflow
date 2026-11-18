import AppKit
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
    private var keepWarmTask: Task<Void, Never>?
    /// Set while an edit-by-voice session runs: the selected text, read while the instruction is spoken.
    private var editSelection: Task<String?, Never>?
    /// An edit session is recording its instruction; the selection is read once recording stops.
    private var editPending = false
    private var startingEdit = false
    /// What LocalFlow pasted last, so an edit with nothing selected can work on it.
    private var lastInserted: String?

    /// macOS pages an idle model out to swap after roughly twenty minutes on a Mac short of memory,
    /// and paging the 4.6 GB cleanup model back in took 26 s (Ollama log, 2026-11-16): the cleanup
    /// waited behind it. A one-token request every four minutes keeps the weights resident.
    static let keepWarmInterval: TimeInterval = 240
    /// The style for the app in front when recording started, which is where the text is pasted.
    private var sessionStyle = WritingStyle.standard

    var onPhaseChanged: ((DictationPhase) -> Void)?
    /// The text just typed, for the Dictionary window's "last dictation". Held in memory only.
    var onDictated: ((String) -> Void)?
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
        startKeepingModelsWarm()
        recorder.prewarmSoon()
    }

    private func startKeepingModelsWarm() {
        keepWarmTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.keepWarmInterval * 1_000_000_000))
                guard let self else { return }
                guard self.settings.enabled, self.machine.phase == .idle else { continue }
                self.warmModels()
            }
        }
    }

    /// Idle pings use the standard style: they only keep the weights in memory. At record start the
    /// session's style also caches its prompt prefix, and a raw session skips the cleanup model.
    private func warmModels(style: WritingStyle = .standard) {
        transcriber.warmUp(settings: settings)
        if style != .raw, let environment = try? environmentProvider() {
            cleaner.warmUp(
                settings: settings.llm, environment: environment,
                style: style, spellings: Personalization.spellings(settings.dictionary),
                personal: Personalization.personalExamples(settings, style: style)
            )
        }
    }

    /// A dictionary edit takes effect on the next dictation without cancelling one in progress.
    func updateDictionary(_ dictionary: DictionarySettings) {
        settings.dictionary = dictionary
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

    /// The edit shortcut: from idle it starts an edit of the selected text; mid-dictation it acts as the dictation key.
    func editHotkeyDown(at time: TimeInterval) {
        DebugLog.write("edit hotkey down, phase=\(machine.phase) enabled=\(settings.enabled)")
        guard settings.enabled else { return }
        startingEdit = machine.phase == .idle
        perform(machine.hotkeyDown(at: time))
        startingEdit = false
        notifyPhase()
    }

    func hotkeyUp(at time: TimeInterval) {
        guard settings.enabled else { return }
        perform(machine.hotkeyUp(at: time))
        notifyPhase()
    }

    var isCapturingAudio: Bool { machine.phase.isCapturingAudio }
    /// Recording or transcribing: the times Escape has something to cancel.
    var isBusy: Bool { machine.phase != .idle }

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
                pill.show(editPending ? .recordingEdit : (mode == .held ? .recordingHeld : .recordingHandsFree))
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
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // In a browser the website decides (LinkedIn writes a post). The host is used here and never logged.
        if startingEdit {
            editPending = true
            DebugLog.write("edit by voice for app=\(app ?? "unknown")")
            sessionStyle = .standard
            warmModels()
            beginSession()
            return
        }
        editPending = false
        editSelection = nil
        let host = BrowserTab.host(forApp: app)
        sessionStyle = Personalization.style(forApp: app, host: host, settings: settings)
        DebugLog.write("recording for app=\(app ?? "unknown") style=\(sessionStyle.rawValue)\(host == nil ? "" : " (from the browser tab)")")
        warmModels(style: sessionStyle)
        beginSession()
    }

    /// Starts the microphone and the maximum-length timer for a new session.
    private func beginSession() {
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
            DebugLog.write("finish with no session")
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
                // Selecting sends keystrokes to the front app, so it waits until the microphone is off,
                // then runs while the instruction is transcribed.
                if self.editPending {
                    let last = self.lastInserted
                    self.editSelection = Task { await SelectionReader.target(lastInserted: last) }
                }
                let dictionary = self.settings.dictionary
                let style = self.sessionStyle
                let (heard, engine) = try await self.transcriber.transcribe(
                    audioURL: audioURL, settings: self.settings, prompt: Personalization.whisperPrompt(dictionary)
                )
                timing.mark("whisper_\(engine)")
                try Task.checkCancellation()
                guard !heard.isEmpty else {
                    DebugLog.write("no speech heard; nothing to insert")
                    self.complete(id: id)
                    return
                }

                if let selectionTask = self.editSelection {
                    try await self.applyEdit(instruction: heard, selection: await selectionTask.value, id: id, timing: timing)
                    return
                }

                let rawTranscript = Personalization.applyReplacements(heard, dictionary.replacements)
                let environment = try self.environmentProvider()
                var finalTranscript: String
                if let snippet = Personalization.wholeSnippet(rawTranscript, dictionary.snippets) {
                    // The whole dictation was a trigger phrase: paste the snippet exactly, untouched by cleanup.
                    finalTranscript = snippet
                    timing.mark("snippet")
                } else {
                    if style == .raw || (self.settings.skipCleanupWhenClean && !TranscriptCleaner.needsCleanup(rawTranscript)) {
                        finalTranscript = rawTranscript
                        timing.mark("cleanup_skipped")
                    } else {
                        do {
                            finalTranscript = try await self.cleaner.clean(
                                rawTranscript,
                                settings: self.settings.llm,
                                environment: environment,
                                style: style,
                                spellings: Personalization.spellings(dictionary),
                                personal: Personalization.personalExamples(self.settings, style: style)
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
                    finalTranscript = Personalization.finish(finalTranscript, style: style)
                    finalTranscript = Personalization.expandSnippets(finalTranscript, dictionary.snippets)
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
                self.lastInserted = finalTranscript
                self.onDictated?(finalTranscript)
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

    /// Rewrites the selection as the spoken instruction says and pastes the result over it. With nothing
    /// selected it says so and changes nothing; if the model fails, the selection is left as it was.
    private func applyEdit(instruction: String, selection: String?, id: UUID, timing: TimingLog.Entry) async throws {
        var timing = timing
        editSelection = nil
        editPending = false
        guard let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail(id: id, message: "Nothing to edit: select some text, or dictate first.")
            return
        }
        let style = Personalization.style(forApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, settings: settings)
        let voice = Personalization.personalExamples(settings, style: style == .standard ? .casual : style).map(\.written)
        let rewritten = try await cleaner.edit(
            selection, instruction: instruction, settings: settings.llm, environment: try environmentProvider(),
            spellings: Personalization.spellings(settings.dictionary), voice: voice
        )
        timing.mark("edit")
        try Task.checkCancellation()
        guard sessionID == id else { return }
        try await inserter.insert(
            rewritten,
            restorePreviousClipboard: settings.restorePreviousClipboard,
            restoreDelay: TimeInterval(settings.clipboardRestoreDelayMilliseconds) / 1_000
        )
        timing.mark("paste")
        TimingLog.write(timing, words: rewritten.split(separator: " ").count)
        lastInserted = rewritten
        onDictated?(rewritten)
        complete(id: id)
    }

    private func cancelEverything() {
        editSelection?.cancel()
        editSelection = nil
        editPending = false
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
        recorder.cancelAndPrewarm()
        pill.hide()
    }

    private func complete(id: UUID) {
        guard sessionID == id else { return }
        editSelection = nil
        editPending = false
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
        editSelection = nil
        editPending = false
        transcriber.cancel()
        recorder.cancelAndPrewarm()
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
