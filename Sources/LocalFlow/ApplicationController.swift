import AppKit
import ApplicationServices
import AVFoundation
import ServiceManagement

@MainActor
final class ApplicationController: NSObject {
    let configStore: ConfigStore
    private(set) var settings: AppSettings
    private let pill = FloatingPillController()
    private let servers = BundledServers()
    private var setupWindow: SetupWindowController?
    private var lastError: String?

    private lazy var coordinator: DictationCoordinator = {
        let coordinator = DictationCoordinator(
            settings: settings,
            pill: pill,
            environmentProvider: { [weak self] in
                try self?.configStore.loadEnvironment() ?? [:]
            }
        )
        coordinator.onPhaseChanged = { [weak self] phase in
            if phase != .idle { self?.lastError = nil }
            self?.menuBar.refresh()
        }
        coordinator.onError = { [weak self] message in
            self?.lastError = message
            self?.menuBar.refresh()
        }
        return coordinator
    }()

    private lazy var hotkeyMonitor = HotkeyMonitor(
        onDown: { [weak self] time in self?.coordinator.hotkeyDown(at: time) },
        onUp: { [weak self] time in self?.coordinator.hotkeyUp(at: time) }
    )
    private lazy var escapeMonitor = EscapeMonitor { [weak self] in self?.coordinator.cancel() }
    private lazy var menuBar = MenuBarController(owner: self)

    var statusText: String {
        if let lastError { return "Error: \(lastError)" }
        if !settings.enabled { return "LocalFlow is off" }
        if setupWindow?.isDownloading == true { return "Downloading models..." }
        if !missingModels.isEmpty { return "Finish setup to start dictating" }
        return "LocalFlow is ready"
    }

    private var environment: [String: String] {
        (try? configStore.loadEnvironment()) ?? [:]
    }

    private var missingModels: [ModelFile] {
        BundledServers.neededModels(settings, environment: environment).filter { !ModelStore.isInstalled($0) }
    }

    var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    init(configStore: ConfigStore) throws {
        self.configStore = configStore
        settings = try configStore.load()
        super.init()
    }

    func start() {
        DebugLog.write("LocalFlow started, accessibility trusted=\(AXIsProcessTrusted()) listenAccess=\(CGPreflightListenEventAccess())")
        _ = coordinator
        _ = menuBar
        hotkeyMonitor.isCapturing = { [weak self] in self?.coordinator.isCapturingAudio ?? false }
        hotkeyMonitor.onStopKey = { [weak self] in self?.coordinator.stopKeyPressed() }
        escapeMonitor.start()
        applyCapsLockMapping()
        applyHotkeyState()
        if BundledServers.isBundled && (!missingModels.isEmpty || !AXIsProcessTrusted()) {
            showSetup(nil)
        } else {
            promptForAccessibility()
            Task { _ = await AudioRecorder.requestPermission() }
        }
        startServers()
    }

    @objc func showSetup(_ sender: Any?) {
        if setupWindow == nil {
            setupWindow = SetupWindowController(owner: self, models: BundledServers.neededModels(settings, environment: environment))
        }
        setupWindow?.show()
    }

    /// Called by the setup window when a download finishes.
    func modelsChanged() {
        startServers()
        menuBar.refresh()
    }

    func setDictationKey(capsLock: Bool) {
        settings.mapCapsLock = capsLock
        settings.hotkey = HotkeySettings(key: capsLock ? "f13" : "fn", modifiers: [])
        saveSettings()
        coordinator.update(settings: settings)
        applyCapsLockMapping(clearWhenOff: true)
        applyHotkeyState()
        menuBar.refresh()
    }

    private func startServers() {
        let settings = settings
        let environment = environment
        Task { await servers.startNeeded(settings: settings, environment: environment) }
    }

    /// Caps Lock (HID 0x39) becomes F13 (0x68) until logout; LocalFlow re-applies it at each launch.
    private func applyCapsLockMapping(clearWhenOff: Bool = false) {
        guard settings.mapCapsLock || clearWhenOff else { return }
        let mapping = settings.mapCapsLock
            ? #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x700000068}]}"#
            : #"{"UserKeyMapping":[]}"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", mapping]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            DebugLog.write("hidutil failed: \(error.localizedDescription)")
        }
    }

    @objc func toggleEnabled(_ sender: Any?) {
        settings.enabled.toggle()
        lastError = nil
        saveSettings()
        coordinator.update(settings: settings)
        applyHotkeyState()
        menuBar.refresh()
    }

    @objc func toggleLaunchAtLogin(_ sender: Any?) {
        do {
            if launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            lastError = nil
        } catch {
            let message = "Launch at login: \(error.localizedDescription)"
            lastError = message
            pill.show(.error(message))
        }
        menuBar.refresh()
    }

    @objc func openSettingsFile(_ sender: Any?) {
        NSWorkspace.shared.open(configStore.settingsURL)
    }

    @objc func openEnvironmentFile(_ sender: Any?) {
        NSWorkspace.shared.open(configStore.environmentURL)
    }

    @objc func reloadSettings(_ sender: Any?) {
        do {
            settings = try configStore.load()
            lastError = nil
            coordinator.update(settings: settings)
            applyCapsLockMapping()
            applyHotkeyState()
            startServers()
        } catch {
            let message = "Settings: \(error.localizedDescription)"
            lastError = message
            pill.show(.error(message))
        }
        menuBar.refresh()
    }

    @objc func requestPermissions(_ sender: Any?) {
        promptForAccessibility()
        _ = CGRequestListenEventAccess()
        Task { _ = await AudioRecorder.requestPermission() }
    }

    @objc func quit(_ sender: Any?) {
        shutdown()
        NSApplication.shared.terminate(nil)
    }

    func shutdown() {
        servers.stopAll()
        coordinator.cancel()
        hotkeyMonitor.stop()
        escapeMonitor.stop()
    }

    private func applyHotkeyState() {
        hotkeyMonitor.stop()
        guard settings.enabled else { return }
        do {
            try hotkeyMonitor.start(settings: settings.hotkey)
            lastError = nil
        } catch {
            DebugLog.write("hotkey start failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            pill.show(.error(error.localizedDescription))
            retryHotkeyWhenTrusted()
        }
    }

    /// After a rebuild macOS drops Accessibility. Poll until it is granted again and start
    /// the hotkey then, so re-approving in System Settings is enough without a restart.
    private var trustRetryTimer: Timer?

    private func retryHotkeyWhenTrusted() {
        guard trustRetryTimer == nil else { return }
        trustRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            MainActor.assumeIsolated {
                guard let self else { return }
                self.trustRetryTimer = nil
                DebugLog.write("accessibility granted; starting hotkey")
                self.applyHotkeyState()
                self.pill.hide()
                self.menuBar.refresh()
            }
        }
    }

    private func saveSettings() {
        do {
            try configStore.save(settings)
        } catch {
            let message = "Could not save settings: \(error.localizedDescription)"
            lastError = message
            pill.show(.error(message))
        }
    }

    private func promptForAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }
}
