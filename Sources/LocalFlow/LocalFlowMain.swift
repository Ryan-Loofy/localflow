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

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let controller = try ApplicationController(configStore: ConfigStore())
            self.controller = controller
            controller.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "LocalFlow could not start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}
