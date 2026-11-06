import AppKit
import CoreGraphics
import Foundation

enum HotkeyError: LocalizedError {
    case unsupportedKey(String)
    case unsupportedModifier(String)
    case modifierRequired
    case eventTapUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedKey(let key):
            return "Unsupported hotkey key \"\(key)\". See README.md for supported names."
        case .unsupportedModifier(let modifier):
            return "Unsupported hotkey modifier \"\(modifier)\"."
        case .modifierRequired:
            return "Non-fn hotkeys require at least one modifier so normal typing is not swallowed."
        case .eventTapUnavailable:
            return "The global hotkey could not start. Grant LocalFlow Accessibility permission, then reload settings."
        }
    }
}

struct HotkeyDefinition {
    let keyCode: CGKeyCode
    let requiredFlags: CGEventFlags
    let isFunctionKey: Bool

    init(settings: HotkeySettings) throws {
        let normalizedKey = settings.key.lowercased()
        if normalizedKey == "fn" || normalizedKey == "function" {
            keyCode = 63
            requiredFlags = []
            isFunctionKey = true
            return
        }

        guard let code = Self.keyCodes[normalizedKey] else {
            throw HotkeyError.unsupportedKey(settings.key)
        }
        var flags: CGEventFlags = []
        for rawModifier in settings.modifiers {
            switch rawModifier.lowercased() {
            case "command", "cmd": flags.insert(.maskCommand)
            case "control", "ctrl": flags.insert(.maskControl)
            case "option", "alt": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            default: throw HotkeyError.unsupportedModifier(rawModifier)
            }
        }
        guard !flags.isEmpty || Self.standaloneKeys.contains(normalizedKey) else {
            throw HotkeyError.modifierRequired
        }
        keyCode = code
        requiredFlags = flags
        isFunctionKey = false
    }

    func matchesKeyDown(type: CGEventType, event: CGEvent) -> Bool {
        if isFunctionKey {
            return type == .flagsChanged
                && event.getIntegerValueField(.keyboardEventKeycode) == Int64(keyCode)
                && event.flags.contains(.maskSecondaryFn)
        }
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(keyCode) else { return false }
        return relevantFlags(event.flags) == requiredFlags
    }

    func matchesKeyUp(type: CGEventType, event: CGEvent) -> Bool {
        if isFunctionKey {
            return type == .flagsChanged
                && event.getIntegerValueField(.keyboardEventKeycode) == Int64(keyCode)
                && !event.flags.contains(.maskSecondaryFn)
        }
        return type == .keyUp && event.getIntegerValueField(.keyboardEventKeycode) == Int64(keyCode)
    }

    private func relevantFlags(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
        "backspace": 51,
        "f13": 105, "f14": 107, "f15": 113, "f16": 106,
        "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "left": 123, "right": 124,
        "down": 125, "up": 126
    ]

    private static let standaloneKeys: Set<String> = [
        "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20"
    ]
}

final class HotkeyMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var definition: HotkeyDefinition?
    private var keyIsDown = false
    private var otherKeyEvents = 0
    private let onDown: (TimeInterval) -> Void
    private let onUp: (TimeInterval) -> Void
    /// While a recording is running, a bare Return (or keypad Enter) stops it, like a second hotkey tap.
    /// The key is swallowed so it never submits the half-written message.
    var isCapturing: () -> Bool = { false }
    var onStopKey: () -> Void = {}
    private var swallowStopKeyUp = false

    init(onDown: @escaping (TimeInterval) -> Void, onUp: @escaping (TimeInterval) -> Void) {
        self.onDown = onDown
        self.onUp = onUp
    }

    deinit { stop() }

    func start(settings: HotkeySettings) throws {
        stop()
        definition = try HotkeyDefinition(settings: settings)
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            definition = nil
            throw HotkeyError.eventTapUnavailable
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            definition = nil
            throw HotkeyError.eventTapUnavailable
        }
        DebugLog.write("hotkey tap started key=\(settings.key) modifiers=\(settings.modifiers) trusted=\(AXIsProcessTrusted())")
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        keyIsDown = false
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
        definition = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DebugLog.write("hotkey tap disabled by system (type=\(type.rawValue)); re-enabling")
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let definition else { return Unmanaged.passUnretained(event) }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if code == 36 || code == 76 {
            let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            if type == .keyDown && modifiers.isEmpty && isCapturing() {
                swallowStopKeyUp = true
                DebugLog.write("return pressed while recording; stopping")
                onStopKey()
                return nil
            }
            if type == .keyUp && swallowStopKeyUp {
                swallowStopKeyUp = false
                return nil
            }
        }
        otherKeyEvents += 1
        if [57, 63, 105, 106, 107, 113].contains(code) {
            DebugLog.write("key event type=\(type.rawValue) code=\(code) flags=\(String(event.flags.rawValue, radix: 16)) otherEventsSinceLast=\(otherKeyEvents - 1)")
            otherKeyEvents = 0
        }

        if definition.matchesKeyDown(type: type, event: event) {
            if !keyIsDown {
                keyIsDown = true
                onDown(ProcessInfo.processInfo.systemUptime)
            }
            return nil
        }
        if keyIsDown && definition.matchesKeyUp(type: type, event: event) {
            keyIsDown = false
            onUp(ProcessInfo.processInfo.systemUptime)
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}

final class EscapeMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let onEscape: () -> Void

    init(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
    }

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 && !event.isARepeat { self?.onEscape() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 && !event.isARepeat { self?.onEscape() }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}
