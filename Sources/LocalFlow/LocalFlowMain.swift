import AppKit

@main
enum LocalFlowMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        _ = delegate
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: ApplicationController?
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies of LocalFlow would both grab the dictation key. The newer build keeps running.
        let me = NSRunningApplication.current
        let myBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        if let id = Bundle.main.bundleIdentifier {
            for other in NSRunningApplication.runningApplications(withBundleIdentifier: id) where other.processIdentifier != me.processIdentifier {
                let otherBuild = other.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String }.flatMap(Int.init) ?? 0
                if otherBuild >= myBuild, let url = other.bundleURL {
                    DebugLog.write("another LocalFlow (build \(otherBuild)) is running; showing it and quitting this one (build \(myBuild))")
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    NSApplication.shared.terminate(nil)
                    return
                }
                DebugLog.write("quitting an older LocalFlow (build \(otherBuild)); this is build \(myBuild)")
                other.terminate()
            }
        }
        do {
            let controller = try ApplicationController(configStore: ConfigStore())
            self.controller = controller
            controller.start()
            // A plain `kill` skips applicationWillTerminate; stop the bundled servers then too.
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.controller?.shutdown() }
                exit(0)
            }
            source.resume()
            termSource = source
        } catch {
            let alert = NSAlert()
            alert.messageText = "LocalFlow could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    /// Opening LocalFlow again while it runs (Finder, Spotlight, Launchpad) shows its window,
    /// instead of doing nothing visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showSetup(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}
