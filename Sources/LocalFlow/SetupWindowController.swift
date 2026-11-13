import AppKit
import ApplicationServices
import AVFoundation
import ServiceManagement

/// First-run window: downloads the models, walks through the three permissions,
/// and picks the dictation key. It can be reopened from the menu bar.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private unowned let owner: ApplicationController
    private let window: NSWindow
    private var models: [ModelFile]
    private var downloader: ModelDownloader?
    private var pollTimer: Timer?
    private var hasBeenShown = false
    private var micWasGranted = false
    private var axWasGranted = false
    private var permissionsKnown = false

    private var bars: [String: NSProgressIndicator] = [:]
    private var modelLabels: [String: NSTextField] = [:]
    private let downloadButton = NSButton(title: "Download", target: nil, action: nil)
    private let downloadError = NSTextField(wrappingLabelWithString: "")
    private let micStatus = NSTextField(labelWithString: "")
    private let axStatus = NSTextField(labelWithString: "")
    private let keyPopup = NSPopUpButton()
    private let keyNote = NSTextField(wrappingLabelWithString: "")
    private let recordButton = NSButton(title: "Record shortcut", target: nil, action: nil)
    private var recordMonitor: Any?
    private let axHint = NSTextField(wrappingLabelWithString: "")
    private let keyCap = NSTextField(labelWithString: "")
    private let readyLabel = NSTextField(wrappingLabelWithString: "")
    private let loginCheck = NSButton(checkboxWithTitle: "Open LocalFlow when I log in", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    var isDownloading: Bool { downloader != nil }
    var isVisible: Bool { window.isVisible }

    init(owner: ApplicationController, models: [ModelFile]) {
        self.owner = owner
        self.models = models
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Set Up LocalFlow"
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
    }

    func show() {
        refresh()
        if !hasBeenShown { window.center(); hasBeenShown = true }
        // A menu-bar app has no Dock icon, so a window behind System Settings is lost.
        // While this window is open, LocalFlow shows in the Dock and the app switcher.
        NSApp.setActivationPolicy(.regular)
        bringToFront()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        stopRecording()
        NSApp.setActivationPolicy(.accessory)
    }

    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: layout

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)

        stack.addArrangedSubview(heading("1. Download the models"))
        let total = models.reduce(Int64(0)) { $0 + $1.size }
        stack.addArrangedSubview(body(models.isEmpty
            ? "LocalFlow is set to use your own speech and cleanup servers, so there is nothing to download."
            : String(format: "LocalFlow downloads %.1f GB once from Hugging Face. After that, dictation runs entirely on this Mac.", Double(total) / 1e9)))
        for model in models {
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            let bar = NSProgressIndicator()
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.widthAnchor.constraint(equalToConstant: 472).isActive = true
            modelLabels[model.fileName] = label
            bars[model.fileName] = bar
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(bar)
        }
        downloadButton.target = self
        downloadButton.action = #selector(startDownload)
        downloadButton.bezelStyle = .rounded
        downloadError.textColor = .systemRed
        downloadError.font = .systemFont(ofSize: 12)
        downloadError.preferredMaxLayoutWidth = 472
        if !models.isEmpty {
            stack.addArrangedSubview(downloadButton)
            stack.addArrangedSubview(downloadError)
        }

        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(heading("2. Allow LocalFlow"))
        stack.addArrangedSubview(permissionRow("Microphone", micStatus, "Allow", #selector(allowMicrophone)))
        stack.addArrangedSubview(permissionRow("Accessibility (to paste)", axStatus, "Open Settings", #selector(openAccessibility)))
        stack.addArrangedSubview(body("When you switch on Accessibility in System Settings, this window comes back on its own."))
        axHint.font = .systemFont(ofSize: 11)
        axHint.textColor = .secondaryLabelColor
        axHint.preferredMaxLayoutWidth = 472
        axHint.stringValue = "Already switched on but this still says Not yet? An older copy of LocalFlow holds that switch. In System Settings, select LocalFlow, click the minus button, then click Open Settings here again."
        stack.addArrangedSubview(axHint)

        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(heading("3. Pick your dictation key"))
        keyPopup.addItems(withTitles: ["Caps Lock", "fn (Globe)", "Custom shortcut"])
        let current = owner.settings.hotkey
        keyPopup.selectItem(at: current.key == "fn" ? 1 : (owner.settings.mapCapsLock && current.key == "f13" && current.modifiers.isEmpty) ? 0 : 2)
        keyPopup.target = self
        keyPopup.action = #selector(keyChanged)
        recordButton.target = self
        recordButton.action = #selector(recordShortcut)
        recordButton.bezelStyle = .rounded
        keyCap.font = .systemFont(ofSize: 14, weight: .semibold)
        keyCap.alignment = .center
        keyCap.wantsLayer = true
        keyCap.layer?.cornerRadius = 6
        keyCap.layer?.borderWidth = 1.5
        keyCap.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        keyCap.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let keyRow = NSStackView(views: [keyPopup, keyCap, recordButton])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8
        stack.addArrangedSubview(keyRow)
        keyNote.font = .systemFont(ofSize: 11)
        keyNote.textColor = .secondaryLabelColor
        keyNote.preferredMaxLayoutWidth = 472
        stack.addArrangedSubview(keyNote)
        stack.addArrangedSubview(body("Tap the key, talk, then tap it again or press Return. The cleaned-up text is pasted where you are typing."))

        stack.addArrangedSubview(spacer())
        loginCheck.state = .on
        stack.addArrangedSubview(loginCheck)
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        readyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        readyLabel.preferredMaxLayoutWidth = 472
        stack.addArrangedSubview(readyLabel)
        stack.addArrangedSubview(doneButton)

        window.contentView = stack
        updateKeyNote()
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        return label
    }

    private func body(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 472
        return label
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: 4).isActive = true
        return view
    }

    private func permissionRow(_ title: String, _ status: NSTextField, _ buttonTitle: String, _ action: Selector) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 220).isActive = true
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let button = NSButton(title: buttonTitle, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        let row = NSStackView(views: [label, status, button])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // MARK: state

    private func refresh() {
        for model in models {
            let installed = ModelStore.isInstalled(model)
            let mb = Double(model.size) / 1e6
            let sizeText = mb > 1000 ? String(format: "%.1f GB", mb / 1000) : String(format: "%.0f MB", mb)
            if installed {
                modelLabels[model.fileName]?.stringValue = "\(model.title), \(sizeText): ready"
                bars[model.fileName]?.doubleValue = 1
            } else if !isDownloading {
                modelLabels[model.fileName]?.stringValue = "\(model.title), \(sizeText)"
            }
        }
        let allModels = models.allSatisfy(ModelStore.isInstalled)
        downloadButton.isHidden = allModels
        downloadButton.isEnabled = !isDownloading

        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        set(micStatus, mic)
        set(axStatus, ax)
        axHint.isHidden = ax
        // A permission just turned on in System Settings: come back to the front.
        if permissionsKnown, window.isVisible, (ax && !axWasGranted) || (mic && !micWasGranted) {
            DebugLog.write("setup: permission granted (microphone=\(mic) accessibility=\(ax)); bringing setup to front")
            bringToFront()
        }
        permissionsKnown = true
        micWasGranted = mic
        axWasGranted = ax
        doneButton.isEnabled = allModels && mic && ax
        if !allModels {
            setReady(false, "Not ready yet: download the models above.")
        } else if !mic || !ax {
            setReady(false, "Not ready yet: allow \(!mic && !ax ? "the Microphone and Accessibility" : !mic ? "the Microphone" : "Accessibility") above.")
        } else if recordMonitor != nil {
            setReady(false, "Recording your shortcut: press it now.")
        } else {
            setReady(true, "Ready. Press \(keyName) in any app, talk, and press it again.")
        }
    }

    private func setReady(_ ready: Bool, _ text: String) {
        readyLabel.stringValue = text
        readyLabel.textColor = ready ? .systemGreen : .systemOrange
    }

    private func showKeyCap(recording: Bool) {
        keyCap.stringValue = recording ? "Press keys…" : keyName
        keyCap.textColor = recording ? .systemOrange : .labelColor
        keyCap.layer?.borderColor = (recording ? NSColor.systemOrange : NSColor.separatorColor).cgColor
        keyCap.layer?.backgroundColor = (recording ? NSColor.systemOrange.withAlphaComponent(0.08) : NSColor.controlBackgroundColor).cgColor
    }

    private func set(_ field: NSTextField, _ granted: Bool) {
        field.stringValue = granted ? "Allowed" : "Not yet"
        field.textColor = granted ? .systemGreen : .secondaryLabelColor
    }

    private var keyName: String {
        HotkeyDefinition.displayName(owner.settings.hotkey, capsLock: owner.settings.mapCapsLock)
    }

    private func updateKeyNote() {
        recordButton.isHidden = keyPopup.indexOfSelectedItem != 2
        showKeyCap(recording: false)
        refresh()
        switch keyPopup.indexOfSelectedItem {
        case 0:
            keyNote.stringValue = "Caps Lock stops working as Caps Lock while LocalFlow is running."
        case 1:
            keyNote.stringValue = "Also set System Settings > Keyboard > \"Press 🌐 key to\" to Do Nothing. Some keyboards (many Keychron and Logitech) never send fn to macOS: use Caps Lock there."
        default:
            let isCustom = !(owner.settings.hotkey.key == "fn" || (owner.settings.mapCapsLock && owner.settings.hotkey.key == "f13" && owner.settings.hotkey.modifiers.isEmpty))
            keyNote.stringValue = isCustom
                ? "Saved: \(keyName) is your dictation key. Click Record shortcut to change it."
                    + (owner.settings.hotkey.key.hasPrefix("left_command") || owner.settings.hotkey.key.hasPrefix("left_control")
                        ? " \(keyName) is part of everyday shortcuts like ⌘C, so a right-hand key such as Right ⌥ works better." : "")
                : "Click Record shortcut, then press a combination such as ⌥ Space or ⌃ ⇧ D, or one modifier key on its own such as Right ⌥. A key used on its own stops doing its normal job while LocalFlow runs."
        }
    }

    // MARK: actions

    @objc private func startDownload() {
        downloadError.stringValue = ""
        do {
            try ModelDownloader.checkSpace(for: models)
        } catch {
            downloadError.stringValue = error.localizedDescription
            return
        }
        let pending = models.filter { !ModelStore.isInstalled($0) }
        Task { @MainActor in
            for model in pending {
                let label = modelLabels[model.fileName]
                let bar = bars[model.fileName]
                let downloader = ModelDownloader { fraction in
                    DispatchQueue.main.async {
                        bar?.doubleValue = fraction
                        label?.stringValue = "\(model.title): downloading \(Int(fraction * 100))%"
                    }
                }
                self.downloader = downloader
                refresh()
                do {
                    try await downloader.download(model)
                    label?.stringValue = "\(model.title): checking"
                } catch {
                    self.downloader = nil
                    downloadError.stringValue = error.localizedDescription
                    DebugLog.write("model download failed: \(model.fileName): \(error.localizedDescription)")
                    refresh()
                    return
                }
            }
            self.downloader = nil
            refresh()
            owner.modelsChanged()
        }
    }

    @objc private func allowMicrophone() {
        Task { _ = await AudioRecorder.requestPermission() }
    }

    @objc private func openAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func keyChanged() {
        stopRecording()
        if keyPopup.indexOfSelectedItem < 2 {
            owner.setDictationKey(capsLock: keyPopup.indexOfSelectedItem == 0)
        }
        updateKeyNote()
        if keyPopup.indexOfSelectedItem == 2 { recordShortcut() }
    }

    private var pendingSoloModifier: CGKeyCode?

    @objc private func recordShortcut() {
        if recordMonitor != nil {   // the button reads Cancel while recording
            stopRecording()
            updateKeyNote()
            return
        }
        stopRecording()
        recordButton.title = "Cancel"
        showKeyCap(recording: true)
        keyNote.stringValue = "Press the keys now: a combination such as ⌥ Space, or one modifier key on its own such as Right ⌥. Escape cancels."
        bringToFront()
        DebugLog.write("shortcut recorder: listening (app active=\(NSApp.isActive) window key=\(window.isKeyWindow))")
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.recorderSaw(event) }
            return nil
        }
        refresh()
    }

    private func recorderSaw(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        DebugLog.write("shortcut recorder: \(event.type == .keyDown ? "keyDown" : "flagsChanged") code=\(event.keyCode) flags=\(flags.rawValue)")
        if event.type == .keyDown {
            pendingSoloModifier = nil
            recorded(event)
            return
        }
        // flagsChanged: a modifier went down or up. Any other key in between means a combination.
        let code = CGKeyCode(event.keyCode)
        if let pending = pendingSoloModifier, pending != code { pendingSoloModifier = nil }
        guard let name = HotkeyDefinition.soloModifierName(for: code),
              let (_, flag) = HotkeyDefinition.soloModifierKeys[name] else { return }
        let isDown = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).contains(flag)
        if isDown {
            pendingSoloModifier = flags.subtracting(NSEvent.ModifierFlags(rawValue: UInt(flag.rawValue))).isEmpty ? code : nil
        } else if pendingSoloModifier == code {
            pendingSoloModifier = nil
            stopRecording()
            let hotkey = HotkeySettings(key: name, modifiers: [])
            owner.setDictationKey(hotkey, mapCapsLock: false)
            DebugLog.write("shortcut recorder: saved \(name)")
            updateKeyNote()
        }
    }

    private func recorded(_ event: NSEvent) {
        stopRecording()
        if event.keyCode == 53 { updateKeyNote(); return }   // Escape
        guard let name = HotkeyDefinition.keyName(for: CGKeyCode(event.keyCode)) else {
            DebugLog.write("shortcut recorder: key code \(event.keyCode) is not supported")
            keyNote.stringValue = "LocalFlow can't use that key. Try a letter, number, Space, or F13 to F20 with ⌘ ⌥ ⌃ or ⇧, or one modifier key on its own. Click Record shortcut to try again."
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: [String] = []
        if flags.contains(.control) { modifiers.append("control") }
        if flags.contains(.option) { modifiers.append("option") }
        if flags.contains(.shift) { modifiers.append("shift") }
        if flags.contains(.command) { modifiers.append("command") }
        let hotkey = HotkeySettings(key: name, modifiers: modifiers)
        do {
            _ = try HotkeyDefinition(settings: hotkey)
        } catch {
            DebugLog.write("shortcut recorder: \(name) \(modifiers) rejected: \(error.localizedDescription)")
            keyNote.stringValue = "Add ⌘, ⌥, ⌃ or ⇧ to that key, so normal typing still works. Click Record shortcut to try again."
            return
        }
        // Caps Lock reaches LocalFlow as F13 while the Caps Lock mapping is on: that press means Caps Lock.
        if name == "f13", modifiers.isEmpty, owner.settings.mapCapsLock {
            keyPopup.selectItem(at: 0)
            owner.setDictationKey(capsLock: true)
            updateKeyNote()
            return
        }
        owner.setDictationKey(hotkey, mapCapsLock: false)
        DebugLog.write("shortcut recorder: saved \(name) \(modifiers)")
        updateKeyNote()
    }

    private func stopRecording() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
        pendingSoloModifier = nil
        recordButton.title = "Record shortcut"
    }

    @objc private func done() {
        if loginCheck.state == .on, SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        window.close()
        let alert = NSAlert()
        alert.messageText = "LocalFlow is ready"
        alert.informativeText = "It lives in the menu bar at the top right of your screen (the waveform icon), not in the Dock. Press \(keyName) in any app, talk, and press it again. To change settings later, open LocalFlow again or click the menu-bar icon."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
