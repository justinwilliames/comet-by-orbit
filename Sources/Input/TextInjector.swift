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

        // Write text to clipboard. Plain text is the universal fallback;
        // when the cleaned output contains list lines (`• item` or `- item`),
        // we additionally write an RTF representation so rich-text-aware
        // targets (Mail, Notes, Pages, Word, Notion, Slack, etc.) render the
        // bullets as a real list with proper indent. Plain-text-only targets
        // (code editors, Terminal, chat input fields) ignore the RTF and use
        // the `•` symbols verbatim.
        pasteboard.clearContents()
        if let rtfData = makeRTF(from: finalText) {
            pasteboard.setData(rtfData, forType: .rtf)
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

    /// Builds an RTF representation of `text` with proper list paragraph
    /// styling when list lines are present. Returns `nil` when the text has
    /// no list markers — in that case we want plain-text-only paste so we
    /// don't pollute the destination's font/styling with RTF defaults.
    ///
    /// List detection: any line whose first non-whitespace characters are
    /// `• ` (the symbol we emit) or `- ` (Markdown-style fallback). Each
    /// detected line gets a paragraph style with `firstLineHeadIndent: 0`
    /// (bullet sits at the margin) and `headIndent: 18pt` (wrapped text
    /// aligns under the first character after the bullet). The bullet itself
    /// is rendered as `•\t` so rich-text apps render the indent natively.
    ///
    /// System font at the default body size is used for both list and prose
    /// runs so the destination app's font choice isn't overridden — only
    /// the paragraph-level structure (the indent) gets carried through.
    private static func makeRTF(from text: String) -> Data? {
        let lines = text.components(separatedBy: "\n")

        let hasList = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("• ") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
        }
        guard hasList else { return nil }

        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        let listParagraphStyle = NSMutableParagraphStyle()
        listParagraphStyle.firstLineHeadIndent = 0
        listParagraphStyle.headIndent = 18
        listParagraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: 18, options: [:])]

        let bodyParagraphStyle = NSMutableParagraphStyle()

        let attributed = NSMutableAttributedString()

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isBullet = trimmed.hasPrefix("• ") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")

            if isBullet {
                // Strip the original marker (one of `• `, `- `, `* `) and
                // re-emit a real bullet glyph followed by a tab so the
                // paragraph's tab stop kicks in. Using a tab rather than
                // a space lets receiving apps render proper hanging indent
                // when the line wraps.
                let content = String(trimmed.dropFirst(2))
                attributed.append(NSAttributedString(
                    string: "•\t\(content)",
                    attributes: [
                        .font: bodyFont,
                        .paragraphStyle: listParagraphStyle,
                    ]
                ))
            } else {
                attributed.append(NSAttributedString(
                    string: line,
                    attributes: [
                        .font: bodyFont,
                        .paragraphStyle: bodyParagraphStyle,
                    ]
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

    /// Injects a Return/Enter keypress into the focused app — e.g. to send a
    /// dictated chat message after pasting it. Waits for any held modifier
    /// keys to clear first (same as paste) so a lingering Cmd/Fn doesn't turn
    /// it into a different shortcut.
    static func pressReturn() async {
        await waitForKeyRelease()
        guard !Task.isCancelled else { return }

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true) // Return
        keyDown?.post(tap: .cgSessionEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
        keyUp?.post(tap: .cgSessionEventTap)

        logger.debug("Simulated Return keypress")
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
