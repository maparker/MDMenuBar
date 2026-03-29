import AppKit
import WebKit

class PreviewPanel: NSPanel {

    private var webView: WKWebView!
    private var titleBar: NSView!
    private var fileLabel: NSTextField!
    private var handle: ResizeHandle!
    private var watchSource: DispatchSourceFileSystemObject?
    private var currentFilePath: String?
    private var globalClickMonitor: Any?

    private static let minWidth: CGFloat = 300
    private static let maxWidth: CGFloat = 1200
    private static let defaultWidth: CGFloat = 520
    private static let widthKey = "previewPanelWidth"

    private var panelWidth: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: Self.widthKey)
            return stored > 0 ? stored : Self.defaultWidth
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.widthKey)
        }
    }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        configure()
    }

    // MARK: - Setup

    private func configure() {
        styleMask = [.borderless, .nonactivatingPanel]
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        acceptsMouseMovedEvents = true  // required for sendEvent to receive .mouseMoved

        buildContentView()
    }

    private func buildContentView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true

        // Toolbar strip at top
        let bar = NSVisualEffectView()
        bar.material = .sidebar
        bar.blendingMode = .behindWindow
        bar.state = .active
        bar.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "MD Preview")
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        fileLabel = NSTextField(labelWithString: "No file selected")
        fileLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        fileLabel.textColor = .tertiaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.translatesAutoresizingMaskIntoConstraints = false

        let reloadBtn = makeToolbarButton(systemSymbol: "arrow.clockwise", action: #selector(reload))
        let openBtn   = makeToolbarButton(systemSymbol: "doc.badge.plus",  action: #selector(openFile))
        let closeBtn  = makeToolbarButton(systemSymbol: "xmark",            action: #selector(hidePanel))

        let btnStack = NSStackView(views: [openBtn, reloadBtn, closeBtn])
        btnStack.orientation = .horizontal
        btnStack.spacing = 8
        btnStack.translatesAutoresizingMaskIntoConstraints = false

        bar.addSubview(titleLabel)
        bar.addSubview(fileLabel)
        bar.addSubview(btnStack)

        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            fileLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            fileLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            fileLabel.trailingAnchor.constraint(lessThanOrEqualTo: btnStack.leadingAnchor, constant: -10),
            btnStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            btnStack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        // WebView
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Intercept all link clicks in JS — more reliable than WKNavigationDelegate
        // for file:// URLs, which WKWebView can block before the delegate fires.
        let linkScript = WKUserScript(source: """
            document.addEventListener('click', function(e) {
                var el = e.target;
                while (el && el.tagName !== 'A') { el = el.parentElement; }
                if (el && el.href) {
                    e.preventDefault();
                    window.webkit.messageHandlers.linkClicked.postMessage(el.href);
                }
            }, true);
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(linkScript)
        config.userContentController.add(self, name: "linkClicked")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground") // transparent bg, CSS handles it
        webView.navigationDelegate = self

        let scrollBg = NSVisualEffectView()
        scrollBg.material = .contentBackground
        scrollBg.blendingMode = .behindWindow
        scrollBg.state = .active
        scrollBg.translatesAutoresizingMaskIntoConstraints = false
        scrollBg.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: scrollBg.topAnchor),
            webView.bottomAnchor.constraint(equalTo: scrollBg.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: scrollBg.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: scrollBg.trailingAnchor),
        ])

        // Resize handle on the left edge — added before other views so we can
        // constrain scrollBg's leading edge to it, keeping WKWebView from
        // overlapping the strip (WKWebView resets the cursor over its own area).
        handle = ResizeHandle()
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.onDrag = { [weak self] delta in self?.resizeByDelta(delta) }

        // Background strip behind the handle so the left edge isn't transparent
        let handleBg = NSVisualEffectView()
        handleBg.material = .sidebar
        handleBg.blendingMode = .behindWindow
        handleBg.state = .active
        handleBg.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(handleBg)
        root.addSubview(bar)
        root.addSubview(sep)
        root.addSubview(scrollBg)
        root.addSubview(handle)   // on top so it receives mouse events
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // Handle and its background strip occupy the left 6pt
            handleBg.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            handleBg.topAnchor.constraint(equalTo: root.topAnchor),
            handleBg.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            handleBg.widthAnchor.constraint(equalToConstant: 6),
            handle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            handle.topAnchor.constraint(equalTo: root.topAnchor),
            handle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: 6),
            // All content starts at the handle's trailing edge
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: handle.trailingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sep.topAnchor.constraint(equalTo: bar.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: handle.trailingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollBg.topAnchor.constraint(equalTo: sep.bottomAnchor),
            scrollBg.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollBg.leadingAnchor.constraint(equalTo: handle.trailingAnchor),
            scrollBg.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        contentView = root
        titleBar = bar
    }

    private func makeToolbarButton(systemSymbol: String, action: Selector) -> NSButton {
        let btn = NSButton()
        btn.image = NSImage(systemSymbolName: systemSymbol, accessibilityDescription: nil)
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.contentTintColor = .secondaryLabelColor
        btn.action = action
        btn.target = self
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 22).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return btn
    }

    // MARK: - Show / Hide

    func showPanel(on screen: NSScreen? = nil) {
        // Use the provided screen (ideally the one containing the status item button),
        // falling back to the screen with the menu bar, then any available screen.
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let sf = screen.visibleFrame
        let w = min(panelWidth, sf.width * 0.9)
        let h = sf.height

        // Start off-screen to the right
        setFrame(NSRect(x: sf.maxX, y: sf.minY, width: w, height: h), display: false)
        makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(NSRect(x: sf.maxX - w, y: sf.minY, width: w, height: h), display: true)
        }

        // Monitor clicks outside panel to auto-hide
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }

    }

    // sendEvent() receives every event dispatched to the window — the same path
    // that delivers mouseDown/mouseDragged to the resize handle. Using it here
    // avoids all the uncertainty around tracking areas, local monitors, and
    // whether .accessory-policy apps receive mouseMoved through other channels.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .mouseMoved {
            // handle.frame is in the contentView (root) coordinate system,
            // which equals the window base coordinate system.
            // event.locationInWindow is also in window base coordinates.
            if handle.frame.contains(event.locationInWindow) {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        super.sendEvent(event)
    }

    @objc func hidePanel() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        NSCursor.arrow.set()

        // Slide back out to the right edge of whichever screen the panel is currently on
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main else {
            orderOut(nil); return
        }
        let target = NSRect(x: screen.visibleFrame.maxX, y: frame.minY, width: frame.width, height: frame.height)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            self?.orderOut(nil)
        }
    }

    func togglePanel(on screen: NSScreen? = nil) {
        if isVisible { hidePanel() } else { showPanel(on: screen) }
    }

    // MARK: - File loading

    func loadFile(_ path: String) {
        currentFilePath = path
        UserDefaults.standard.set(path, forKey: "lastFilePath")

        let name = URL(fileURLWithPath: path).lastPathComponent
        fileLabel.stringValue = name

        reloadContent()
        startWatching(path: path)
    }

    @objc func reload() {
        reloadContent()
    }

    private func reloadContent() {
        guard let path = currentFilePath,
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            loadPlaceholder()
            return
        }
        let html = MarkdownRenderer.render(content)
        webView.loadHTMLString(html, baseURL: URL(fileURLWithPath: path).deletingLastPathComponent())
    }

    private func loadPlaceholder() {
        let html = MarkdownRenderer.render("""
        # No file loaded

        Click **Open File** (or right-click the menu bar icon) to choose a Markdown file.

        **Keyboard shortcut:** ⌘⇧M to toggle this panel.
        """)
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - File watching

    private func startWatching(path: String) {
        watchSource?.cancel()
        watchSource = nil

        let fd = open(path, O_EVTONLY)
        guard fd != -1 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.reloadContent()
        }
        src.setCancelHandler {
            Darwin.close(fd)
        }
        src.resume()
        watchSource = src
    }

    // MARK: - Open file dialog

    @objc func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!, .plainText]
        panel.title = "Choose a Markdown file"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        // Float above the preview panel
        panel.level = .modalPanel
        panel.makeKeyAndOrderFront(nil)

        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.loadFile(url.path)
            }
        }
    }

    // MARK: - Restore last file

    func restoreLastFile() {
        if let path = UserDefaults.standard.string(forKey: "lastFilePath"),
           FileManager.default.fileExists(atPath: path) {
            loadFile(path)
        } else {
            loadPlaceholder()
        }
    }

    // MARK: - Resize

    private func resizeByDelta(_ delta: CGFloat) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main else { return }
        let newWidth = (frame.width - delta).clamped(to: Self.minWidth...min(Self.maxWidth, screen.visibleFrame.width * 0.9))
        let newX = screen.visibleFrame.maxX - newWidth
        setFrame(NSRect(x: newX, y: frame.minY, width: newWidth, height: frame.height), display: true)
        panelWidth = newWidth
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Escape or ⌘W closes the panel
        if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.characters == "w") {
            hidePanel()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - WKNavigationDelegate

extension PreviewPanel: WKNavigationDelegate {
    // JS handles all link clicks; this is a safety net to block any navigation
    // that slips through (e.g. middle-click, keyboard activation).
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard action.navigationType == .linkActivated, let url = action.request.url else {
            decisionHandler(.allow)   // initial HTML load — always allow
            return
        }
        routeURL(url)
        decisionHandler(.cancel)
    }
}

// MARK: - WKScriptMessageHandler

extension PreviewPanel: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "linkClicked",
              let urlString = message.body as? String,
              let url = URL(string: urlString) else { return }
        routeURL(url)
    }
}

// MARK: - Link routing

extension PreviewPanel {
    private func routeURL(_ url: URL) {
        if url.isFileURL {
            let ext = url.pathExtension.lowercased()
            if ext == "md" || ext == "markdown" {
                NSWorkspace.shared.open(url)  // opens in default .md editor
            }
            // other file:// URLs (images etc.) are already rendered inline — ignore
        } else {
            NSWorkspace.shared.open(url)      // http/https/mailto → default browser
        }
    }
}

// MARK: - ResizeHandle

/// A thin view on the left edge of the panel that handles drag-to-resize.
/// Cursor management is handled by PreviewPanel via a global event monitor,
/// since NSTrackingArea is unreliable for .accessory activation policy apps.
private class ResizeHandle: NSView {

    var onDrag: ((CGFloat) -> Void)?
    private var dragStartX: CGFloat = 0

    override func mouseDown(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        dragStartX = convert(event.locationInWindow, from: nil).x
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        let currentX = convert(event.locationInWindow, from: nil).x
        onDrag?(currentX - dragStartX)
        dragStartX = currentX
    }
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
