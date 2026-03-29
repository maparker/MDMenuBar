import Foundation

struct MarkdownRenderer {

    static func render(_ markdown: String) -> String {
        let body = convertToHTML(markdown)
        return wrapInPage(body)
    }

    // MARK: - Block processing

    private static func convertToHTML(_ markdown: String) -> String {
        var result = ""
        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        var inCodeBlock = false
        var codeLang = ""
        var codeContent = ""
        var inUL = false
        var inOL = false

        while i < lines.count {
            let line = lines[i]

            // Code fences
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if inCodeBlock {
                    let escaped = escapeHTML(codeContent.hasSuffix("\n")
                        ? String(codeContent.dropLast()) : codeContent)
                    result += "<pre><code class=\"language-\(codeLang)\">\(escaped)</code></pre>\n"
                    codeContent = ""; codeLang = ""; inCodeBlock = false
                } else {
                    closeList(&result, &inUL, &inOL)
                    codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCodeBlock = true
                }
                i += 1; continue
            }

            if inCodeBlock {
                codeContent += line + "\n"
                i += 1; continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line
            if trimmed.isEmpty {
                closeList(&result, &inUL, &inOL)
                i += 1; continue
            }

            // ATX headers
            if let header = parseHeader(line) {
                closeList(&result, &inUL, &inOL)
                result += header + "\n"
                i += 1; continue
            }

            // Horizontal rule
            let dashes = trimmed.filter { $0 == "-" }.count
            let stars  = trimmed.filter { $0 == "*" }.count
            let unders = trimmed.filter { $0 == "_" }.count
            let hrChars = trimmed.filter { !$0.isWhitespace }
            if (dashes >= 3 && hrChars.allSatisfy { $0 == "-" }) ||
               (stars  >= 3 && hrChars.allSatisfy { $0 == "*" }) ||
               (unders >= 3 && hrChars.allSatisfy { $0 == "_" }) {
                closeList(&result, &inUL, &inOL)
                result += "<hr>\n"
                i += 1; continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") {
                closeList(&result, &inUL, &inOL)
                let content = processInline(String(trimmed.dropFirst(2)))
                result += "<blockquote><p>\(content)</p></blockquote>\n"
                i += 1; continue
            }

            // Unordered list (-, *, +)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                if inOL { result += "</ol>\n"; inOL = false }
                if !inUL { result += "<ul>\n"; inUL = true }
                let content = processInline(String(trimmed.dropFirst(2)))
                result += "<li>\(content)</li>\n"
                i += 1; continue
            }

            // Ordered list
            if let olMatch = orderedListItem(trimmed) {
                if inUL { result += "</ul>\n"; inUL = false }
                if !inOL { result += "<ol>\n"; inOL = true }
                result += "<li>\(processInline(olMatch))</li>\n"
                i += 1; continue
            }

            // Table (simple)
            if trimmed.contains("|") && i + 1 < lines.count && lines[i + 1].contains("---") {
                closeList(&result, &inUL, &inOL)
                result += parseTable(lines: lines, startIndex: &i)
                continue
            }

            // Paragraph
            closeList(&result, &inUL, &inOL)
            result += "<p>\(processInline(line))</p>\n"
            i += 1
        }

        closeList(&result, &inUL, &inOL)
        if inCodeBlock {
            result += "<pre><code>\(escapeHTML(codeContent))</code></pre>\n"
        }

        return result
    }

    private static func closeList(_ out: inout String, _ ul: inout Bool, _ ol: inout Bool) {
        if ul { out += "</ul>\n"; ul = false }
        if ol { out += "</ol>\n"; ol = false }
    }

    private static func parseHeader(_ line: String) -> String? {
        for level in stride(from: 6, through: 1, by: -1) {
            let prefix = String(repeating: "#", count: level)
            if line.hasPrefix(prefix + " ") {
                let text = processInline(String(line.dropFirst(level + 1)))
                let anchor = text.lowercased()
                    .replacingOccurrences(of: " ", with: "-")
                    .filter { $0.isLetter || $0.isNumber || $0 == "-" }
                return "<h\(level) id=\"\(anchor)\">\(text)</h\(level)>"
            }
        }
        return nil
    }

    private static func orderedListItem(_ line: String) -> String? {
        let pattern = #"^\d+\.\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    private static func parseTable(lines: [String], startIndex: inout Int) -> String {
        let headerLine = lines[startIndex]
        startIndex += 2 // skip header + separator

        let headers = headerLine.split(separator: "|", omittingEmptySubsequences: true)
            .map { processInline($0.trimmingCharacters(in: .whitespaces)) }

        var html = "<table>\n<thead><tr>"
        for h in headers { html += "<th>\(h)</th>" }
        html += "</tr></thead>\n<tbody>\n"

        while startIndex < lines.count {
            let row = lines[startIndex]
            if !row.contains("|") { break }
            let cells = row.split(separator: "|", omittingEmptySubsequences: true)
                .map { processInline($0.trimmingCharacters(in: .whitespaces)) }
            html += "<tr>"
            for c in cells { html += "<td>\(c)</td>" }
            html += "</tr>\n"
            startIndex += 1
        }
        html += "</tbody>\n</table>\n"
        return html
    }

    // MARK: - Inline processing

    static func processInline(_ text: String) -> String {
        // Escape HTML first (but preserve existing entities)
        var s = escapeHTML(text)

        // Bold + italic
        s = applyRegex(#"\*\*\*(.+?)\*\*\*"#, template: "<strong><em>$1</em></strong>", to: s)
        s = applyRegex(#"___(.+?)___"#, template: "<strong><em>$1</em></strong>", to: s)

        // Bold
        s = applyRegex(#"\*\*(.+?)\*\*"#, template: "<strong>$1</strong>", to: s)
        s = applyRegex(#"__(.+?)__"#, template: "<strong>$1</strong>", to: s)

        // Italic
        s = applyRegex(#"\*(.+?)\*"#, template: "<em>$1</em>", to: s)
        s = applyRegex(#"(?<![a-zA-Z0-9])_(.+?)_(?![a-zA-Z0-9])"#, template: "<em>$1</em>", to: s)

        // Strikethrough
        s = applyRegex(#"~~(.+?)~~"#, template: "<del>$1</del>", to: s)

        // Inline code (must come after bold/italic to avoid nesting issues)
        s = applyRegex(#"`(.+?)`"#, template: "<code>$1</code>", to: s)

        // Images (before links)
        s = applyRegex(#"!\[([^\]]*)\]\(([^)]+)\)"#, template: "<img alt=\"$1\" src=\"$2\">", to: s)

        // Links
        s = applyRegex(#"\[([^\]]+)\]\(([^)]+)\)"#, template: "<a href=\"$2\">$1</a>", to: s)

        return s
    }

    private static func applyRegex(_ pattern: String, template: String, to input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return input
        }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: template)
    }

    static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - HTML wrapper

    private static func wrapInPage(_ body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root {
            --bg: #ffffff;
            --fg: #1f2328;
            --muted: #656d76;
            --border: #d0d7de;
            --code-bg: #f6f8fa;
            --link: #0969da;
            --quote-border: #d0d7de;
            --table-alt: #f6f8fa;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg: #0d1117;
                --fg: #e6edf3;
                --muted: #8b949e;
                --border: #30363d;
                --code-bg: #161b22;
                --link: #58a6ff;
                --quote-border: #3b434b;
                --table-alt: #161b22;
            }
        }
        * { box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
            font-size: 15px;
            line-height: 1.6;
            color: var(--fg);
            background: var(--bg);
            margin: 0;
            padding: 20px 28px 40px;
            word-wrap: break-word;
        }
        h1, h2, h3, h4, h5, h6 {
            margin-top: 24px;
            margin-bottom: 12px;
            font-weight: 600;
            line-height: 1.25;
        }
        h1 { font-size: 2em; border-bottom: 1px solid var(--border); padding-bottom: 0.3em; }
        h2 { font-size: 1.5em; border-bottom: 1px solid var(--border); padding-bottom: 0.3em; }
        h3 { font-size: 1.25em; }
        p { margin: 0 0 16px; }
        a { color: var(--link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code {
            font-family: "SF Mono", ui-monospace, Menlo, Monaco, Consolas, monospace;
            font-size: 85%;
            background: var(--code-bg);
            padding: 0.2em 0.4em;
            border-radius: 6px;
            border: 1px solid var(--border);
        }
        pre {
            background: var(--code-bg);
            border: 1px solid var(--border);
            border-radius: 6px;
            padding: 16px;
            overflow-x: auto;
            margin: 0 0 16px;
        }
        pre code {
            background: none;
            border: none;
            padding: 0;
            font-size: 85%;
        }
        blockquote {
            margin: 0 0 16px;
            padding: 0 1em;
            color: var(--muted);
            border-left: 4px solid var(--quote-border);
        }
        blockquote p { margin: 0; }
        ul, ol { margin: 0 0 16px; padding-left: 2em; }
        li { margin: 4px 0; }
        hr { border: none; border-top: 1px solid var(--border); margin: 24px 0; }
        img { max-width: 100%; height: auto; border-radius: 6px; }
        table { border-collapse: collapse; margin: 0 0 16px; width: 100%; }
        th, td { border: 1px solid var(--border); padding: 6px 13px; text-align: left; }
        th { background: var(--code-bg); font-weight: 600; }
        tr:nth-child(even) td { background: var(--table-alt); }
        del { color: var(--muted); }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}
