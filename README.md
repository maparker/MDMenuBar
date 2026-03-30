# MDMenuBar

A lightweight macOS menu bar app that renders a Markdown file as a styled preview panel. The panel slides in from the right edge of your screen and stays out of the way until you need it.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- **Instant preview** — renders Markdown with GitHub-style CSS, including dark mode support
- **Slides in from the right** — smooth animation, dismisses with a click outside or keyboard shortcut
- **Global hotkey** — toggle the panel from any app with **⌘⇧M** (no accessibility permissions required)
- **Live reload** — the preview updates automatically whenever the file changes on disk
- **Scratch pad** — a built-in tab for quick notes; entries are timestamped and prepended to a configurable Markdown file
- **Resizable** — drag the left edge of the panel to adjust width (persisted across launches)
- **Remembers your file** — reopens the last viewed file on next launch
- **No dock icon** — lives entirely in the menu bar

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools (for `swift build`)

## Installation

```bash
git clone https://github.com/maparker/MDMenuBar.git
cd MDMenuBar
swift build -c release
cp .build/release/MDMenuBar /usr/local/bin/MDMenuBar
```

Or run directly without installing:

```bash
swift run
```

## Usage

1. **Launch** — run `MDMenuBar` from the terminal or add it to your login items
2. **Open a file** — right-click the menu bar icon and choose **Open File…**, or click the folder button inside the panel
3. **Toggle the panel** — left-click the menu bar icon or press **⌘⇧M** from anywhere
4. **Switch tabs** — use the **Preview** / **Scratch** segmented control in the title bar
5. **Dismiss** — click outside the panel, press **Escape**, press **⌘W**, or click the **×** button

### Menu bar icon

| Action | Result |
|---|---|
| Left-click | Toggle preview panel |
| Right-click | Context menu (Open File, Reload, Quit) |

### Inside the panel

| Action | Result |
|---|---|
| **⌘⇧M** or Escape | Close panel |
| **⌘W** | Close panel |
| Click outside | Close panel |
| ↺ button | Reload file from disk |
| Folder button | Open a different file |
| × button | Close panel |
| Drag left edge | Resize panel width |

### Scratch tab

| Action | Result |
|---|---|
| Type in the text area | Compose a new entry |
| **⌘↩** or **Add Entry** button | Prepend entry with timestamp to scratch file |
| Folder button | Choose or create a scratch `.md` file |

## Supported Markdown

- Headings (`#` – `######`)
- **Bold**, *italic*, ~~strikethrough~~, `inline code`
- Fenced code blocks with language hint
- Ordered and unordered lists
- Blockquotes
- Tables
- Links and images
- Horizontal rules

## Login Item (start at login)

1. Build a release binary: `swift build -c release`
2. Copy `.build/release/MDMenuBar` somewhere permanent (e.g. `~/Applications/`)
3. Open **System Settings → General → Login Items** and add the binary

## Project structure

```
Sources/MDMenuBar/
├── main.swift              — entry point; hides dock icon
├── AppDelegate.swift       — status bar item, context menu, global hotkey
├── PreviewPanel.swift      — sliding NSPanel, WKWebView, file watcher, tab switching
├── ScratchView.swift       — scratch pad tab with text input and markdown preview
└── MarkdownRenderer.swift  — Markdown → HTML converter with GitHub-style CSS
```

## License

MIT
