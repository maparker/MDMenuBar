import AppKit
import WebKit

class PreviewPanel: NSPanel {

    override var canBecomeKey: Bool { true }

    private var webView: WKWebView!
    private var titleBar: NSView!
    private var fileLabel: NSTextField!
    private var watchSource: DispatchSourceFileSystemObject?
    private var currentFilePath: String?
    private var globalClickMonitor: Any?

    private var tabControl: NSSegmentedControl!
    private var previewControls: NSView!
    private var scratchControls: NSView!
    private var previewContent: NSView!
    private var scratchView: ScratchView!
    private var scratchFileLabel: NSTextField!
    private var pinButton: NSButton!
    private var isPinned = false

    private static let minWidth: CGFloat = 300
    private static let maxWidth: CGFloat = 1200
    private static let defaultWidth: CGFloat = 520
    private static let widthKey = "previewPanelWidth"
    private static let handleWidth: CGFloat = 8

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
        buildContentView()
    }

    private func buildContentView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true

        // MARK: Title bar

        let bar = NSVisualEffectView()
        bar.material = .sidebar
        bar.blendingMode = .behindWindow
        bar.state = .active
        bar.translatesAutoresizingMaskIntoConstraints = false

        let grip = DragGripView()
        grip.onDrag = { [weak self] delta in self?.resizeByDelta(delta) }
        grip.translatesAutoresizingMaskIntoConstraints = false

        // Tab switcher
        tabControl = NSSegmentedControl(labels: ["Preview", "Scratch"],
                                        trackingMode: .selectOne,
                                        target: self,
                                        action: #selector(tabChanged))
        tabControl.selectedSegment = 0
        tabControl.translatesAutoresizingMaskIntoConstraints = false

        pinButton = makeToolbarButton(systemSymbol: "pin", action: #selector(togglePin))
        pinButton.contentTintColor = .tertiaryLabelColor

        let closeBtn = makeToolbarButton(systemSymbol: "xmark", action: #selector(hidePanel))

        // Preview-tab controls
        fileLabel = NSTextField(labelWithString: "No file selected")
        fileLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        fileLabel.textColor = .tertiaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.translatesAutoresizingMaskIntoConstraints = false

        let openBtn   = makeToolbarButton(systemSymbol: "doc.badge.plus",  action: #selector(openFile))
        let reloadBtn = makeToolbarButton(systemSymbol: "arrow.clockwise", action: #selector(reload))
        previewControls = NSStackView(views: [fileLabel, openBtn, reloadBtn])
        (previewControls as! NSStackView).orientation = .horizontal
        (previewControls as! NSStackView).spacing = 8
        previewControls.translatesAutoresizingMaskIntoConstraints = false

        // Scratch-tab controls
        scratchFileLabel = NSTextField(labelWithString: "No scratch folder")
        scratchFileLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        scratchFileLabel.textColor = .tertiaryLabelColor
        scratchFileLabel.lineBreakMode = .byTruncatingMiddle
        scratchFileLabel.translatesAutoresizingMaskIntoConstraints = false

        let chooseBtn = makeToolbarButton(systemSymbol: "folder.badge.plus", action: #selector(chooseScratchFolder))
        scratchControls = NSStackView(views: [scratchFileLabel, chooseBtn])
        (scratchControls as! NSStackView).orientation = .horizontal
        (scratchControls as! NSStackView).spacing = 8
        scratchControls.translatesAutoresizingMaskIntoConstraints = false
        scratchControls.isHidden = true

        bar.addSubview(grip)
        bar.addSubview(tabControl)
        bar.addSubview(previewControls)
        bar.addSubview(scratchControls)
        bar.addSubview(pinButton)
        bar.addSubview(closeBtn)

        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 44),

            grip.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            grip.topAnchor.constraint(equalTo: bar.topAnchor),
            grip.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            grip.widthAnchor.constraint(equalToConstant: 16),

            tabControl.leadingAnchor.constraint(equalTo: grip.trailingAnchor, constant: 6),
            tabControl.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            previewControls.leadingAnchor.constraint(equalTo: tabControl.trailingAnchor, constant: 10),
            previewControls.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            previewControls.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -10),

            scratchControls.leadingAnchor.constraint(equalTo: tabControl.trailingAnchor, constant: 10),
            scratchControls.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            scratchControls.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -10),

            pinButton.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -4),
            pinButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            closeBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        // MARK: Separator

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        // MARK: Preview content

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let linkScript = WKUserScript(source: """
            (function() {
                document.addEventListener('click', function(e) {
                    var el = e.target;
                    while (el && el.tagName !== 'A') { el = el.parentElement; }
                    if (el && el.href) {
                        e.preventDefault();
                        window.webkit.messageHandlers.linkClicked.postMessage(el.href);
                    }
                }, true);
            })();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(linkScript)
        config.userContentController.add(self, name: "linkClicked")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self

        let edgeHandle = ResizeEdgeView()
        edgeHandle.onDrag = { [weak self] delta in self?.resizeByDelta(delta) }
        edgeHandle.translatesAutoresizingMaskIntoConstraints = false

        let handleBg = NSVisualEffectView()
        handleBg.material = .contentBackground
        handleBg.blendingMode = .behindWindow
        handleBg.state = .active
        handleBg.translatesAutoresizingMaskIntoConstraints = false

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

        previewContent = NSView()
        previewContent.translatesAutoresizingMaskIntoConstraints = false
        previewContent.addSubview(handleBg)
        previewContent.addSubview(scrollBg)
        previewContent.addSubview(edgeHandle)
        NSLayoutConstraint.activate([
            handleBg.topAnchor.constraint(equalTo: previewContent.topAnchor),
            handleBg.bottomAnchor.constraint(equalTo: previewContent.bottomAnchor),
            handleBg.leadingAnchor.constraint(equalTo: previewContent.leadingAnchor),
            handleBg.widthAnchor.constraint(equalToConstant: Self.handleWidth),

            edgeHandle.topAnchor.constraint(equalTo: previewContent.topAnchor),
            edgeHandle.bottomAnchor.constraint(equalTo: previewContent.bottomAnchor),
            edgeHandle.leadingAnchor.constraint(equalTo: previewContent.leadingAnchor),
            edgeHandle.widthAnchor.constraint(equalToConstant: Self.handleWidth),

            scrollBg.topAnchor.constraint(equalTo: previewContent.topAnchor),
            scrollBg.bottomAnchor.constraint(equalTo: previewContent.bottomAnchor),
            scrollBg.leadingAnchor.constraint(equalTo: handleBg.trailingAnchor),
            scrollBg.trailingAnchor.constraint(equalTo: previewContent.trailingAnchor),
        ])

        // MARK: Scratch content

        scratchView = ScratchView()
        scratchView.translatesAutoresizingMaskIntoConstraints = false
        scratchView.isHidden = true
        scratchView.onFolderChange = { [weak self] path in
            self?.updateScratchLabel(path: path)
        }
        if let path = scratchView.folderPath {
            updateScratchLabel(path: path)
        }

        // MARK: Assemble

        root.addSubview(bar)
        root.addSubview(sep)
        root.addSubview(previewContent)
        root.addSubview(scratchView)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            sep.topAnchor.constraint(equalTo: bar.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            previewContent.topAnchor.constraint(equalTo: sep.bottomAnchor),
            previewContent.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            previewContent.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            previewContent.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scratchView.topAnchor.constraint(equalTo: sep.bottomAnchor),
            scratchView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scratchView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scratchView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        contentView = root
        titleBar = bar
    }

    @objc private func togglePin() {
        isPinned.toggle()
        pinButton.contentTintColor = isPinned ? .controlAccentColor : .tertiaryLabelColor
        pinButton.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin",
                                   accessibilityDescription: nil)
        if isPinned {
            if let monitor = globalClickMonitor {
                NSEvent.removeMonitor(monitor)
                globalClickMonitor = nil
            }
        } else if isVisible {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hidePanel()
            }
        }
    }

    @objc private func tabChanged() {
        let isPreview = tabControl.selectedSegment == 0
        previewControls.isHidden = !isPreview
        scratchControls.isHidden = isPreview
        previewContent.isHidden = !isPreview
        scratchView.isHidden = isPreview
        if !isPreview { scratchView.reload(); scratchView.focusTextView() }
    }

    @objc private func chooseScratchFolder() {
        scratchView.chooseScratchFolder()
    }

    private func updateScratchLabel(path: String) {
        scratchFileLabel.stringValue = URL(fileURLWithPath: path).lastPathComponent + "/"
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
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let sf = screen.visibleFrame
        let w = min(panelWidth, sf.width * 0.9)
        let h = sf.height

        setFrame(NSRect(x: sf.maxX, y: sf.minY, width: w, height: h), display: false)
        makeKeyAndOrderFront(nil)
        // .accessory apps are never "active" by default, so NSCursor calls
        // are ignored by WindowServer.  Explicitly activating makes cursor
        // management work.  The .accessory policy still prevents a Dock icon.
        NSApp.activate(ignoringOtherApps: true)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(NSRect(x: sf.maxX - w, y: sf.minY, width: w, height: h), display: true)
        }

        if !isPinned {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hidePanel()
            }
        }
    }

    @objc func hidePanel() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }

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
        let baseURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let html = (ext == "html" || ext == "htm") ? content : MarkdownRenderer.render(content)
        webView.loadHTMLString(html, baseURL: baseURL)
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
            guard let self = self else { return }
            self.reloadContent()
            let event = src.data
            // Atomic saves (VS Code, sed, mv) replace the file via rename.
            // The old fd now points to the renamed-away file, so re-watch
            // the path to pick up future changes to the new inode.
            if event.contains(.rename) || event.contains(.delete) {
                self.startWatching(path: path)
            }
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
        panel.allowedContentTypes = [.init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!, .init(filenameExtension: "html")!, .init(filenameExtension: "htm")!, .plainText]
        panel.title = "Choose a Markdown or HTML file"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

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
        if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.characters == "w") {
            hidePanel()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - WKNavigationDelegate

extension PreviewPanel: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard action.navigationType == .linkActivated, let url = action.request.url else {
            decisionHandler(.allow)
            return
        }
        routeURL(url)
        decisionHandler(.cancel)
    }
}

// MARK: - WKScriptMessageHandler

extension PreviewPanel: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "linkClicked":
            guard let urlString = message.body as? String,
                  let url = URL(string: urlString) else { return }
            routeURL(url)
        default:
            break
        }
    }
}

// MARK: - Link routing

extension PreviewPanel {
    private func routeURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - ResizeEdgeView
//
// Full-height strip on the left edge of the panel.  The WKWebView frame does
// not cover this strip, and the app is explicitly activated in showPanel(),
// so NSCursor works normally here.

private class ResizeEdgeView: NSView {
    var onDrag: ((CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.resizeLeftRight.push() }
    override func mouseExited(with event: NSEvent)  { NSCursor.pop() }
    override func mouseDown(with event: NSEvent)    { NSCursor.resizeLeftRight.set() }
    override func mouseDragged(with event: NSEvent) { NSCursor.resizeLeftRight.set(); onDrag?(event.deltaX) }
    override func mouseUp(with event: NSEvent)      { NSCursor.pop() }
}

// MARK: - DragGripView
//
// Small view in the title bar showing three dots as a resize affordance.

private class DragGripView: NSView {
    var onDrag: ((CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let dotSize: CGFloat = 3
        let gap: CGFloat = 4
        let totalHeight = dotSize * 3 + gap * 2
        let startY = (bounds.height - totalHeight) / 2
        let x = (bounds.width - dotSize) / 2

        ctx.setFillColor(NSColor.tertiaryLabelColor.cgColor)
        for i in 0..<3 {
            let y = startY + CGFloat(i) * (dotSize + gap)
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: dotSize, height: dotSize))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.resizeLeftRight.push() }
    override func mouseExited(with event: NSEvent)  { NSCursor.pop() }
    override func mouseDown(with event: NSEvent)    { NSCursor.resizeLeftRight.set() }
    override func mouseDragged(with event: NSEvent) { NSCursor.resizeLeftRight.set(); onDrag?(event.deltaX) }
    override func mouseUp(with event: NSEvent)      { NSCursor.pop() }
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
