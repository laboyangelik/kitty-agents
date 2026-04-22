import SwiftUI
import AppKit
import Sparkle
import ServiceManagement
import Carbon.HIToolbox

@main
struct LilAgentsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: LilAgentsController?
    var statusItem: NSStatusItem?
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = LilAgentsController()
        controller?.start()
        setupMenuBar()
        setupGlobalHotkey()
    }

    private func setupGlobalHotkey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x6B636174) // 'kcat'
        hotKeyID.id = 1

        RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(cmdKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallApplicationEventHandler({ _, _, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.openChat() }
            return noErr
        }, 1, &eventSpec, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandlerRef)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.characters.forEach { $0.session?.terminate() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let char = controller?.characters.first else { return true }
        if !char.isManuallyVisible {
            char.greetAfterReopen()
            buildMenu()
        }
        return true
    }

    // MARK: - Menu Bar

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = catEmojiImage()
        }

        buildMenu()
    }

    private func catEmojiImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.setFillColor(NSColor.black.cgColor)

            // Left ear
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 1, y: 9))
            ctx.addLine(to: CGPoint(x: 4.5, y: 16))
            ctx.addLine(to: CGPoint(x: 8, y: 12))
            ctx.closePath()
            ctx.fillPath()

            // Right ear
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 17, y: 9))
            ctx.addLine(to: CGPoint(x: 13.5, y: 16))
            ctx.addLine(to: CGPoint(x: 10, y: 12))
            ctx.closePath()
            ctx.fillPath()

            // Head
            ctx.fillEllipse(in: CGRect(x: 2, y: 1, width: 14, height: 13))

            // Eyes — punched out
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: 5, y: 5.5, width: 2.8, height: 2.8))
            ctx.fillEllipse(in: CGRect(x: 10.2, y: 5.5, width: 2.8, height: 2.8))
            ctx.setBlendMode(.normal)

            return true
        }
        image.isTemplate = true
        return image
    }

    @discardableResult
    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let openChatItem = NSMenuItem(title: "Open Chat", action: #selector(openChat), keyEquivalent: "")
        menu.addItem(openChatItem)

        menu.addItem(NSMenuItem.separator())

        let catVisible = controller?.characters.first?.isManuallyVisible ?? true
        let showHideItem = NSMenuItem(
            title: catVisible ? "Hide Cat" : "Show Cat",
            action: #selector(toggleCatVisibility),
            keyEquivalent: ""
        )
        menu.addItem(showHideItem)

        menu.addItem(NSMenuItem.separator())

        let soundItem = NSMenuItem(title: "Sounds", action: #selector(toggleSounds(_:)), keyEquivalent: "")
        soundItem.state = WalkerCharacter.soundsEnabled ? .on : .off
        menu.addItem(soundItem)

        // Provider submenu (applies to all characters)
        let providerItem = NSMenuItem(title: "Provider", action: nil, keyEquivalent: "")
        let providerMenu = NSMenu()
        let currentProvider = controller?.characters.first?.provider ?? .claude
        for (i, provider) in AgentProvider.allCases.enumerated() {
            let item = NSMenuItem(title: provider.displayName, action: #selector(switchProvider(_:)), keyEquivalent: "")
            item.tag = i
            item.state = provider == currentProvider ? .on : .off
            if !provider.isAvailable {
                item.isEnabled = false
            }
            providerMenu.addItem(item)
        }
        providerMenu.addItem(NSMenuItem.separator())
        let gatewayItem = NSMenuItem(title: "Advanced Settings\u{2026}", action: #selector(openGatewaySettings), keyEquivalent: "")
        gatewayItem.tag = -1
        providerMenu.addItem(gatewayItem)

        providerItem.submenu = providerMenu
        menu.addItem(providerItem)

        // Cat color submenu
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        let catColors: [(display: String, anim: String)] = [
            ("Gray",    "gray"),
            ("Ungu",    "ungu"),
            ("Blue",    "Blue"),
            ("Calico",  "calico"),
            ("Black",   "Black"),
            ("White",   "white"),
            ("Orange",  "orange"),
        ]
        let currentColor = controller?.characters.first?.catColorAnimation ?? "gray"
        for (i, color) in catColors.enumerated() {
            let item = NSMenuItem(title: color.display, action: #selector(switchCatColor(_:)), keyEquivalent: "")
            item.tag = i
            item.state = color.anim == currentColor ? .on : .off
            colorMenu.addItem(item)
        }
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        // Display submenu
        let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        displayMenu.delegate = self
        let autoItem = NSMenuItem(title: "Auto (Main Display)", action: #selector(switchDisplay(_:)), keyEquivalent: "")
        autoItem.tag = -1
        autoItem.state = .on
        displayMenu.addItem(autoItem)
        displayMenu.addItem(NSMenuItem.separator())
        for (i, screen) in NSScreen.screens.enumerated() {
            let name = screen.localizedName
            let item = NSMenuItem(title: name, action: #selector(switchDisplay(_:)), keyEquivalent: "")
            item.tag = i
            item.state = .off
            displayMenu.addItem(item)
        }
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        menu.addItem(NSMenuItem.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.state = launchAtLoginEnabled() ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(NSMenuItem.separator())

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = updaterController
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
        return menu
    }

    @objc func openChat() {
        guard let char = controller?.characters.first else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !char.isIdleForPopover {
            char.openPopover()
        }
    }

    @objc func toggleCatVisibility() {
        guard let char = controller?.characters.first else { return }
        char.setManuallyVisible(!char.isManuallyVisible)
        buildMenu()
    }

    // MARK: - Menu Actions

    @objc func switchTheme(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx < PopoverTheme.allThemes.count else { return }
        PopoverTheme.current = PopoverTheme.allThemes[idx]

        if let themeMenu = sender.menu {
            for item in themeMenu.items {
                item.state = item.tag == idx ? .on : .off
            }
        }

        controller?.characters.forEach { char in
            let wasOpen = char.isIdleForPopover
            if wasOpen { char.popoverWindow?.orderOut(nil) }
            char.popoverWindow = nil
            char.terminalView = nil
            char.thinkingBubbleWindow = nil
            if wasOpen {
                char.createPopoverWindow()
                if let session = char.session, !session.history.isEmpty {
                    char.terminalView?.replayHistory(session.history)
                }
                char.updatePopoverPosition()
                char.popoverWindow?.orderFrontRegardless()
                char.popoverWindow?.makeKey()
                if let terminal = char.terminalView {
                    char.popoverWindow?.makeFirstResponder(terminal.inputField)
                }
            }
        }
    }

    @objc func switchProvider(_ sender: NSMenuItem) {
        let idx = sender.tag
        let allProviders = AgentProvider.allCases
        guard idx < allProviders.count else { return }
        let newProvider = allProviders[idx]

        controller?.characters.forEach { char in
            if char.provider == newProvider { return }
            char.provider = newProvider
            char.session?.terminate()
            char.session = nil
            char.popoverWindow?.orderOut(nil)
            char.popoverWindow = nil
            char.terminalView = nil
            char.thinkingBubbleWindow?.orderOut(nil)
            char.thinkingBubbleWindow = nil
        }

        if let providerMenu = sender.menu {
            for item in providerMenu.items {
                item.state = item.tag == idx ? .on : .off
            }
        }
    }

    @objc func switchCatColor(_ sender: NSMenuItem) {
        let catColors = ["gray", "ungu", "Blue", "calico", "Black", "white", "orange"]
        guard sender.tag < catColors.count else { return }
        let animName = catColors[sender.tag]
        controller?.characters.forEach { $0.applyCatColor(animName) }
        if let colorMenu = sender.menu {
            for item in colorMenu.items { item.state = item.tag == sender.tag ? .on : .off }
        }
    }

    @objc func switchCharacterSize(_ sender: NSMenuItem) {
        let idx = sender.tag
        let allSizes = CharacterSize.allCases
        guard idx < allSizes.count else { return }
        let newSize = allSizes[idx]

        controller?.characters.forEach { $0.size = newSize }

        if let sizeMenu = sender.menu {
            for item in sizeMenu.items {
                item.state = item.tag == idx ? .on : .off
            }
        }
    }

    @objc func switchDisplay(_ sender: NSMenuItem) {
        let idx = sender.tag
        controller?.pinnedScreenIndex = idx

        if let displayMenu = sender.menu {
            for item in displayMenu.items {
                item.state = item.tag == idx ? .on : .off
            }
        }
    }

    @objc func toggleChar1(_ sender: NSMenuItem) {
        guard let chars = controller?.characters, chars.count > 0 else { return }
        let char = chars[0]
        if char.isManuallyVisible {
            char.setManuallyVisible(false)
            sender.state = .off
        } else {
            char.setManuallyVisible(true)
            sender.state = .on
        }
    }

    @objc func toggleChar2(_ sender: NSMenuItem) {
        guard let chars = controller?.characters, chars.count > 1 else { return }
        let char = chars[1]
        if char.isManuallyVisible {
            char.setManuallyVisible(false)
            sender.state = .off
        } else {
            char.setManuallyVisible(true)
            sender.state = .on
        }
    }

    @objc func toggleSounds(_ sender: NSMenuItem) {
        WalkerCharacter.soundsEnabled.toggle()
        sender.state = WalkerCharacter.soundsEnabled ? .on : .off
    }

    @objc func openGatewaySettings() {
        OpenClawSession.showSettingsPanel { [weak self] in
            // If OpenClaw is the active provider, reconnect with new settings
            guard AgentProvider.current == .openclaw else { return }
            self?.controller?.characters.forEach { char in
                char.session?.terminate()
                char.session = nil
            }
        }
    }

    private func launchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    sender.state = .off
                } else {
                    try SMAppService.mainApp.register()
                    sender.state = .on
                }
            } catch {
                NSLog("Launch at login error: %@", "\(error)")
            }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.Extension")!)
        }
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {}
