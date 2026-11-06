import Foundation

enum RecordingMode: Equatable {
    case held
    case handsFree
}

enum DictationPhase: Equatable {
    case idle
    case recording(RecordingMode)
    case awaitingSecondTap
    case transcribing

    var isCapturingAudio: Bool {
        switch self {
        case .recording, .awaitingSecondTap:
            return true
        case .idle, .transcribing:
            return false
        }
    }
}

enum DictationAction: Equatable {
    case beginRecording
    case showMode(RecordingMode)
    case scheduleSecondTapTimeout(TimeInterval)
    case cancelSecondTapTimeout
    case finishAndTranscribe
    case cancelEverything
}

struct DictationStateMachine {
    private(set) var phase: DictationPhase = .idle
    private var firstPressTime: TimeInterval?
    let doubleTapWindow: TimeInterval
    /// Tap once to start and once to stop. Holding past the window still works as push-to-talk.
    let tapToToggle: Bool

    init(doubleTapWindow: TimeInterval, tapToToggle: Bool = false) {
        self.doubleTapWindow = doubleTapWindow
        self.tapToToggle = tapToToggle
    }

    mutating func hotkeyDown(at time: TimeInterval) -> [DictationAction] {
        switch phase {
        case .idle:
            firstPressTime = time
            phase = .recording(.held)
            return [.beginRecording, .showMode(.held)]

        case .awaitingSecondTap:
            guard let firstPressTime, time - firstPressTime <= doubleTapWindow else {
                return []
            }
            phase = .recording(.handsFree)
            return [.cancelSecondTapTimeout, .showMode(.handsFree)]

        case .recording(.handsFree):
            phase = .transcribing
            return [.cancelSecondTapTimeout, .finishAndTranscribe]

        case .recording(.held), .transcribing:
            return []
        }
    }

    mutating func hotkeyUp(at time: TimeInterval) -> [DictationAction] {
        guard phase == .recording(.held), let firstPressTime else { return [] }
        let elapsed = max(0, time - firstPressTime)
        if elapsed >= doubleTapWindow {
            phase = .transcribing
            return [.finishAndTranscribe]
        }

        if tapToToggle {
            phase = .recording(.handsFree)
            return [.showMode(.handsFree)]
        }

        phase = .awaitingSecondTap
        return [.scheduleSecondTapTimeout(max(0, doubleTapWindow - elapsed))]
    }

    mutating func secondTapWindowExpired() -> [DictationAction] {
        guard phase == .awaitingSecondTap else { return [] }
        phase = .transcribing
        return [.finishAndTranscribe]
    }

    mutating func forceStop() -> [DictationAction] {
        guard phase.isCapturingAudio else { return [] }
        phase = .transcribing
        return [.cancelSecondTapTimeout, .finishAndTranscribe]
    }

    mutating func cancel() -> [DictationAction] {
        guard phase != .idle else { return [] }
        phase = .idle
        firstPressTime = nil
        return [.cancelEverything]
    }

    mutating func processingCompleted() {
        phase = .idle
        firstPressTime = nil
    }
}
