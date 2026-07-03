import AppKit
import ApplicationServices
import Foundation
import os

private let logger = Logger(subsystem: "team.yourorbit.OrbitDictation", category: "TextInjector")

/// Pastes text into the active application while preserving the previous clipboard contents when possible.
enum TextInjector {
    static func paste(_ text: String, preserveClipboard: Bool = true) async {
        let pasteboard = NSPasteboard.general

        // Snapshot the current clipboard in parallel with the key-release
        // wait. The two are independent, and snapshotting takes ~1–5 ms, so
        // running them concurrently shaves measurable paste latency.
        async let snapshot: [NSPasteboardItem]? = preserveClipboard
            ? snapshotPasteboard(pasteboard)
            : nil
        await waitForKeyRelease()
        let savedItems = await snapshot

        guard !Task.isCancelled else {
            logger.info("Paste cancelled before clipboard write")
            return
        }

        // Read the focused text field's cursor context via Accessibility.
        // If the character immediately before the cursor is non-whitespace,
        // prepend a space so dictating into mid-sentence text doesn't
        // jam-words-together. AX lookup is best-effort; falls through
        // silently for apps that don't expose the attribute (Electron,
        // some web fields). Latency is ~3–10ms in practice.
        let finalText = applyLeadingSpaceIfNeeded(to: text)

        // Write text to clipboard. Plain text is the universal fallback; when
        // the cleaned output contains list lines (`• item`, `- item`), we also
        // write RTF (with a native NSTextList) and HTML (`<ul><li>`) so
        // rich-text targets (Mail, Notes, Pages, Word) and web/Electron targets
        // (Slack, Notion, Gmail) each render a REAL native bulleted list rather
        // than a literal "•" glyph. Plain-text-only targets (code editors,
        // Terminal) ignore both and fall back to the `•` lines verbatim.
        pasteboard.clearContents()
        if let rtfData = makeRTF(from: finalText) {
            pasteboard.setData(rtfData, forType: .rtf)
        }
        if let htmlData = makeHTML(from: finalText) {
            pasteboard.setData(htmlData, forType: .html)
        }
        pasteboard.setString(finalText, forType: .string)
        let pasteChangeCount = pasteboard.changeCount

        // Brief wait for app focus to return. 15ms is enough on modern
        // hardware; the prior 30ms was defensive padding.
        try? await Task.sleep(for: .milliseconds(15))

        // If cancelled after clipboard write but before paste, restore and bail.
        guard !Task.isCancelled else {
            logger.info("Paste cancelled before simulating Cmd+V — restoring clipboard")
            if let savedItems {
                pasteboard.clearContents()
                pasteboard.writeObjects(savedItems)
            }
            return
        }

        // Simulate Cmd+V
        simulatePaste()

        // Restore clipboard after 150ms (only if nothing else modified it)
        if preserveClipboard, let savedItems {
            try? await Task.sleep(for: .milliseconds(150))
            if pasteboard.changeCount == pasteChangeCount {
                pasteboard.clearContents()
                let wrote = pasteboard.writeObjects(savedItems)
                if wrote {
                    logger.debug("Clipboard restored")
                } else {
                    logger.warning("Clipboard restore failed: writeObjects returned false")
                }
            } else {
                // Something else wrote to the clipboard between paste and restore
                // (likely the user or another app). Skip restore to avoid clobbering.
                logger.info("Clipboard changed during paste — skipping restore to preserve new contents")
            }
        }
    }

    /// Reads the focused text field's cursor context via Accessibility and
    /// prepends a space if the character immediately before the cursor is
    /// non-whitespace. Catches the "type into mid-sentence" case where
    /// pasting "world" after "hello" without a space would produce
    /// "helloworld".
    ///
    /// Best-effort: any AX failure (web text fields, Electron apps that
    /// don't expose AXSelectedTextRange / AXStringForRange, fields that
    /// don't have AXFocusedUIElement) returns the original text unchanged
    /// rather than blocking paste. AX latency is ~3–10ms in practice.
    ///
    /// Behaviour matrix:
    ///   - Cursor at position 0 → no leading space (nothing to follow)
    ///   - Char before cursor is whitespace or newline → no leading space
    ///   - Char before cursor is any other character → prepend " "
    ///   - AX read fails for any reason → no leading space (status quo)
    private static func applyLeadingSpaceIfNeeded(to text: String) -> String {
        guard let charBefore = readCharacterBeforeCursor() else {
            return text
        }

        // Only prepend when we have a clear non-whitespace character before
        // the cursor. Empty string means cursor is at position 0.
        if charBefore.isEmpty {
            return text
        }
        if charBefore.allSatisfy({ $0.isWhitespace || $0.isNewline }) {
            return text
        }

        logger.debug("Leading space prepended (preceded by non-whitespace)")
        return " " + text
    }

    /// Returns the character immediately before the focused field's cursor,
    /// or `nil` if the AX lookup fails at any step. Returns "" (empty) when
    /// the cursor is at position 0.
    private static func readCharacterBeforeCursor() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        // Focused UI element across the system (frontmost app's focused
        // text input). Returns nil for apps that don't expose this — we
        // fall through silently and skip the space.
        var focused: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard focusResult == .success, let focusedRef = focused else {
            return nil
        }
        let element = focusedRef as! AXUIElement

        // Selected text range — for an unselected cursor this is a
        // zero-length range at the insertion point. For a selection
        // we still use the start-of-range to mean "where new text would
        // land", which is the desired semantics here.
        var rangeRef: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        )
        guard rangeResult == .success, let rangeAxValue = rangeRef else {
            return nil
        }

        var range = CFRange(location: 0, length: 0)
        let extracted = AXValueGetValue(rangeAxValue as! AXValue, .cfRange, &range)
        guard extracted else { return nil }

        // Cursor at the very start: caller treats this as "no space".
        if range.location == 0 {
            return ""
        }

        // Read just the character immediately before the cursor.
        var beforeRange = CFRange(location: range.location - 1, length: 1)
        guard let beforeAxValue = AXValueCreate(.cfRange, &beforeRange) else {
            return nil
        }

        var charRef: CFTypeRef?
        let charResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            beforeAxValue,
            &charRef
        )
        guard charResult == .success, let str = charRef as? String else {
            return nil
        }

        return str
    }

    /// Shared list-line detection. A line is a bullet if its first
    /// non-whitespace characters are `• `, `- `, or `* ` (markers the cleanup
    /// prompt may emit). The marker is stripped and re-rendered natively per
    /// representation.
    private static func isBulletLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("• ") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
    }

    private static func bulletContent(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return String(trimmed.dropFirst(2))
    }

    /// Builds an RTF representation with a REAL native bulleted list
    /// (`NSTextList`) when list lines are present, so rich-text apps (Pages,
    /// TextEdit, Notes, Mail, Word) render proper list items — a native disc
    /// marker with a hanging indent — rather than a literal "•" glyph at body
    /// size. Returns `nil` when there are no list markers, so plain prose
    /// pastes as plain-text-only and doesn't carry RTF styling into the target.
    private static func makeRTF(from text: String) -> Data? {
        let lines = text.components(separatedBy: "\n")
        guard lines.contains(where: isBulletLine) else { return nil }

        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let textList = NSTextList(markerFormat: .disc, options: 0)
        let marker = textList.marker(forItemNumber: 1)
        let bodyParagraphStyle = NSMutableParagraphStyle()

        let attributed = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if isBulletLine(line) {
                let listStyle = NSMutableParagraphStyle()
                listStyle.textLists = [textList]
                listStyle.firstLineHeadIndent = 0
                listStyle.headIndent = 18
                listStyle.tabStops = [NSTextTab(textAlignment: .left, location: 18, options: [:])]
                // TextEdit's native-list convention: tab, marker, tab, content,
                // with `.textLists` set so the RTF writer emits real \ls/\ilvl
                // list tables that receiving apps interpret as a native list.
                attributed.append(NSAttributedString(
                    string: "\t\(marker)\t\(bulletContent(line))",
                    attributes: [.font: bodyFont, .paragraphStyle: listStyle]
                ))
            } else {
                attributed.append(NSAttributedString(
                    string: line,
                    attributes: [.font: bodyFont, .paragraphStyle: bodyParagraphStyle]
                ))
            }
            if index < lines.count - 1 {
                attributed.append(NSAttributedString(string: "\n"))
            }
        }

        return try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    /// Builds an HTML representation with real `<ul><li>` lists when list lines
    /// are present. Web- and Electron-based targets (Slack, Notion, Gmail, many
    /// chat inputs) read `public.html` off the pasteboard and render this as a
    /// native list — the RTF above doesn't reach them. Returns `nil` when there
    /// are no list markers, so non-list prose stays plain-text-only.
    private static func makeHTML(from text: String) -> Data? {
        let lines = text.components(separatedBy: "\n")
        guard lines.contains(where: isBulletLine) else { return nil }

        var html = ""
        var inList = false
        for line in lines {
            if isBulletLine(line) {
                if !inList { html += "<ul>"; inList = true }
                html += "<li>\(escapeHTML(bulletContent(line)))</li>"
            } else {
                if inList { html += "</ul>"; inList = false }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    html += "<br>"
                } else {
                    html += "<div>\(escapeHTML(line))</div>"
                }
            }
        }
        if inList { html += "</ul>" }
        return html.data(using: .utf8)
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) async -> [NSPasteboardItem]? {
        pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let newItem = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    newItem.setData(data, forType: type)
                }
            }
            return newItem
        }
    }

    /// Wait up to 500ms for modifier keys to be released. Polls at 8ms so
    /// the average wait after a quick release is ~4ms (previously ~12ms).
    private static func waitForKeyRelease() async {
        let maxAttempts = 62  // 62 × 8ms ≈ 500ms
        for _ in 0..<maxAttempts {
            let flags = CGEventSource.flagsState(.hidSystemState)
            let hasModifiers = flags.contains(.maskSecondaryFn)
                || flags.contains(.maskCommand)
                || flags.contains(.maskAlternate)
                || flags.contains(.maskControl)
            if !hasModifiers { return }
            try? await Task.sleep(for: .milliseconds(8))
        }
        logger.warning("Key release wait timed out after 500ms")
    }

    /// Injects an arbitrary keystroke (with optional modifiers) into the
    /// focused app — powers the armed voice commands (Return, ⌘A, ⌘Z, …).
    /// Waits for any held modifier keys to clear first (same as paste) so a
    /// lingering Cmd/Fn doesn't corrupt the intended combination.
    static func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) async {
        await waitForKeyRelease()
        guard !Task.isCancelled else { return }

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cgSessionEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cgSessionEventTap)

        logger.debug("Simulated key \(keyCode) flags \(flags.rawValue)")
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)

        logger.debug("Simulated Cmd+V paste")
    }
}
