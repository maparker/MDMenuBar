import AppKit
import WebKit

// MARK: - ScratchView
//
// The Scratch tab: a text input area at the top for new entries, and a live
// markdown preview of the scratch file below.  New entries are prepended with
// a timestamp heading so the most recent content is always at the top.

class ScratchView: NSView {

    var onFileChange: ((String) -> Void)?   // called when user picks a new file

    private var textScrollView: NSScrollView!
    private(set) var textView: ScratchTextView!
    private var webView: WKWebView!
    private var watchSource: DispatchSourceFileSystemObject?
    private var addButton: NSButton!
    private var hintLabel: NSTextField!

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
        // Input area background
        let inputBg = NSVisualEffectView()
        inputBg.material = .sidebar
        inputBg.blendingMode = .behindWindow
        inputBg.state = .active
        inputBg.translatesAutoresizingMaskIntoConstraints = false

        // NSTextView for new entry
        textView = ScratchTextView()
        textView.onSubmit = { [weak self] in self?.addEntry() }
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 12, height: 10)

        textScrollView = NSScrollView()
        textScrollView.hasVerticalScroller = true
        textScrollView.hasHorizontalScroller = false
        textScrollView.autohidesScrollers = true
        textScrollView.drawsBackground = false
        textScrollView.documentView = textView
        textScrollView.translatesAutoresizingMaskIntoConstraints = false

        // Placeholder label (shown when text view is empty)
        let placeholder = NSTextField(labelWithString: "New entry… (⌘↩ to save)")
        placeholder.font = NSFont.systemFont(ofSize: 13)
        placeholder.textColor = .placeholderTextColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isEditable = false
        placeholder.isBordered = false
        placeholder.backgroundColor = .clear
        placeholder.tag = 99  // used to find/show/hide
        textView.placeholderLabel = placeholder

        // Add Entry button
        addButton = NSButton()
        addButton.title = "Add Entry"
        addButton.bezelStyle = .rounded
        addButton.action = #selector(addEntry)
        addButton.target = self
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.keyEquivalent = "\r"
        addButton.keyEquivalentModifierMask = .command

        let inputDivider = NSBox()
        inputDivider.boxType = .separator
        inputDivider.translatesAutoresizingMaskIntoConstraints = false

        inputBg.addSubview(textScrollView)
        inputBg.addSubview(placeholder)
        inputBg.addSubview(addButton)

        NSLayoutConstraint.activate([
            textScrollView.topAnchor.constraint(equalTo: inputBg.topAnchor),
            textScrollView.leadingAnchor.constraint(equalTo: inputBg.leadingAnchor),
            textScrollView.trailingAnchor.constraint(equalTo: inputBg.trailingAnchor),
            textScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            textScrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 200),

            placeholder.leadingAnchor.constraint(equalTo: inputBg.leadingAnchor, constant: 14),
            placeholder.topAnchor.constraint(equalTo: inputBg.topAnchor, constant: 10),

            addButton.trailingAnchor.constraint(equalTo: inputBg.trailingAnchor, constant: -12),
            addButton.bottomAnchor.constraint(equalTo: inputBg.bottomAnchor, constant: -10),
            addButton.topAnchor.constraint(equalTo: textScrollView.bottomAnchor, constant: 6),
        ])

        let inputHeight = inputBg.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        inputHeight.priority = .defaultHigh
        inputHeight.isActive = true

        // WebView preview
        let config = WKWebViewConfiguration()
        let linkScript = WKUserScript(source: """
            (function() {
                document.addEventListener('click', function(e) {
                    var el = e.target;
                    while (el && el.tagName !== 'A') { el = el.parentElement; }
                    if (el && el.href) {
                        e.preventDefault();
                        window.webkit.messageHandlers.scratchLinkClicked.postMessage(el.href);
                    }
                }, true);
            })();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(linkScript)
        config.userContentController.add(self, name: "scratchLinkClicked")

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

        addSubview(inputBg)
        addSubview(inputDivider)
        addSubview(previewBg)

        NSLayoutConstraint.activate([
            inputBg.topAnchor.constraint(equalTo: topAnchor),
            inputBg.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputBg.trailingAnchor.constraint(equalTo: trailingAnchor),

            inputDivider.topAnchor.constraint(equalTo: inputBg.bottomAnchor),
            inputDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputDivider.trailingAnchor.constraint(equalTo: trailingAnchor),

            previewBg.topAnchor.constraint(equalTo: inputDivider.bottomAnchor),
            previewBg.bottomAnchor.constraint(equalTo: bottomAnchor),
            previewBg.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewBg.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        reload()
    }

    // MARK: - Actions

    @objc func addEntry() {
        guard let path = filePath else { return }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let timestamp = formatter.string(from: Date())

        let entry = "## \(timestamp)\n\n\(text)\n\n"
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let newContent = entry + existing

        do {
            try newContent.write(toFile: path, atomically: true, encoding: .utf8)
            textView.string = ""
            textView.placeholderLabel?.isHidden = false
            reload()
        } catch {
            // Write failed — file may not exist yet; create it
            try? newContent.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func chooseScratchFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!, .plainText]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose scratch file"
        panel.prompt = "Use as Scratch File"
        panel.canCreateDirectories = true

        // Also allow creating a new file by accepting any name
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.init(filenameExtension: "md")!]
        savePanel.title = "Choose or create scratch file"
        savePanel.prompt = "Use as Scratch File"
        savePanel.nameFieldStringValue = "scratch.md"
        savePanel.canCreateDirectories = true
        savePanel.level = .modalPanel
        savePanel.makeKeyAndOrderFront(nil)
        savePanel.begin { [weak self] response in
            if response == .OK, let url = savePanel.url {
                // Create the file if it doesn't exist
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                self?.filePath = url.path
                self?.onFileChange?(url.path)
            }
        }
    }

    // MARK: - Content

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

        Click **Choose Scratch File** in the title bar to pick or create a Markdown file.

        New entries will be prepended with a timestamp heading.
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
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self] in self?.reload() }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watchSource = src
    }
}

// MARK: - WKScriptMessageHandler

extension ScratchView: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "scratchLinkClicked",
              let urlString = message.body as? String,
              let url = URL(string: urlString) else { return }

        if url.isFileURL {
            let ext = url.pathExtension.lowercased()
            if ext == "md" || ext == "markdown" { NSWorkspace.shared.open(url) }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - ScratchTextView
//
// NSTextView subclass that intercepts ⌘↩ to submit the entry and
// manages a placeholder label overlay.

class ScratchTextView: NSTextView {
    var onSubmit: (() -> Void)?
    weak var placeholderLabel: NSTextField?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && event.keyCode == 36 {
            onSubmit?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        placeholderLabel?.isHidden = !string.isEmpty
    }
}
