import AppKit
import CoreGraphics
import Foundation

private struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { values[type] = data }
            }
            return values
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !restoredItems.isEmpty { pasteboard.writeObjects(restoredItems) }
    }
}

enum TextInsertionError: LocalizedError {
    case pasteboardWriteFailed
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .pasteboardWriteFailed:
            return "Could not write the transcript to the clipboard."
        case .eventCreationFailed:
            return "Could not synthesize Command-V. Check Accessibility permission."
        }
    }
}

@MainActor
final class TextInserter {
    func insert(_ text: String, restorePreviousClipboard: Bool, restoreDelay: TimeInterval) async throws {
        let pasteboard = NSPasteboard.general
        let snapshot = restorePreviousClipboard ? ClipboardSnapshot(pasteboard: pasteboard) : nil
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TextInsertionError.pasteboardWriteFailed
        }

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw TextInsertionError.eventCreationFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        if let snapshot {
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, restoreDelay) * 1_000_000_000))
            snapshot.restore(to: pasteboard)
        }
    }
}
