import AppKit
import Carbon.HIToolbox

// Global reference used by the Carbon hotkey C-callback (closures can't capture in @convention(c))
private var _sharedDelegate: AppDelegate?

// Carbon event handler — must be a free function to satisfy EventHandlerUPP
private func carbonHotKeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async { _sharedDelegate?.togglePanel() }
    return noErr
}

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var panel: PreviewPanel!
    private var hotKeyRef: EventHotKeyRef?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        _sharedDelegate = self

        panel = PreviewPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.restoreLastFile()

        setupStatusItem()
        setupHotKey()
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.text.magnifyingglass",
                                   accessibilityDescription: "Markdown Preview")
            button.imageScaling = .scaleProportionallyDown
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    // The screen that contains the status item button — used to place the panel
    // on the correct display in multi-monitor setups.
    private var statusItemScreen: NSScreen? {
        guard let buttonWindow = statusItem.button?.window else { return NSScreen.main }
        return NSScreen.screens.first { $0.frame.contains(buttonWindow.frame.origin) } ?? NSScreen.main
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open File…", action: #selector(openFile),   keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Reload",     action: #selector(reloadFile), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit",       action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // Remove so left-click still toggles
    }

    // MARK: - Panel toggling

    @objc func togglePanel() {
        panel.togglePanel(on: statusItemScreen)
    }

    @objc private func openFile() {
        if !panel.isVisible { panel.showPanel() }
        panel.openFile()
    }

    @objc private func reloadFile() {
        panel.reload()
    }

    // MARK: - Global hotkey (⌘⇧M) via Carbon

    private func setupHotKey() {
        // Key code 46 = 'm'
        let keyCode: UInt32 = 46
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        let hotKeyID = EventHotKeyID(signature: 0x4d444d42 /* "MDMB" */, id: 1)

        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // InstallApplicationEventHandler is a macro — call InstallEventHandler directly
        InstallEventHandler(GetApplicationEventTarget(), carbonHotKeyHandler, 1, &eventSpec,
                            nil, nil)
    }
}
