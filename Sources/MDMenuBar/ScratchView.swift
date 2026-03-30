import AppKit
import WebKit

// MARK: - ScratchView
//
// The Scratch tab: a text input area at the top for new entries, and a live
// markdown preview of the scratch file below.  New entries are prepended with
// a timestamp heading so the most recent content is always at the top.

class ScratchView: NSView {

    var onFileChange: ((String) -> Void)?

    private var textScrollView: NSScrollView!
    private(set) var textView: ScratchTextView!
    private var webView: WKWebView!
    private var watchSource: DispatchSourceFileSystemObject?

    private static let pathKey = "scratchFilePath"

    var filePath: String? {
        get { UserDefaults.standard.string(forKey: Self.pathKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.pathKey)
            reload()
            startWatching()
        }
    }

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func build() {

        // ── Input area ────────────────────────────────────────────────────

        let inputBg = NSVisualEffectView()
        inputBg.material = .sidebar
        inputBg.blendingMode = .behindWindow
        inputBg.state = .active
        inputBg.translatesAutoresizingMaskIntoConstraints = false

        // NSTextView must be set up with a concrete initial frame and
        // autoresizingMask; Auto Layout on the textView itself doesn't work
        // inside NSScrollView.
        textScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        textScrollView.hasVerticalScroller = true
        textScrollView.hasHorizontalScroller = false
        textScrollView.autohidesScrollers = true
        textScrollView.drawsBackground = false
        textScrollView.borderType = .noBorder
        textScrollView.translatesAutoresizingMaskIntoConstraints = false

        let initialWidth = textScrollView.contentSize.width
        textView = ScratchTextView(frame: NSRect(x: 0, y: 0, width: max(initialWidth, 100), height: 120))
        textView.onSubmit = { [weak self] in self?.addEntry() }
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: max(initialWidth, 100),
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        textScrollView.documentView = textView

        // "Add Entry" button
        let addButton = NSButton()
        addButton.title = "Add Entry  ⌘↩"
        addButton.bezelStyle = .rounded
        addButton.action = #selector(addEntry)
        addButton.target = self
        addButton.translatesAutoresizingMaskIntoConstraints = false

        inputBg.addSubview(textScrollView)
        inputBg.addSubview(addButton)

        NSLayoutConstraint.activate([
            textScrollView.topAnchor.constraint(equalTo: inputBg.topAnchor, constant: 8),
            textScrollView.leadingAnchor.constraint(equalTo: inputBg.leadingAnchor),
            textScrollView.trailingAnchor.constraint(equalTo: inputBg.trailingAnchor),
            textScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            textScrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 200),

            addButton.topAnchor.constraint(equalTo: textScrollView.bottomAnchor, constant: 6),
            addButton.trailingAnchor.constraint(equalTo: inputBg.trailingAnchor, constant: -12),
            addButton.bottomAnchor.constraint(equalTo: inputBg.bottomAnchor, constant: -10),
        ])

        // ── Divider ───────────────────────────────────────────────────────

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        // ── Preview (WKWebView) ───────────────────────────────────────────

        let config = WKWebViewConfiguration()
        let linkScript = WKUserScript(source: """
            (function() {
                document.addEventListener('click', function(e) {
                    var el = e.target;
                    while (el && el.tagName !== 'A') { el = el.parentElement; }
                    if (el && el.href) {
                        e.preventDefault();
                        window.webkit.messageHandlers.scratchLink.postMessage(el.href);
                    }
                }, true);
            })();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(linkScript)
        config.userContentController.add(self, name: "scratchLink")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false

        let previewBg = NSVisualEffectView()
        previewBg.material = .contentBackground
        previewBg.blendingMode = .behindWindow
        previewBg.state = .active
        previewBg.translatesAutoresizingMaskIntoConstraints = false
        previewBg.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: previewBg.topAnchor),
            webView.bottomAnchor.constraint(equalTo: previewBg.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: previewBg.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: previewBg.trailingAnchor),
        ])

        // ── Assemble ──────────────────────────────────────────────────────

        addSubview(inputBg)
        addSubview(divider)
        addSubview(previewBg)

        NSLayoutConstraint.activate([
            inputBg.topAnchor.constraint(equalTo: topAnchor),
            inputBg.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputBg.trailingAnchor.constraint(equalTo: trailingAnchor),

            divider.topAnchor.constraint(equalTo: inputBg.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),

            previewBg.topAnchor.constraint(equalTo: divider.bottomAnchor),
            previewBg.bottomAnchor.constraint(equalTo: bottomAnchor),
            previewBg.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewBg.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        reload()
        startWatching()
    }

    // MARK: - Focus

    func focusTextView() {
        window?.makeFirstResponder(textView)
    }

    // MARK: - Add entry

    @objc func addEntry() {
        guard let path = filePath else { return }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let timestamp = formatter.string(from: Date())

        let entry = "## \(timestamp)\n\n\(text)\n\n"
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""

        do {
            try (entry + existing).write(toFile: path, atomically: true, encoding: .utf8)
            textView.string = ""
            reload()
        } catch {
            // no-op: file write failed
        }
    }

    // MARK: - File picker

    func chooseScratchFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.title = "Choose or create scratch file"
        panel.prompt = "Use as Scratch File"
        panel.nameFieldStringValue = "scratch.md"
        panel.canCreateDirectories = true
        panel.level = .modalPanel
        panel.makeKeyAndOrderFront(nil)
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                self?.filePath = url.path
                self?.onFileChange?(url.path)
            }
        }
    }

    // MARK: - Reload

    func reload() {
        guard let path = filePath,
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            loadPlaceholder()
            return
        }
        let html = MarkdownRenderer.render(content)
        let base = URL(fileURLWithPath: path).deletingLastPathComponent()
        webView.loadHTMLString(html, baseURL: base)
    }

    private func loadPlaceholder() {
        let html = MarkdownRenderer.render("""
        # No scratch file

        Click the **folder icon** in the title bar to pick or create a Markdown file.

        New entries will be prepended as timestamp headings.
        """)
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - File watching

    func startWatching() {
        watchSource?.cancel()
        watchSource = nil
        guard let path = filePath else { return }

        let fd = open(path, O_EVTONLY)
        guard fd != -1 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.reload() }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watchSource = src
    }
}

// MARK: - WKScriptMessageHandler

extension ScratchView: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let urlString = message.body as? String,
              let url = URL(string: urlString) else { return }
        if url.isFileURL {
            if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
                NSWorkspace.shared.open(url)
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - ScratchTextView

class ScratchTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // ⌘↩ submits the entry
        if event.modifierFlags.contains(.command) && event.keyCode == 36 {
            onSubmit?()
        } else {
            super.keyDown(with: event)
        }
    }
}
