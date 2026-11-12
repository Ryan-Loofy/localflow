import AppKit

@MainActor
final class MenuBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private unowned let owner: ApplicationController

    init(owner: ApplicationController) {
        self.owner = owner
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "LocalFlow")
            button.image?.isTemplate = true
            button.toolTip = "LocalFlow"
        }
        refresh()
    }

    func refresh() {
        let menu = NSMenu()

        let status = NSMenuItem(title: owner.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let enabled = item("Enabled", action: #selector(ApplicationController.toggleEnabled(_:)))
        enabled.state = owner.settings.enabled ? .on : .off
        menu.addItem(enabled)

        let launch = item("Launch at Login", action: #selector(ApplicationController.toggleLaunchAtLogin(_:)))
        launch.state = owner.launchAtLoginEnabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())
        menu.addItem(item("Set Up LocalFlow...", action: #selector(ApplicationController.showSetup(_:))))
        menu.addItem(item("Open Settings File", action: #selector(ApplicationController.openSettingsFile(_:))))
        menu.addItem(item("Open .env File", action: #selector(ApplicationController.openEnvironmentFile(_:))))
        menu.addItem(item("Reload Settings", action: #selector(ApplicationController.reloadSettings(_:))))
        menu.addItem(item("Request Permissions", action: #selector(ApplicationController.requestPermissions(_:))))

        menu.addItem(.separator())
        let quit = item("Quit LocalFlow", action: #selector(ApplicationController.quit(_:)))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = owner
        return item
    }
}
