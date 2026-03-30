import AppKit
import WebKit

// MARK: - ScratchView
//
// The Scratch tab: a text input area at the top for new entries, and a live
// markdown preview of today's scratch file below.  New entries are prepended
// with a timestamp heading.  Daily files (scratch-YYYY-MM-DD.md) are created
// automatically in a user-chosen folder, with links to previous days.

class ScratchView: NSView {

    var onFolderChange: ((String) -> Void)?

    private var textScrollView: NSScrollView!
    private(set) var textView: ScratchTextView!
    private var searchField: NSSearchField!
    private var webView: WKWebView!
    private var watchSource: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var searchQuery: String = ""

    private static let folderKey = "scratchFolderPath"
    // Migration: old single-file key
    private static let legacyFileKey = "scratchFilePath"

    var folderPath: String? {
        get {
            // Migrate from single-file to folder if needed
            if let legacy = UserDefaults.standard.string(forKey: Self.legacyFileKey) {
                let folder = (legacy as NSString).deletingLastPathComponent
                UserDefaults.standard.set(folder, forKey: Self.folderKey)
                UserDefaults.standard.removeObject(forKey: Self.legacyFileKey)
                return folder
            }
            return UserDefaults.standard.string(forKey: Self.folderKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.folderKey)
            ensureTodayFileExists()
            reload()
            startWatching()
        }
    }

    private var todayFileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "scratch-\(formatter.string(from: Date())).md"
    }

    var todayFilePath: String? {
        guard let folder = folderPath else { return nil }
        return (folder as NSString).appendingPathComponent(todayFileName)
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

        // ── Search field ──────────────────────────────────────────────────

        searchField = NSSearchField()
        searchField.placeholderString = "Search scratch files…"
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true

        // ── Assemble ──────────────────────────────────────────────────────

        addSubview(inputBg)
        addSubview(divider)
        addSubview(searchField)
        addSubview(previewBg)

        NSLayoutConstraint.activate([
            inputBg.topAnchor.constraint(equalTo: topAnchor),
            inputBg.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputBg.trailingAnchor.constraint(equalTo: trailingAnchor),

            divider.topAnchor.constraint(equalTo: inputBg.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),

            searchField.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 6),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            previewBg.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
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

    // MARK: - Search

    @objc private func searchChanged() {
        searchQuery = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        reload()
    }

    // MARK: - Helpers

    private func ensureTodayFileExists() {
        guard let folder = folderPath, let path = todayFilePath else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
    }

    private func previousDayFiles() -> [(date: String, filename: String, preview: String)] {
        guard let folder = folderPath else { return [] }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: folder) else { return [] }

        let today = todayFileName
        let pattern = try! NSRegularExpression(pattern: #"^scratch-(\d{4}-\d{2}-\d{2})\.md$"#)

        var results: [(date: String, filename: String, preview: String)] = []
        for file in files {
            guard file != today else { continue }
            let range = NSRange(file.startIndex..., in: file)
            if let match = pattern.firstMatch(in: file, range: range),
               let dateRange = Range(match.range(at: 1), in: file) {
                let date = String(file[dateRange])
                let path = (folder as NSString).appendingPathComponent(file)
                let preview = firstEntry(fromFile: path)
                results.append((date: date, filename: file, preview: preview))
            }
        }
        return results.sorted { $0.date > $1.date }
    }

    /// Extracts the first entry (content up to the second ## heading) from a scratch file.
    private func firstEntry(fromFile path: String) -> String {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        let lines = content.components(separatedBy: "\n")
        var result: [String] = []
        var foundFirst = false
        for line in lines {
            if line.hasPrefix("## ") {
                if foundFirst { break }
                foundFirst = true
            }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Add entry

    @objc func addEntry() {
        guard let path = todayFilePath else { return }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Handle midnight rollover
        if watchedPath != path {
            ensureTodayFileExists()
            startWatching()
        }

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

    // MARK: - Folder picker

    func chooseScratchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.title = "Choose scratch folder"
        panel.prompt = "Use as Scratch Folder"
        panel.level = .modalPanel
        panel.makeKeyAndOrderFront(nil)
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.folderPath = url.path
                self?.onFolderChange?(url.path)
            }
        }
    }

    // MARK: - Reload

    func reload() {
        guard let folder = folderPath, let path = todayFilePath else {
            loadPlaceholder()
            return
        }

        // Handle midnight rollover
        if watchedPath != path {
            ensureTodayFileExists()
            startWatching()
        }

        if !searchQuery.isEmpty {
            renderSearchResults(folder: folder)
            return
        }

        let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""

        // Build previous days section with previews
        let previous = previousDayFiles()
        var markdown = content
        if !previous.isEmpty {
            markdown += "\n---\n\n"
            for entry in previous {
                markdown += "### [\(entry.date)](\(entry.filename))\n\n"
                if !entry.preview.isEmpty {
                    // Strip the ## heading from the preview since we already show the date
                    var preview = entry.preview
                    if preview.hasPrefix("## ") {
                        // Remove the first line (the ## timestamp heading)
                        if let newline = preview.firstIndex(of: "\n") {
                            preview = String(preview[preview.index(after: newline)...])
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        } else {
                            preview = ""
                        }
                    }
                    if !preview.isEmpty {
                        markdown += "> \(preview.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
                    }
                }
            }
        }

        let html = MarkdownRenderer.render(markdown)
        let base = URL(fileURLWithPath: folder, isDirectory: true)
        webView.loadHTMLString(html, baseURL: base)
    }

    private func renderSearchResults(folder: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: folder) else { return }

        let pattern = try! NSRegularExpression(pattern: #"^scratch-(\d{4}-\d{2}-\d{2})\.md$"#)
        let query = searchQuery.lowercased()

        // Collect all scratch files sorted newest first
        var scratchFiles: [(date: String, filename: String)] = []
        for file in files {
            let range = NSRange(file.startIndex..., in: file)
            if let match = pattern.firstMatch(in: file, range: range),
               let dateRange = Range(match.range(at: 1), in: file) {
                scratchFiles.append((date: String(file[dateRange]), filename: file))
            }
        }
        scratchFiles.sort { $0.date > $1.date }

        var markdown = "# Search: \(searchQuery)\n\n"
        var matchCount = 0

        for file in scratchFiles {
            let path = (folder as NSString).appendingPathComponent(file.filename)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            guard content.lowercased().contains(query) else { continue }

            // Find matching entries (## blocks)
            let entries = splitIntoEntries(content)
            for entry in entries {
                guard entry.body.lowercased().contains(query) else { continue }
                markdown += "### [\(file.date)](\(file.filename))"
                if !entry.heading.isEmpty {
                    markdown += " — \(entry.heading)"
                }
                markdown += "\n\n"
                markdown += "> \(entry.body.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
                matchCount += 1
            }
        }

        if matchCount == 0 {
            markdown += "*No results found.*\n"
        }

        let html = MarkdownRenderer.render(markdown)
        let base = URL(fileURLWithPath: folder, isDirectory: true)
        webView.loadHTMLString(html, baseURL: base)
    }

    /// Splits file content into entries delimited by ## headings.
    private func splitIntoEntries(_ content: String) -> [(heading: String, body: String)] {
        let lines = content.components(separatedBy: "\n")
        var entries: [(heading: String, body: String)] = []
        var currentHeading = ""
        var currentLines: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                if !currentLines.isEmpty || !currentHeading.isEmpty {
                    let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty {
                        entries.append((heading: currentHeading, body: body))
                    }
                }
                currentHeading = String(line.dropFirst(3))
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        // Last entry
        let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            entries.append((heading: currentHeading, body: body))
        }
        return entries
    }

    private func loadPlaceholder() {
        let html = MarkdownRenderer.render("""
        # No scratch folder

        Click the **folder icon** in the title bar to pick a folder for daily scratch files.

        Each day gets its own file (`scratch-YYYY-MM-DD.md`) with links to previous days.
        """)
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - File watching

    func startWatching() {
        watchSource?.cancel()
        watchSource = nil
        watchedPath = nil
        guard let path = todayFilePath else { return }

        ensureTodayFileExists()

        let fd = open(path, O_EVTONLY)
        guard fd != -1 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.reload() }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        watchSource = src
        watchedPath = path
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
