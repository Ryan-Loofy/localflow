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

    private var bars: [String: NSProgressIndicator] = [:]
    private var modelLabels: [String: NSTextField] = [:]
    private let downloadButton = NSButton(title: "Download", target: nil, action: nil)
    private let downloadError = NSTextField(wrappingLabelWithString: "")
    private let micStatus = NSTextField(labelWithString: "")
    private let axStatus = NSTextField(labelWithString: "")
    private let inputStatus = NSTextField(labelWithString: "")
    private let keyPopup = NSPopUpButton()
    private let keyNote = NSTextField(wrappingLabelWithString: "")
    private let loginCheck = NSButton(checkboxWithTitle: "Open LocalFlow when I log in", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)

    var isDownloading: Bool { downloader != nil }

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
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
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
        stack.addArrangedSubview(permissionRow("Input Monitoring (for the key)", inputStatus, "Open Settings", #selector(openInputMonitoring)))

        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(heading("3. Pick your dictation key"))
        keyPopup.addItems(withTitles: ["Caps Lock", "fn (Globe)"])
        keyPopup.selectItem(at: owner.settings.hotkey.key == "fn" ? 1 : 0)
        keyPopup.target = self
        keyPopup.action = #selector(keyChanged)
        stack.addArrangedSubview(keyPopup)
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

        set(micStatus, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        set(axStatus, AXIsProcessTrusted())
        set(inputStatus, CGPreflightListenEventAccess())
        doneButton.isEnabled = allModels
    }

    private func set(_ field: NSTextField, _ granted: Bool) {
        field.stringValue = granted ? "Allowed" : "Not yet"
        field.textColor = granted ? .systemGreen : .secondaryLabelColor
    }

    private func updateKeyNote() {
        keyNote.stringValue = keyPopup.indexOfSelectedItem == 0
            ? "Caps Lock stops working as Caps Lock while LocalFlow is running."
            : "Also set System Settings > Keyboard > \"Press 🌐 key to\" to Do Nothing. Some keyboards (many Keychron and Logitech) never send fn to macOS: use Caps Lock there."
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

    @objc private func openInputMonitoring() {
        _ = CGRequestListenEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func keyChanged() {
        updateKeyNote()
        owner.setDictationKey(capsLock: keyPopup.indexOfSelectedItem == 0)
    }

    @objc private func done() {
        if loginCheck.state == .on, SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        window.close()
    }
}
