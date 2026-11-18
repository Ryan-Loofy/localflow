import AppKit
import ApplicationServices

/// The text an edit by voice works on: what is selected in the front app, or, with nothing selected, the
/// dictation LocalFlow just pasted, selected again where it sits right before the cursor.
@MainActor
enum SelectionReader {
    /// The selected text, or the last dictation once it is selected again; nil when neither can be had.
    /// `lastInserted` is only used after checking it is the text right before the cursor.
    static func target(lastInserted: String?) async -> String? {
        await waitForModifierRelease()
        let state = accessibilityState()
        if let selected = state?.selected, !isBlank(selected) { return selected }
        // Where Accessibility fully reports the field and says nothing is selected, Command-C is skipped: it would
        // copy something else (a whole line in some editors). Elsewhere an empty answer is not trusted.
        let knownEmpty = state?.selected?.isEmpty == true && state?.caret != nil
        if !knownEmpty, let copied = await copySelection(), !isBlank(copied) { return copied }
        guard let lastInserted, !isBlank(lastInserted) else { return nil }
        if let state, let element = state.element, let range = rangeBeforeCaret(value: state.value, caret: state.caret, text: lastInserted),
           select(range, in: element) {
            return lastInserted
        }
        return await selectByKeyboard(lastInserted) ? lastInserted : nil
    }

    /// The range of `text` when it is exactly what sits before the caret in `value`, in UTF-16 units.
    nonisolated static func rangeBeforeCaret(value: String?, caret: Int?, text: String) -> NSRange? {
        guard let value, let caret else { return nil }
        let length = (text as NSString).length
        let full = value as NSString
        guard length > 0, caret >= length, caret <= full.length else { return nil }
        let range = NSRange(location: caret - length, length: length)
        return full.substring(with: range) == text ? range : nil
    }

    /// Two copies of the same text, ignoring whitespace an app may change on paste (line endings, a trailing space).
    nonisolated static func sameText(_ a: String, _ b: String) -> Bool {
        let squeeze = { (s: String) in s.components(separatedBy: .whitespacesAndNewlines).joined() }
        return !squeeze(a).isEmpty && squeeze(a) == squeeze(b)
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The edit shortcut holds Option; a synthesized key sent while it is still down can mean another command.
    private static func waitForModifierRelease() async {
        for _ in 0..<20 where CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private struct AccessibilityState {
        var element: AXUIElement?
        var selected: String?
        var value: String?
        var caret: Int?
    }

    /// What Accessibility says about the focused field. `selected` is "" when it reports an empty selection
    /// and nil when the app does not say.
    private static func accessibilityState() -> AccessibilityState? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var state = AccessibilityState(element: element)
        var selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success {
            state.selected = selected as? String
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success {
            state.value = value as? String
        }
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length == 0 { state.caret = range.location }
        }
        return state
    }

    private static func select(_ range: NSRange, in element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    /// For apps that hide their text from Accessibility: Shift-Left once per character, then Command-C to check
    /// the selection really is the last dictation. If it is not, Right puts the cursor back and nothing changes.
    private static func selectByKeyboard(_ text: String) async -> Bool {
        let count = text.count
        guard count <= 5_000 else { return false }
        for _ in 0..<count { press(123, flags: .maskShift) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        if let copied = await copySelection(), sameText(copied, text) { return true }
        press(124, flags: [])
        return false
    }

    private static func press(_ key: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot(pasteboard: pasteboard)
        let before = pasteboard.changeCount
        press(8, flags: .maskCommand)
        // Nothing selected leaves the clipboard as it was; give the app up to half a second to copy.
        for _ in 0..<10 where pasteboard.changeCount == before {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        snapshot.restore(to: pasteboard)
        return text
    }
}
